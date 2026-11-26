#if os(macOS)
import Accelerate
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import MulticastAudio

/// Captures app or system audio with Core Audio process taps (macOS 14.2+).
///
/// Pipeline: process tap -> private aggregate device ("Multicast Capture …") -> IOProc on the
/// HAL IO thread copies Float32 frames into a lock-free ring -> converter thread resamples to
/// 44.1 kHz S16 stereo into a second ring -> `read` (engine pacing thread). `read` also applies
/// gentle drift correction (drop/duplicate one frame per pull) so the tap's device clock and
/// the engine's host clock cannot push latency up or starve the ring.
///
/// Permission: process taps need the "System Audio Recording" TCC grant
/// (`NSAudioCaptureUsageDescription` in the app's Info.plist). Without it the tap is created
/// but delivers digital silence; `permission` becomes `.likelySilencedByTCC` when the tap has
/// been running ≥3 s with only exact zeros while a tapped process is producing output.
@available(macOS 14.2, *)
public final class AppAudioTapSource: AudioSource, @unchecked Sendable {
    public enum Target: Sendable, Equatable, CustomStringConvertible {
        /// Specific apps by bundle id (their helper processes are included, e.g. a browser's
        /// audio helper). Re-resolved whenever processes appear/disappear (app relaunch).
        case apps(bundleIDs: [String])
        /// Specific Core Audio process objects (from `AudioProcessDirectory`).
        case processObjects([AudioObjectID])
        /// Everything on the system except this process (prevents re-capturing what Multicast
        /// itself plays on local outputs) and except the listed apps.
        case systemExcludingSelf(alsoExcludingApps: [String])

        public static var system: Target { .systemExcludingSelf(alsoExcludingApps: []) }

        public var description: String {
            switch self {
            case .apps(let ids): return ids.joined(separator: ", ")
            case .processObjects(let objs): return "processes " + objs.map(String.init).joined(separator: ",")
            case .systemExcludingSelf(let ex): return ex.isEmpty ? "System audio" : "System audio (excluding \(ex.joined(separator: ", ")))"
            }
        }
    }

    public enum MuteBehavior: Sendable, Equatable {
        /// Captured app is also heard directly on the Mac (un-delayed: will echo against the
        /// synced playback).
        case unmuted
        /// Captured app is never sent to hardware while the tap exists.
        case muted
        /// Captured app is muted only while Multicast is actually reading the tap (default).
        case mutedWhenTapped
    }

    public enum State: Sendable, Equatable {
        case idle
        /// No process matching the target is a Core Audio client yet (app not running / silent).
        case waitingForProcess
        case starting
        case capturing
        case failed(String)
    }

    public enum CapturePermission: Sendable, Equatable {
        case unknown
        /// Non-zero samples have been captured: the grant is effective.
        case granted
        /// Only exact digital silence while a tapped process is producing output: almost
        /// certainly the System Audio Recording permission is missing / denied.
        case likelySilencedByTCC
        /// Tap creation was refused by the system.
        case denied(String)
    }

    public enum TapError: Error, Equatable {
        case tapCreationFailed(String)
        case aggregateCreationFailed(String)
        case ioStartFailed(String)
        case unsupportedTapFormat(String)
        case alreadyStarted
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        public var permission: CapturePermission
        /// Process objects currently included (or, for `.systemExcludingSelf`, excluded).
        public var processObjects: [AudioObjectID]
        public var tapSampleRate: Double?
        public var outputDeviceUID: String?
    }

    public struct Statistics: Sendable, Equatable {
        public var ioCycles: Int64
        public var capturedFrames: Int64
        public var nonSilentCycles: Int64
        public var inputOverflowFrames: Int64
        public var outputOverflowFrames: Int64
        public var underruns: Int64
        public var driftDrops: Int64
        public var driftDuplicates: Int64
        public var resyncs: Int64
        public var rebuilds: Int64
    }

