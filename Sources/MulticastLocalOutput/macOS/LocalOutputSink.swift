#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
import MulticastAudio

/// One local Core Audio output device (built-in, Bluetooth, USB, HDMI…) as a timeline-aligned
/// `AudioSink`.
///
/// Each sink owns its own AUHAL output unit (`kAudioUnitSubType_HALOutput`) bound to *its*
/// device (never the system default), so any number of local devices play simultaneously.
/// The unit's input is pipeline-rate (44.1 kHz) Float32 stereo; the AUHAL's converter does the
/// device-rate conversion. The render callback asks `RenderCore` for the timeline frame that
/// must be handed to the hardware at the callback's host time + total output latency + trim.
public final class LocalOutputSink: AudioSink, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let deviceUID: String

    private let core: RenderCore
    private let control = NSLock()
    private let accepting = AtomicU64(0)
    private let stateBroadcaster = ReplayingBroadcaster<SinkState>(.idle)
    private let listenerQueue: DispatchQueue

    // Guarded by `control`.
    private var unit: AudioUnit?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var session: UInt64 = 0
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var volume: Float = 1
    private var offset: Int = 0
    private var latency = LocalOutputLatency.zero
    private var currentTimeline: StreamTimeline?

    /// - Throws: `LocalOutputError.missingDeviceUID` if the descriptor is not a local output.
    public convenience init(descriptor: SpeakerDescriptor) throws {
        guard descriptor.transport == .local, let uid = descriptor.localDeviceUID else {
            throw LocalOutputError.missingDeviceUID(speakerID: descriptor.id)
        }
        self.init(deviceUID: uid, name: descriptor.name)
    }

    public init(deviceUID: String, name: String? = nil) {
        self.deviceUID = deviceUID
        self.id = LocalKindMapping.speakerID(forDeviceUID: deviceUID)
        self.displayName = name ?? CoreAudioHAL.deviceID(forUID: deviceUID).flatMap(CoreAudioHAL.deviceName) ?? deviceUID
        self.core = RenderCore()
        self.listenerQueue = DispatchQueue(label: "multicast.localoutput.sink.\(deviceUID)")
        _ = HostClock.nanos(fromHostTicks: 1) // initialise the timebase off the IO thread
    }

    deinit {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        for (obj, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, listenerQueue, block)
        }
        stateBroadcaster.finishAll()
    }

    // MARK: UI-facing extras

    /// Latency compensated for (reported by the HAL + converter). Bluetooth devices often
    /// under-report; use `setOffset(millis:)` to trim.
    public var reportedLatency: LocalOutputLatency {
        control.lock(); defer { control.unlock() }
        return latency
    }

    /// Live sync telemetry (measured read-position error, varispeed ratio, jumps, underruns).
    public var syncStats: LocalOutputSyncStats { core.snapshotStats() }

    public var offsetMillis: Int {
        control.lock(); defer { control.unlock() }
        return offset
    }

    public var currentState: SinkState { stateBroadcaster.current }

    // MARK: AudioSink

    public var stateUpdates: AsyncStream<SinkState> { stateBroadcaster.makeStream() }

    public func prepare(timeline: StreamTimeline) async throws {
        try prepareSync(timeline: timeline)
    }

    func prepareSync(timeline: StreamTimeline) throws {
        control.lock()
        defer { control.unlock() }
        do {
            try core.checkCapacity(for: timeline)
        } catch {
            stateBroadcaster.send(.failed((error as? LocalOutputError)?.description ?? "\(error)"))
            throw error
        }

        if unit != nil, CoreAudioHAL.isAlive(deviceID) {
            // Already open: re-anchor without reopening the device.
            if currentTimeline != timeline { core.ring.requestReset() }
            currentTimeline = timeline
            core.setTimeline(timeline)
            accepting.store(1)
            stateBroadcaster.sendIfChanged(.playing)
            return
        }
        if unit != nil { closeUnitLocked() }

        stateBroadcaster.sendIfChanged(.connecting)
        do {
            guard let dev = CoreAudioHAL.deviceID(forUID: deviceUID) else {
                throw LocalOutputError.deviceNotFound(uid: deviceUID)
            }
            guard CoreAudioHAL.isAlive(dev) else { throw LocalOutputError.deviceNotAlive(name: displayName) }
            guard CoreAudioHAL.outputChannelCount(dev) > 0 else { throw LocalOutputError.noOutputChannels(name: displayName) }

            core.resetForStart()
            core.ring.requestReset()
            core.setTimeline(timeline)
            core.setOffset(millis: offset)
            core.setGainTarget(VolumeCurve.amplitude(forVolume: volume))

            let u = try openUnit(device: dev)
            unit = u
            deviceID = dev
            session &+= 1
            currentTimeline = timeline
            refreshLatencyLocked()
            installDeviceListenersLocked(device: dev, session: session)

            core.setActive(true)
            accepting.store(1)
            let status = AudioOutputUnitStart(u)
            guard status == noErr else { throw LocalOutputError.coreAudio(operation: "AudioOutputUnitStart", status: status) }
            stateBroadcaster.send(.playing)
        } catch {
            closeUnitLocked()
            let reason = (error as? LocalOutputError)?.description ?? String(describing: error)
            stateBroadcaster.send(.failed(reason))
            throw error
        }
    }

    public func enqueue(_ packet: AudioPacket) {
        guard accepting.load(acquire: false) == 1 else { return }
        core.write(packet: packet)
    }

    public func setVolume(_ volume: Float) async {
        control.withLock {
            self.volume = max(0, min(1, volume))
            core.setGainTarget(VolumeCurve.amplitude(forVolume: self.volume))
        }
    }

    public func setOffset(millis: Int) async {
        control.withLock {
            offset = millis
            core.setOffset(millis: millis)
        }
    }

    public func flush() async {
        core.ring.requestReset()
    }

    public func stop() async {
        stopSync()
    }

    func stopSync() {
        control.lock()
        closeUnitLocked()
        control.unlock()
        stateBroadcaster.sendIfChanged(.idle)
    }

    // MARK: Unit

    private static let renderCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, _, inNumberFrames, ioData in
        guard let ioData else { return noErr }
        let core = Unmanaged<RenderCore>.fromOpaque(refCon).takeUnretainedValue()
        let ts = inTimeStamp.pointee
        let host: UInt64? = ts.mFlags.contains(.hostTimeValid) ? HostClock.nanos(fromHostTicks: ts.mHostTime) : nil
        let silent = core.render(hostNanos: host, frames: Int(inNumberFrames), abl: UnsafeMutableAudioBufferListPointer(ioData))
        if silent { ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence) }
        return noErr
    }

    private func openUnit(device: AudioObjectID) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw LocalOutputError.coreAudio(operation: "AudioComponentFindNext(HALOutput)", status: -1)
        }
        var maybeUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &maybeUnit), "AudioComponentInstanceNew")
        guard let u = maybeUnit else { throw LocalOutputError.coreAudio(operation: "AudioComponentInstanceNew", status: -1) }
        do {
            var one: UInt32 = 1, zero: UInt32 = 0
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, u32), "EnableIO(output)")
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, u32), "EnableIO(input)")
            var dev = device
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                           UInt32(MemoryLayout<AudioObjectID>.size)), "CurrentDevice")
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(PCM.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size * PCM.channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size * PCM.channels),
                mChannelsPerFrame: UInt32(PCM.channels),
                mBitsPerChannel: 32,
                mReserved: 0)
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "StreamFormat")
            var maxFrames = UInt32(4096)
            _ = AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)
            var cb = AURenderCallbackStruct(
                inputProc: LocalOutputSink.renderCallback,
                inputProcRefCon: Unmanaged.passUnretained(core).toOpaque())
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback")
            try check(AudioUnitInitialize(u), "AudioUnitInitialize")
            return u
        } catch {
            AudioComponentInstanceDispose(u)
            throw error
        }
    }

    private func check(_ status: OSStatus, _ op: String) throws {
        if status != noErr { throw LocalOutputError.coreAudio(operation: op, status: status) }
    }

    /// Stop and dispose the unit, remove listeners, stop accepting packets. Caller holds `control`.
    private func closeUnitLocked() {
        accepting.store(0)
        core.setActive(false)
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        unit = nil
        session &+= 1
        let toRemove = deviceListeners
        deviceListeners.removeAll()
        // Remove listeners off this thread and outside the control lock (this may run on the
        // listener queue itself). Handlers that still fire bail out on the stale session token.
        if !toRemove.isEmpty {
            let queue = listenerQueue
            DispatchQueue.global(qos: .utility).async {
                for (obj, addr, block) in toRemove {
                    var a = addr
                    AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
                }
            }
        }
        core.ring.requestReset()
        deviceID = AudioObjectID(kAudioObjectUnknown)
        currentTimeline = nil
    }

    private func refreshLatencyLocked() {
        var l = CoreAudioHAL.outputLatency(deviceID)
        if let u = unit {
            var seconds: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            if AudioUnitGetProperty(u, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size) == noErr {
                l.unitLatencySeconds = seconds
            }
        }
        latency = l
        core.setOutputLatency(nanos: l.totalNanos)
    }

    private func installDeviceListenersLocked(device: AudioObjectID, session token: UInt64) {
        let out = kAudioObjectPropertyScopeOutput
        let watches: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (device, CoreAudioHAL.address(kAudioDevicePropertyDeviceIsAlive)),
            (device, CoreAudioHAL.address(kAudioDevicePropertyNominalSampleRate)),
            (device, CoreAudioHAL.address(kAudioDevicePropertyLatency, out)),
            (device, CoreAudioHAL.address(kAudioDevicePropertySafetyOffset, out)),
            (device, CoreAudioHAL.address(kAudioDevicePropertyStreamConfiguration, out)),
            (AudioObjectID(kAudioObjectSystemObject), CoreAudioHAL.address(kAudioHardwarePropertyDevices)),
        ]
        for (obj, addr) in watches {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceChanged(session: token)
            }
            var a = addr
            if AudioObjectAddPropertyListenerBlock(obj, &a, listenerQueue, block) == noErr {
                deviceListeners.append((obj, addr, block))
            }
        }
    }

    private func deviceChanged(session token: UInt64) {
        control.lock()
        guard token == session, unit != nil else { control.unlock(); return }
        let stillPresent = CoreAudioHAL.allDeviceIDs().contains(deviceID)
        if !stillPresent || !CoreAudioHAL.isAlive(deviceID) || CoreAudioHAL.outputChannelCount(deviceID) == 0 {
            closeUnitLocked()
            control.unlock()
            stateBroadcaster.send(.failed("Output device \"\(displayName)\" was disconnected"))
            return
        }
        refreshLatencyLocked()
        control.unlock()
    }
}
#endif
