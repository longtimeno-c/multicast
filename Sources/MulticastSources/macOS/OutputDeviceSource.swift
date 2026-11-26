#if os(macOS)
import CoreAudio
import Darwin
import Foundation
import MulticastAudio

/// Reads what the Mac plays to the "Multicast" output device (Drivers/MulticastDevice).
///
/// The driver publishes a visible output device, "Multicast", and a hidden input device,
/// "Multicast Loopback", that hands back the same audio sample for sample. This source runs an
/// IOProc on the hidden device: HAL IO thread -> Float32 ring -> converter thread (resamples
/// only when the device runs at 48 kHz) -> pipeline ring -> `read` (engine pacing thread), with
/// the same drift control as the tap sources. The driver's clock is host time at the nominal
/// rate, the clock the engine paces with, so at 44.1 kHz the fill level stays flat.
///
/// It also tells the driver the hub's playout delay (`reportLatency`), which the driver reports
/// as the output device's latency so video players delay their picture to match.
///
/// Permission: reading an input device needs Microphone access (`NSMicrophoneUsageDescription`).
public final class OutputDeviceSource: AudioSource, @unchecked Sendable {
    /// UIDs published by the driver (MC_OUTPUT_DEVICE_UID / MC_LOOPBACK_DEVICE_UID).
    public static let outputDeviceUID = "io.github.longtimeno-c.multicast.device.output"
    public static let loopbackDeviceUID = "io.github.longtimeno-c.multicast.device.loopback"
    /// The driver's custom property 'mcLt': the hub's playout delay in seconds (CFNumber).
    static let hubLatencySelector: AudioObjectPropertySelector = 0x6D63_4C74

    public enum SourceError: Error, Equatable, CustomStringConvertible {
        case notInstalled
        case unsupportedFormat(String)
        case ioStartFailed(String)

        public var description: String {
            switch self {
            case .notInstalled: "The Multicast output device isn\u{2019}t installed."
            case .unsupportedFormat(let s): "The Multicast output device has an unexpected format (\(s))."
            case .ioStartFailed(let s): "The Multicast output device couldn\u{2019}t start (\(s))."
            }
        }
    }

    public struct Statistics: Sendable, Equatable {
        public var ioCycles: Int64
        public var capturedFrames: Int64
        public var nonSilentCycles: Int64
        public var underruns: Int64
        public var driftDrops: Int64
        public var driftDuplicates: Int64
        public var resyncs: Int64
        public var sampleRate: Double
    }

    public let displayName: String
    public var isLive: Bool { true }

    /// Whether the driver is installed (its hidden loopback device exists).
    public static var isInstalled: Bool { device(uid: loopbackDeviceUID) != nil }