    public let target: Target
    public let muteBehavior: MuteBehavior
    public let displayName: String
    public var isLive: Bool { true }

    private let core: TapCore

    public init(target: Target, muteBehavior: MuteBehavior = .mutedWhenTapped, displayName: String? = nil) {
        self.target = target
        self.muteBehavior = muteBehavior
        self.displayName = displayName ?? target.description
        self.core = TapCore(target: target, muteBehavior: muteBehavior)
    }

    deinit {
        core.shutdownSync()
    }

    public var status: Status { core.currentStatus() }
    public var statistics: Statistics { core.statistics() }
    /// Status now, then on every change.
    public var statusUpdates: AsyncStream<Status> { core.makeStatusStream() }

    /// Builds the tap and starts capturing. If the target app is not running yet, succeeds in
    /// `.waitingForProcess` and starts automatically when it appears. Throws for definitive
    /// failures (tap / aggregate creation refused).
    public func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            core.start { result in c.resume(with: result) }
        }
    }

    /// Stops capture and destroys the tap and aggregate device.
    public func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            core.stop { c.resume() }
        }
    }

    public func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
        core.read(into: buffer, frameCount: frameCount)
    }

    // MARK: Stale device cleanup

    public struct CleanupResult: Sendable, Equatable {
        public var destroyedAggregateDevices: [String]
        public var destroyedTaps: [String]
    }

    /// UID prefix of every aggregate device this module creates.
    public static let aggregateUIDPrefix = "com.multicast.capture."
    /// Name prefix of every aggregate device and tap this module creates.
    public static let namePrefix = "Multicast"

    /// Destroys aggregate devices and taps left behind by this module (e.g. after a crash)
    /// that are visible to this process and not owned by a live `AppAudioTapSource`.
    /// Only devices whose UID starts with `aggregateUIDPrefix` and taps whose name starts with
    /// `namePrefix` are touched. Call once at launch.
    @discardableResult
    public static func cleanupStaleDevices() -> CleanupResult {
        var result = CleanupResult(destroyedAggregateDevices: [], destroyedTaps: [])
        let live = TapRegistry.shared.liveIDs()
        for dev in CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyDevices) where !live.contains(dev) {
            guard CAProp.classID(dev) == kAudioAggregateDeviceClassID,
                  let uid = CAProp.deviceUID(dev), uid.hasPrefix(aggregateUIDPrefix) else { continue }
            if AudioHardwareDestroyAggregateDevice(dev) == noErr {
                result.destroyedAggregateDevices.append(uid)
            }
        }
        for tap in CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyTapList) where !live.contains(tap) {
            let name = CAProp.name(tap) ?? ""
            guard name.hasPrefix(namePrefix) else { continue }
            if AudioHardwareDestroyProcessTap(tap) == noErr {
                result.destroyedTaps.append(CAProp.string(tap, kAudioTapPropertyUID) ?? name)
            }
        }
        return result
    }

    /// Aggregate devices / taps created by this module that are currently visible.
    public static func visibleMulticastDevices() -> (aggregates: [String], taps: [String]) {
        let aggs = CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyDevices).compactMap { dev -> String? in
            guard let uid = CAProp.deviceUID(dev), uid.hasPrefix(aggregateUIDPrefix) else { return nil }
            return uid
        }
        let taps = CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyTapList).compactMap { tap -> String? in
            let name = CAProp.name(tap) ?? ""
            return name.hasPrefix(namePrefix) ? name : nil
        }
        return (aggs, taps)
    }
}

// MARK: - Drift control (pure, tested)

/// Decides, per engine pull, how to keep the capture ring near its target fill level.
struct LiveFillController: Equatable {
    enum Action: Equatable {
        /// Not enough buffered yet: deliver nothing (engine pads silence).
        case wait
        /// Deliver `frames` frames normally.
        case read(frames: Int)
        /// Deliver `frames` and drop one extra frame (ring above target: speed up 1 frame).
        case readDroppingOne(frames: Int)
        /// Deliver `frames - 1` real frames and duplicate the last one (ring low: slow down).
        case readDuplicatingOne(frames: Int)
        /// Ring far too full: drop `drop` frames first, then deliver `frames`.
        case resync(drop: Int, frames: Int)
    }

    let targetFrames: Int
    let lowFrames: Int
    let highFrames: Int
    let maxFrames: Int
    private(set) var priming = true

    init(targetFrames: Int = 4410) {
        self.targetFrames = targetFrames
        self.lowFrames = targetFrames / 2
        self.highFrames = targetFrames * 2
        self.maxFrames = targetFrames * 5
    }

    mutating func reset() { priming = true }

    mutating func decide(available: Int, requested: Int) -> Action {
        if requested <= 0 { return .read(frames: 0) }
        if priming {
            if available < targetFrames { return .wait }
            priming = false
        }
        if available == 0 {
            priming = true
            return .wait
        }
        if available > maxFrames {
            let drop = available - targetFrames
            return .resync(drop: drop, frames: min(requested, available - drop))
        }
        let n = min(requested, available)
        if n < requested { return .read(frames: n) }
        if available - n > highFrames, available - n - 1 >= 0 { return .readDroppingOne(frames: n) }
        if available - n < lowFrames, n >= 2 { return .readDuplicatingOne(frames: n) }
        return .read(frames: n)
    }
}

/// "Keep running while the worker generation is still mine."
struct WorkerGate {
    let generation: Int64
    let current: AtomicInt64
    @inline(__always) func load() -> Bool { current.load() == generation }
}

// MARK: - Registry of live objects (for stale cleanup)

final class TapRegistry: @unchecked Sendable {
    static let shared = TapRegistry()
    private let lock = NSLock()
    private var ids = Set<AudioObjectID>()
    func add(_ id: AudioObjectID) { lock.withLock { _ = ids.insert(id) } }
    func remove(_ id: AudioObjectID) { lock.withLock { _ = ids.remove(id) } }
    func liveIDs() -> Set<AudioObjectID> { lock.withLock { ids } }
}

// MARK: - One tap + aggregate lifetime

@available(macOS 14.2, *)
final class TapSession: @unchecked Sendable {
    let tapID: AudioObjectID
    let tapUUID: UUID
    let aggregateID: AudioObjectID
    let sampleRate: Double
    let outputDeviceUID: String?
    let processObjects: [AudioObjectID]
    let floatRing: SPSCRingBuffer<Float>
    var ioProcID: AudioDeviceIOProcID?
    var formatListener: CAListener?
    let createdAt = Date()

    let ioCycles = AtomicInt64(0)
    let framesIn = AtomicInt64(0)
    let nonSilentCycles = AtomicInt64(0)
    let overflowFrames = AtomicInt64(0)

    init(tapID: AudioObjectID, tapUUID: UUID, aggregateID: AudioObjectID, sampleRate: Double,
         outputDeviceUID: String?, processObjects: [AudioObjectID]) {
        self.tapID = tapID
        self.tapUUID = tapUUID
        self.aggregateID = aggregateID
        self.sampleRate = sampleRate
        self.outputDeviceUID = outputDeviceUID
        self.processObjects = processObjects
        self.floatRing = SPSCRingBuffer<Float>(capacityFrames: Int(sampleRate), channels: 2)
    }