    /// Whether "Multicast" is the Mac's default output now.
    public static var isDefaultOutput: Bool {
        guard let dev = CAProp.defaultOutputDevice() else { return false }
        return CAProp.deviceUID(dev) == outputDeviceUID
    }

    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "Multicast.OutputDevice.listener")
    private var deviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var rateListener: CAListener?
    private var floatRing: SPSCRingBuffer<Float>?
    private var sampleRate: Double = 0
    private var worker: Thread?
    private let workerGeneration = AtomicInt64(0)
    private var workerExited = AtomicBool(true)

    private let pcmRing = PCMRingBuffer(capacityFrames: PCM.sampleRate * 2, channels: PCM.channels)
    private var fill = LiveFillController()
    private let flushOutput = AtomicBool(false)

    private let ioCycles = AtomicInt64(0)
    private let framesIn = AtomicInt64(0)
    private let nonSilentCycles = AtomicInt64(0)
    private let underruns = AtomicInt64(0)
    private let driftDrops = AtomicInt64(0)
    private let driftDups = AtomicInt64(0)
    private let resyncs = AtomicInt64(0)

    public init(displayName: String = "Mac output") {
        self.displayName = displayName
    }

    deinit { teardown() }

    public var statistics: Statistics {
        Statistics(ioCycles: ioCycles.load(), capturedFrames: framesIn.load(), nonSilentCycles: nonSilentCycles.load(),
                   underruns: underruns.load(), driftDrops: driftDrops.load(), driftDuplicates: driftDups.load(),
                   resyncs: resyncs.load(), sampleRate: lock.withLock { sampleRate })
    }

    // MARK: Lifecycle

    public func start() async throws {
        try lock.withLock { try startLocked() }
    }

    public func stop() async {
        teardown()
    }

    private func teardown() {
        lock.withLock { stopLocked() }
    }

    private func startLocked() throws {
        guard ioProcID == nil else { return }
        guard let dev = Self.device(uid: Self.loopbackDeviceUID) else { throw SourceError.notInstalled }
        let rate: Double = CAProp.scalar(dev, kAudioDevicePropertyNominalSampleRate) ?? 0
        guard rate > 0 else { throw SourceError.unsupportedFormat("no sample rate") }
        let ring = SPSCRingBuffer<Float>(capacityFrames: Int(rate), channels: 2)
        var procID: AudioDeviceIOProcID?
        let cycles = ioCycles, frames = framesIn, loud = nonSilentCycles
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, input, _, _, _ in
            cycles.add(1)
            let n = OutputDeviceSource.copyInput(input, into: ring)
            frames.add(Int64(n.frames))
            if n.nonSilent { loud.add(1) }
        }
        guard status == noErr, let procID else { throw SourceError.ioStartFailed("IOProc \(CAProp.fourCC(status))") }
        let started = AudioDeviceStart(dev, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(dev, procID)
            throw SourceError.ioStartFailed("start \(CAProp.fourCC(started))")
        }
        deviceID = dev
        ioProcID = procID
        floatRing = ring
        sampleRate = rate
        flushOutput.store(true)
        startWorker(ring: ring, rate: rate)
        // A rate change (Audio MIDI Setup) restarts the IO at the new rate.
        rateListener = CAListener(object: dev, selector: kAudioDevicePropertyNominalSampleRate, queue: listenerQueue) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.ioProcID != nil else { return }
                self.stopLocked()
                try? self.startLocked()
            }
        }
    }

    private func stopLocked() {
        rateListener?.cancel()
        rateListener = nil
        if let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        ioProcID = nil
        workerGeneration.add(1)
        worker = nil
        floatRing = nil
    }

    // MARK: Latency reporting

    /// Tells the driver how long after the Mac plays a frame it is heard on the speakers, so the
    /// output device reports it as latency (video apps delay the picture to match). Returns
    /// false if the driver isn't installed or refused the value.
    @discardableResult
    public static func reportLatency(seconds: Double) -> Bool {
        guard let dev = device(uid: outputDeviceUID) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: hubLatencySelector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &address) else { return false }
        var value: CFPropertyList = NSNumber(value: min(max(0, seconds), 10))
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(dev, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
        return status == noErr
    }

    /// The latency the output device reports, in seconds (nil if not installed).
    public static func reportedLatencySeconds() -> Double? {
        guard let dev = device(uid: outputDeviceUID),
              let frames: UInt32 = CAProp.scalar(dev, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput),
              let rate: Double = CAProp.scalar(dev, kAudioDevicePropertyNominalSampleRate), rate > 0 else { return nil }
        return Double(frames) / rate
    }

    // MARK: Engine thread

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        if flushOutput.exchangeFalse() {
            pcmRing.discardAll()
            fill.reset()
        }
        let wasPriming = fill.priming
        switch fill.decide(available: pcmRing.availableToRead, requested: frameCount) {
        case .wait:
            if !wasPriming { underruns.add(1) }
            return 0
        case .read(let n):
            return pcmRing.read(into: buffer, frames: n)
        case .readDroppingOne(let n):
            let got = pcmRing.read(into: buffer, frames: n)
            pcmRing.skip(frames: 1)
            driftDrops.add(1)
            return got
        case .readDuplicatingOne(let n):
            let got = pcmRing.read(into: buffer, frames: n - 1)
            if got > 0 {
                buffer[2 * got] = buffer[2 * (got - 1)]
                buffer[2 * got + 1] = buffer[2 * (got - 1) + 1]
            }
            driftDups.add(1)
            return got + 1
        case .resync(let drop, let n):
            pcmRing.skip(frames: drop)
            resyncs.add(1)
            return pcmRing.read(into: buffer, frames: n)
        }
    }

    // MARK: Converter thread

    private func startWorker(ring: SPSCRingBuffer<Float>, rate: Double) {
        let previous = workerExited
        while !previous.load() { usleep(1_000) }
        let gen = workerGeneration.add(1)
        let exited = AtomicBool(false)
        workerExited = exited
        let gate = WorkerGate(generation: gen, current: workerGeneration)
        let out = pcmRing
        let t = Thread {
            OutputDeviceSource.convertLoop(ring: ring, rate: rate, into: out, while: gate)
            exited.store(true)
        }
        t.name = "Multicast.OutputDevice.converter"
        t.qualityOfService = .userInteractive
        worker = t
        t.start()
    }

    private static func convertLoop(ring: SPSCRingBuffer<Float>, rate: Double, into out: PCMRingBuffer, while gate: WorkerGate) {
        let chunk = 2048
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        let s16 = UnsafeMutablePointer<Int16>.allocate(capacity: chunk * 2)
        defer { scratch.deallocate(); s16.deallocate() }
        let direct = rate == Double(PCM.sampleRate)
        let converter = direct ? nil : try? PipelineConverter(inputSampleRate: rate, maxInputFrames: chunk)
        while gate.load() {
            var didWork = false
            while gate.load() {
                let n = ring.read(into: scratch, frames: chunk)
                if n == 0 { break }
                didWork = true
                if direct {
                    floatToS16(scratch, count: n * 2, into: s16)
                    out.write(s16, frames: n)
                } else if let converter {
                    try? converter.convert(interleaved: scratch, frames: n) { ptr, frames in out.write(ptr, frames: frames) }
                }
            }
            if !didWork { usleep(4_000) }
        }
    }

    // MARK: Pure helpers (tested)

    /// Interleaved Float32 -> S16 with clipping (the 44.1 kHz path: no resampling).
    static func floatToS16(_ src: UnsafePointer<Float>, count: Int, into dst: UnsafeMutablePointer<Int16>) {
        for i in 0..<count { dst[i] = SampleConversion.int16(fromFloat: src[i]) }
    }

    /// Copies one IO cycle of the loopback device's input (one interleaved stereo buffer, or
    /// planar buffers) into `ring` as interleaved stereo. Real-time safe.
    @inline(__always)
    static func copyInput(_ input: UnsafePointer<AudioBufferList>, into ring: SPSCRingBuffer<Float>) -> (frames: Int, nonSilent: Bool) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard abl.count > 0, let d0 = abl[0].mData else { return (0, false) }
        var loud = false
        if abl.count == 1 {
            let ch = max(1, Int(abl[0].mNumberChannels))
            let frames = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let src = d0.assumingMemoryBound(to: Float.self)
            ring.withWritableRegions(maxFrames: frames) { dst, count, offset in
                for i in 0..<count {
                    let s = (offset + i) * ch
                    let l = src[s], r = ch > 1 ? src[s + 1] : l
                    if l != 0 || r != 0 { loud = true }
                    dst[2 * i] = l
                    dst[2 * i + 1] = r
                }
            }
            return (frames, loud)
        }
        let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        let l = d0.assumingMemoryBound(to: Float.self)
        let r = (abl[1].mData ?? d0).assumingMemoryBound(to: Float.self)
        ring.withWritableRegions(maxFrames: frames) { dst, count, offset in
            for i in 0..<count {
                let a = l[offset + i], b = r[offset + i]
                if a != 0 || b != 0 { loud = true }
                dst[2 * i] = a
                dst[2 * i + 1] = b
            }
        }
        return (frames, loud)
    }

    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &dev)
        }
        return status == noErr && dev != kAudioObjectUnknown ? dev : nil
    }
}
#endif