    /// Real-time: called on the HAL IO thread. Copies Float32 input into `floatRing`.
    @inline(__always)
    func handleInput(_ input: UnsafePointer<AudioBufferList>) {
        ioCycles.add(1)
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard abl.count > 0, let d0 = abl[0].mData else { return }
        var peak: Float = 0
        var frames = 0
        if abl.count == 1 {
            let ch = max(1, Int(abl[0].mNumberChannels))
            frames = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let src = d0.assumingMemoryBound(to: Float.self)
            vDSP_maxmgv(src, 1, &peak, vDSP_Length(frames * ch))
            let written = floatRing.withWritableRegions(maxFrames: frames) { dst, count, offset in
                for i in 0..<count {
                    let s = (offset + i) * ch
                    let l = src[s]
                    dst[2 * i] = l
                    dst[2 * i + 1] = ch > 1 ? src[s + 1] : l
                }
            }
            if written < frames { overflowFrames.add(Int64(frames - written)) }
        } else {
            frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let l = d0.assumingMemoryBound(to: Float.self)
            let r = (abl[1].mData ?? d0).assumingMemoryBound(to: Float.self)
            var p2: Float = 0
            vDSP_maxmgv(l, 1, &peak, vDSP_Length(frames))
            vDSP_maxmgv(r, 1, &p2, vDSP_Length(frames))
            peak = max(peak, p2)
            let written = floatRing.withWritableRegions(maxFrames: frames) { dst, count, offset in
                for i in 0..<count {
                    dst[2 * i] = l[offset + i]
                    dst[2 * i + 1] = r[offset + i]
                }
            }
            if written < frames { overflowFrames.add(Int64(frames - written)) }
        }
        framesIn.add(Int64(frames))
        if peak > 0 { nonSilentCycles.add(1) }
    }
}

// MARK: - Core

@available(macOS 14.2, *)
final class TapCore: @unchecked Sendable {
    typealias Status = AppAudioTapSource.Status
    typealias State = AppAudioTapSource.State

    let target: AppAudioTapSource.Target
    let muteBehavior: AppAudioTapSource.MuteBehavior

    private let controlQueue = DispatchQueue(label: "Multicast.AppAudioTap.control")
    private let queueKey = DispatchSpecificKey<Bool>()

    // Control-queue state.
    private var running = false
    private var session: TapSession?
    private var systemListeners: [CAListener] = []
    private var watchdog: DispatchSourceTimer?
    private var rebuildScheduled = false
    private var status = Status(state: .idle, permission: .unknown, processObjects: [], tapSampleRate: nil, outputDeviceUID: nil)
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var silentSince: Date?
    private var rebuilds: Int64 = 0
    private var lastIOCycles: Int64 = 0
    private var ioStalledSince: Date?

    // Shared between control queue and converter thread.
    private let sessionLock = NSLock()
    private var workerSession: TapSession?
    private var workerThread: Thread?
    private let workerGeneration = AtomicInt64(0)
    private var workerExited = AtomicBool(true)

    // Output ring (converter thread -> engine).
    let pcmRing = PCMRingBuffer(capacityFrames: PCM.sampleRate * 2, channels: PCM.channels)
    private let outputOverflow = AtomicInt64(0)
    private let flushOutput = AtomicBool(false)

    // Engine-thread state.
    private var fill = LiveFillController()
    private let underruns = AtomicInt64(0)
    private let driftDrops = AtomicInt64(0)
    private let driftDups = AtomicInt64(0)
    private let resyncs = AtomicInt64(0)

    init(target: AppAudioTapSource.Target, muteBehavior: AppAudioTapSource.MuteBehavior) {
        self.target = target
        self.muteBehavior = muteBehavior
        controlQueue.setSpecific(key: queueKey, value: true)
    }

    // MARK: Engine thread

    func read(into buffer: UnsafeMutablePointer<Int16>, frameCount: Int) -> Int? {
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

    // MARK: Status

    func currentStatus() -> Status {
        onControlQueueSync { status }
    }

    func statistics() -> AppAudioTapSource.Statistics {
        let s: TapSession? = sessionLock.withLock { workerSession }
        let rb = onControlQueueSync { rebuilds }
        return .init(
            ioCycles: s?.ioCycles.load() ?? 0,
            capturedFrames: s?.framesIn.load() ?? 0,
            nonSilentCycles: s?.nonSilentCycles.load() ?? 0,
            inputOverflowFrames: s?.overflowFrames.load() ?? 0,
            outputOverflowFrames: outputOverflow.load(),
            underruns: underruns.load(),
            driftDrops: driftDrops.load(),
            driftDuplicates: driftDups.load(),
            resyncs: resyncs.load(),
            rebuilds: rb)
    }

    func makeStatusStream() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let token = UUID()
            controlQueue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                self.statusContinuations[token] = continuation
                continuation.yield(self.status)
            }
            continuation.onTermination = { [weak self] _ in
                self?.controlQueue.async { self?.statusContinuations[token] = nil }
            }
        }
    }

    private func setStatus(_ mutate: (inout Status) -> Void) {
        var s = status
        mutate(&s)
        guard s != status else { return }
        status = s
        for c in statusContinuations.values { c.yield(s) }
    }

    private func onControlQueueSync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return controlQueue.sync(execute: body)
    }

    // MARK: Lifecycle (control queue)

    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        controlQueue.async { [self] in
            guard !running else { completion(.failure(AppAudioTapSource.TapError.alreadyStarted)); return }
            running = true
            flushOutput.store(true)
            installSystemListeners()
            startWorker()
            startWatchdog()
            do {
                try build()
                completion(.success(()))
            } catch {
                let message = "\(error)"
                teardownAll()
                setStatus { $0.state = .failed(message) }
                completion(.failure(error))
            }
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        controlQueue.async { [self] in
            teardownAll()
            setStatus { $0.state = .idle; $0.processObjects = []; $0.tapSampleRate = nil }
            completion()
        }
    }

    func shutdownSync() {
        onControlQueueSync {
            teardownAll()
            for c in statusContinuations.values { c.finish() }
            statusContinuations = [:]
        }
    }

    private func teardownAll() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        systemListeners.forEach { $0.cancel() }
        systemListeners = []
        if let s = session { destroy(s) }
        session = nil
        stopWorker()
        flushOutput.store(true)
    }

    private func installSystemListeners() {
        let q = controlQueue
        let handler: @Sendable () -> Void = { [weak self] in self?.scheduleRebuild(reason: "system change") }
        for sel in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            if let l = CAListener(object: CAProp.system, selector: sel, queue: q, handler: handler) {
                systemListeners.append(l)
            }
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        t.resume()
        watchdog = t
    }

    /// Process objects the tap should include (or exclude, for the system target), now.
    private func resolveProcessObjects() -> [AudioObjectID]? {
        switch target {
        case .apps(let bundleIDs):
            let procs = AudioProcessDirectory.snapshot().filter { p in bundleIDs.contains { p.belongs(toApp: $0) } }
            let ids = procs.filter { !$0.isCurrentProcess }.map(\.objectID).sorted()
            return ids.isEmpty ? nil : ids
        case .processObjects(let objs):
            let existing = Set(CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyProcessObjectList))
            let ids = objs.filter { existing.contains($0) }.sorted()
            return ids.isEmpty ? nil : ids
        case .systemExcludingSelf(let apps):
            var ids: [AudioObjectID] = []
            if let me = CAProp.processObject(forPID: getpid()) { ids.append(me) }
            if !apps.isEmpty {
                ids += AudioProcessDirectory.snapshot().filter { p in apps.contains { p.belongs(toApp: $0) } }.map(\.objectID)
            }
            return Array(Set(ids)).sorted()
        }
    }

    private func scheduleRebuild(reason: String) {
        guard running, !rebuildScheduled else { return }
        rebuildScheduled = true
        controlQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.running else { return }
            self.rebuildIfNeeded()
        }
    }

    private func rebuildIfNeeded() {
        let desired = resolveProcessObjects()
        let defaultUID = CAProp.defaultOutputDevice().flatMap(CAProp.deviceUID)
        var currentRate: Double?
        if let s = session, let asbd = CAProp.scalar(s.tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
            currentRate = asbd.mSampleRate
        }
        if let s = session, desired == s.processObjects, defaultUID == s.outputDeviceUID,
           currentRate == nil || currentRate == s.sampleRate {
            return // nothing relevant changed
        }
        if session == nil, desired == nil { return } // still waiting
        do {
            try build()
        } catch {
            setStatus { $0.state = .failed("\(error)") }
        }
    }

    /// (Re)creates tap + aggregate + IOProc for the current target. Control queue only.
    private func build() throws {
        if let s = session {
            destroy(s)
            session = nil
            rebuilds += 1
        }
        guard let objects = resolveProcessObjects() else {
            setStatus { $0.state = .waitingForProcess; $0.processObjects = []; $0.tapSampleRate = nil }
            return
        }
        setStatus { $0.state = .starting }

        let desc: CATapDescription
        switch target {
        case .systemExcludingSelf:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
        case .apps, .processObjects:
            desc = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        let uuid = UUID()
        desc.uuid = uuid
        desc.name = "\(AppAudioTapSource.namePrefix) Tap \(uuid.uuidString.prefix(8))"
        desc.isPrivate = true
        switch muteBehavior {
        case .unmuted: desc.muteBehavior = .unmuted
        case .muted: desc.muteBehavior = .muted
        case .mutedWhenTapped: desc.muteBehavior = .mutedWhenTapped
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            let msg = "AudioHardwareCreateProcessTap: \(CAProp.fourCC(tapStatus))"
            setStatus { $0.permission = .denied(msg) }
            throw AppAudioTapSource.TapError.tapCreationFailed(msg)
        }
        TapRegistry.shared.add(tapID)

        guard let asbd = CAProp.scalar(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mSampleRate > 0
        else {
            AudioHardwareDestroyProcessTap(tapID)
            TapRegistry.shared.remove(tapID)
            throw AppAudioTapSource.TapError.unsupportedTapFormat("tap format not Float32 PCM")
        }

        let outputUID = CAProp.defaultOutputDevice().flatMap(CAProp.deviceUID)
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(AppAudioTapSource.namePrefix) Capture \(uuid.uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: AppAudioTapSource.aggregateUIDPrefix + uuid.uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: uuid.uuidString,
            ]],
        ]
        if let outputUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            TapRegistry.shared.remove(tapID)
            throw AppAudioTapSource.TapError.aggregateCreationFailed(CAProp.fourCC(aggStatus))
        }
        TapRegistry.shared.add(aggID)

        let s = TapSession(tapID: tapID, tapUUID: uuid, aggregateID: aggID, sampleRate: asbd.mSampleRate,
                           outputDeviceUID: outputUID, processObjects: objects)
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, _, _ in
            s.handleInput(inInputData)
        }
        guard ioStatus == noErr, let procID else {
            destroy(s)
            throw AppAudioTapSource.TapError.ioStartFailed("AudioDeviceCreateIOProcIDWithBlock: \(CAProp.fourCC(ioStatus))")
        }
        s.ioProcID = procID
        s.formatListener = CAListener(object: tapID, selector: kAudioTapPropertyFormat, queue: controlQueue) {
            [weak self] in self?.scheduleRebuild(reason: "tap format")
        }

        // Hand the new session to the converter thread before IO starts.
        sessionLock.withLock { workerSession = s }
        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            sessionLock.withLock { workerSession = nil }
            destroy(s)
            throw AppAudioTapSource.TapError.ioStartFailed("AudioDeviceStart: \(CAProp.fourCC(startStatus))")
        }
        session = s
        lastIOCycles = 0
        ioStalledSince = nil
        silentSince = nil
        setStatus {
            $0.processObjects = objects
            $0.tapSampleRate = asbd.mSampleRate
            $0.outputDeviceUID = outputUID
        }
    }

    private func destroy(_ s: TapSession) {
        if let procID = s.ioProcID {
            AudioDeviceStop(s.aggregateID, procID)
            AudioDeviceDestroyIOProcID(s.aggregateID, procID)
            s.ioProcID = nil
        }
        s.formatListener?.cancel()
        s.formatListener = nil
        // Returns noErr synchronously; the device disappears from kAudioHardwarePropertyDevices
        // a few hundred ms later (HAL notifies asynchronously).
        AudioHardwareDestroyAggregateDevice(s.aggregateID)
        TapRegistry.shared.remove(s.aggregateID)
        AudioHardwareDestroyProcessTap(s.tapID)
        TapRegistry.shared.remove(s.tapID)
        sessionLock.withLock { if workerSession === s { workerSession = nil } }
    }

    private func watchdogTick() {
        guard running else { return }
        guard let s = session else { return }
        let cycles = s.ioCycles.load()
        let now = Date()
        if cycles > 0, cycles != lastIOCycles {
            ioStalledSince = nil
            if status.state != .capturing { setStatus { $0.state = .capturing } }
        } else if now.timeIntervalSince(s.createdAt) > 3 {
            if ioStalledSince == nil { ioStalledSince = now }
            if status.state == .capturing || status.state == .starting {
                setStatus { $0.state = .failed("tap IO not running") }
            }
        }
        lastIOCycles = cycles

        if s.nonSilentCycles.load() > 0 {
            silentSince = nil
            if status.permission != .granted { setStatus { $0.permission = .granted } }
            return
        }
        guard status.permission != .granted, cycles > 0 else { return }
        // Only exact zeros so far. Is anything we tap actually producing sound?
        let producing: Bool
        let procs = AudioProcessDirectory.snapshot()
        switch target {
        case .systemExcludingSelf:
            let excluded = Set(s.processObjects)
            producing = procs.contains { $0.isRunningOutput && !$0.isCurrentProcess && !excluded.contains($0.objectID) }
        case .apps, .processObjects:
            let included = Set(s.processObjects)
            producing = procs.contains { $0.isRunningOutput && included.contains($0.objectID) }
        }
        if producing {
            if silentSince == nil { silentSince = now }
            if let since = silentSince, now.timeIntervalSince(since) >= 3 {
                setStatus { $0.permission = .likelySilencedByTCC }
            }
        } else {
            silentSince = nil
        }
    }

    // MARK: Converter thread

    private func startWorker() {
        guard workerThread == nil else { return }
        // A previous worker may still be finishing its last iteration; it exits as soon as it
        // sees the generation change, and we wait for that so the rings keep a single
        // producer / consumer.
        let previousExited = workerExited
        while !previousExited.load() { usleep(1_000) }
        let gen = workerGeneration.add(1)
        let exited = AtomicBool(false)
        workerExited = exited
        let t = Thread { [weak self] in
            self?.workerLoop(generation: gen)
            exited.store(true)
        }
        t.name = "Multicast.AppAudioTap.converter"
        t.qualityOfService = .userInteractive
        workerThread = t
        t.start()
    }

    private func stopWorker() {
        workerGeneration.add(1)
        workerThread = nil
    }

    private func workerLoop(generation: Int64) {
        let workerRun = WorkerGate(generation: generation, current: workerGeneration)
        let chunk = 2048
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { scratch.deallocate() }
        var converter: PipelineConverter?
        var converterSession: TapSession?
        while workerRun.load() {
            let s: TapSession? = sessionLock.withLock { workerSession }
            guard let s else {
                converter = nil
                converterSession = nil
                usleep(10_000)
                continue
            }
            if converterSession !== s {
                converter = try? PipelineConverter(inputSampleRate: s.sampleRate, maxInputFrames: chunk)
                converterSession = s
            }
            guard let conv = converter else { usleep(10_000); continue }
            var didWork = false
            while workerRun.load() {
                let n = s.floatRing.read(into: scratch, frames: chunk)
                if n == 0 { break }
                didWork = true
                try? conv.convert(interleaved: scratch, frames: n) { ptr, frames in
                    let w = pcmRing.write(ptr, frames: frames)
                    if w < frames { outputOverflow.add(Int64(frames - w)) }
                }
            }
            if !didWork { usleep(4_000) }
        }
    }
}
#endif
