import Foundation
import Network
import dnssd
import MulticastAudio

/// Finds every AirPlay speaker on the LAN and publishes them as `SpeakerDescriptor` snapshots.
///
/// Implementation: DNS-SD (`dnssd`, i.e. mDNSResponder) browses `_raop._tcp` and `_airplay._tcp`
/// on all interfaces. Every (instance, interface) the browse reports gets its own long-lived
/// `DNSServiceResolve`, which keeps delivering SRV/TXT changes for as long as it runs — so a bridge
/// that comes back on a new port is picked up without a restart, and a browse "remove" followed
/// by "add" restarts the resolve from scratch. Records of one device are merged by
/// `SpeakerCatalog.merge`.
///
/// Threading: all DNS-SD callbacks and all mutable state live on one private serial queue.
/// `start()` / `stop()` may be called from any thread (not from inside a snapshot consumer that
/// runs on that queue — there is none: snapshots are delivered through `AsyncStream`).
/// Nothing here runs on an audio thread.
///
/// iOS: the host app needs `NSBonjourServices` = [`_raop._tcp`, `_airplay._tcp`] and
/// `NSLocalNetworkUsageDescription` in its Info.plist.
public final class SpeakerBrowser: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Hide this machine's own AirPlay receiver (default `true`).
        public var hideThisMachine: Bool = true
        /// Extra device ids (any separator style) that should count as "this machine".
        public var additionalLocalDeviceIDs: Set<String> = []
        public var domain: String = "local."
        /// Changes within this window are coalesced into one snapshot.
        public var coalescing: DispatchTimeInterval = .milliseconds(150)
        /// Delay before re-creating a browse/resolve that failed (e.g. mDNSResponder restarted).
        public var retryDelay: DispatchTimeInterval = .seconds(2)
        /// Optional diagnostics sink (called on the browser's private queue; keep it cheap).
        public var log: (@Sendable (String) -> Void)?

        public init(hideThisMachine: Bool = true, additionalLocalDeviceIDs: Set<String> = [],
                    log: (@Sendable (String) -> Void)? = nil) {
            self.hideThisMachine = hideThisMachine
            self.additionalLocalDeviceIDs = additionalLocalDeviceIDs
            self.log = log
        }
    }

    public let configuration: Configuration

    // MARK: State (queue-confined)

    private let queue = DispatchQueue(label: "multicast.discovery.browser", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()

    fileprivate struct InstanceKey: Hashable {
        var type: AirPlayServiceType
        var name: String
        var domain: String
        var interfaceIndex: UInt32
    }

    fileprivate final class BrowseContext {
        weak var browser: SpeakerBrowser?
        let type: AirPlayServiceType
        let generation: Int
        var ref: DNSServiceRef?
        init(browser: SpeakerBrowser, type: AirPlayServiceType, generation: Int) {
            self.browser = browser
            self.type = type
            self.generation = generation
        }
    }

    fileprivate final class ResolveContext {
        weak var browser: SpeakerBrowser?
        let key: InstanceKey
        let regtype: String
        let generation: Int
        var ref: DNSServiceRef?
        var result: ResolvedService?
        var sequence: UInt64 = 0
        init(browser: SpeakerBrowser, key: InstanceKey, regtype: String, generation: Int) {
            self.browser = browser
            self.key = key
            self.regtype = regtype
            self.generation = generation
        }
    }

    private var running = false
    /// Bumped on every start/stop/restart so stale callbacks and timers are ignored.
    private var generation = 0
    private var browses: [AirPlayServiceType: BrowseContext] = [:]
    /// Instances the browse currently reports, with the regtype string to resolve them with.
    private var present: [InstanceKey: String] = [:]
    private var resolves: [InstanceKey: ResolveContext] = [:]
    private var sequenceCounter: UInt64 = 0
    private var publishScheduled = false
    private var snapshot: [SpeakerDescriptor] = []
    private var subscribers: [UUID: AsyncStream<[SpeakerDescriptor]>.Continuation] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastInterfaceNames: Set<String> = []
    private var lastErrorCode: Int32?
    private let loopbackIndex: UInt32 = if_nametoindex("lo0")

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        // No callbacks can reference `self` after this: contexts hold it weakly and refs are
        // deallocated here on the queue.
        let work = { [browses, resolves, subscribers] in
            for ctx in browses.values { if let ref = ctx.ref { DNSServiceRefDeallocate(ref) } }
            for ctx in resolves.values { if let ref = ctx.ref { DNSServiceRefDeallocate(ref) } }
            for c in subscribers.values { c.finish() }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.sync(execute: work) }
        pathMonitor?.cancel()
    }

    // MARK: Public API

    /// Start browsing. Calling it while running is a no-op; calling it after `stop()` restarts.
    public func start() {
        onQueue {
            guard !self.running else { return }
            self.running = true
            LocalMachineIdentity.refreshHostNames()
            self.startPathMonitor()
            self.startBrowsing()
        }
    }

    /// Stop browsing and release every DNS-SD operation. Subscribers stay attached and receive an
    /// empty snapshot; a later `start()` resumes publishing to them. Safe to call repeatedly.
    public func stop() {
        onQueue {
            guard self.running else { return }
            self.running = false
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.tearDown()
            self.publishNow()
        }
    }

    public var isRunning: Bool { onQueue { running } }

    /// The latest published snapshot (sorted by name).
    public var currentSpeakers: [SpeakerDescriptor] { onQueue { snapshot } }

    /// The last DNS-SD error code seen (e.g. -65563 kDNSServiceErr_ServiceNotRunning,
    /// -65570 kDNSServiceErr_PolicyDenied when local-network access is refused), if any.
    public var lastError: Int32? { onQueue { lastErrorCode } }

    /// A new stream of snapshots. It immediately yields the current snapshot, then every change.
    /// Only the newest snapshot is buffered if the consumer is slow. Finishes when the browser
    /// is deallocated or the consumer cancels.
    public var snapshots: AsyncStream<[SpeakerDescriptor]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            self.onQueue {
                self.subscribers[id] = continuation
                continuation.yield(self.snapshot)
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.subscribers[id] = nil }
            }
        }
    }

    // MARK: Browsing

    private func startBrowsing() {
        generation += 1
        for type in AirPlayServiceType.allCases {
            let ctx = BrowseContext(browser: self, type: type, generation: generation)
            var ref: DNSServiceRef?
            let err = DNSServiceBrowse(&ref, 0, 0, type.rawValue, configuration.domain,
                                       speakerBrowserBrowseReply, Unmanaged.passUnretained(ctx).toOpaque())
            guard err == kDNSServiceErr_NoError, let ref else {
                fail("DNSServiceBrowse(\(type.rawValue)) failed: \(err)", code: err)
                return
            }
            let qErr = DNSServiceSetDispatchQueue(ref, queue)
            guard qErr == kDNSServiceErr_NoError else {
                DNSServiceRefDeallocate(ref)
                fail("DNSServiceSetDispatchQueue failed: \(qErr)", code: qErr)
                return
            }
            ctx.ref = ref
            browses[type] = ctx
        }
        log("browsing \(AirPlayServiceType.allCases.map(\.rawValue)) in \(configuration.domain)")
    }

    private func tearDown() {
        generation += 1
        for ctx in browses.values { if let ref = ctx.ref { DNSServiceRefDeallocate(ref) }; ctx.ref = nil }
        for ctx in resolves.values { if let ref = ctx.ref { DNSServiceRefDeallocate(ref) }; ctx.ref = nil }
        browses.removeAll()
        resolves.removeAll()
        present.removeAll()
    }

    /// Tear everything down and start again after `retryDelay` (daemon restart, fatal error).
    private func fail(_ message: String, code: Int32) {
        lastErrorCode = code
        log(message)
        tearDown()
        schedulePublish()
        let gen = generation
        queue.asyncAfter(deadline: .now() + configuration.retryDelay) { [weak self] in
            guard let self, self.running, self.generation == gen else { return }
            self.log("restarting browse after error \(code)")
            self.startBrowsing()
        }
    }

    fileprivate func handleBrowse(_ ctx: BrowseContext, flags: DNSServiceFlags, interfaceIndex: UInt32,
                                  error: DNSServiceErrorType, name: String, regtype: String, domain: String) {
        guard running, ctx.generation == generation else { return }
        guard error == kDNSServiceErr_NoError else {
            fail("browse \(ctx.type.rawValue) error \(error)", code: error)
            return
        }
        let key = InstanceKey(type: ctx.type, name: name, domain: domain, interfaceIndex: interfaceIndex)
        if flags & kDNSServiceFlagsAdd != 0 {
            log("+ \(ctx.type.rawValue) \"\(name)\" if=\(interfaceIndex)")
            present[key] = regtype
            if isLoopback(interfaceIndex), ctx.type == .raop, let id = RAOPInstanceName(name).deviceID {
                LocalMachineIdentity.noteLocalDeviceID(id)
            }
            startResolve(key, regtype: regtype) // (re)start: a re-add may carry a new port
        } else {
            log("- \(ctx.type.rawValue) \"\(name)\" if=\(interfaceIndex)")
            present[key] = nil
            cancelResolve(key)
            schedulePublish()
        }
    }

    // MARK: Resolving

    private func startResolve(_ key: InstanceKey, regtype: String) {
        cancelResolve(key)
        let ctx = ResolveContext(browser: self, key: key, regtype: regtype, generation: generation)
        var ref: DNSServiceRef?
        let err = DNSServiceResolve(&ref, 0, key.interfaceIndex, key.name, regtype, key.domain,
                                    speakerBrowserResolveReply, Unmanaged.passUnretained(ctx).toOpaque())
        guard err == kDNSServiceErr_NoError, let ref else {
            lastErrorCode = err
            log("DNSServiceResolve(\(key.name)) failed: \(err)")
            scheduleResolveRetry(key)
            return
        }
        guard DNSServiceSetDispatchQueue(ref, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            scheduleResolveRetry(key)
            return
        }
        ctx.ref = ref
        resolves[key] = ctx
    }

    private func cancelResolve(_ key: InstanceKey) {
        guard let ctx = resolves.removeValue(forKey: key) else { return }
        if let ref = ctx.ref { DNSServiceRefDeallocate(ref) }
        ctx.ref = nil
        if ctx.result != nil { schedulePublish() }
    }

    private func scheduleResolveRetry(_ key: InstanceKey) {
        let gen = generation
        queue.asyncAfter(deadline: .now() + configuration.retryDelay) { [weak self] in
            guard let self, self.running, self.generation == gen,
                  let regtype = self.present[key], self.resolves[key] == nil else { return }
            self.startResolve(key, regtype: regtype)
        }
    }

    fileprivate func handleResolve(_ ctx: ResolveContext, interfaceIndex: UInt32, error: DNSServiceErrorType,
                                   host: String, port: UInt16, txt: [String: String]) {
        guard running, ctx.generation == generation, resolves[ctx.key] === ctx else { return }
        guard error == kDNSServiceErr_NoError else {
            lastErrorCode = error
            log("resolve \"\(ctx.key.name)\" error \(error)")
            cancelResolve(ctx.key)
            if error == kDNSServiceErr_ServiceNotRunning {
                fail("mDNSResponder not running", code: error)
            } else {
                scheduleResolveRetry(ctx.key)
            }
            return
        }
        let service = ResolvedService(
            type: ctx.key.type, instanceName: ctx.key.name, domain: ctx.key.domain,
            host: host, port: port, txt: txt, interfaceIndex: ctx.key.interfaceIndex,
            seenOnLoopback: isLoopback(ctx.key.interfaceIndex))
        if service.seenOnLoopback { LocalMachineIdentity.noteLocalDeviceID(service.deviceKey) }
        guard service != ctx.result else { return }
        if let old = ctx.result, old.port != service.port || old.host != service.host {
            log("~ \"\(ctx.key.name)\" moved \(old.host):\(old.port) -> \(service.host):\(service.port)")
        } else {
            log("= \"\(ctx.key.name)\" \(service.host):\(service.port) if=\(ctx.key.interfaceIndex)")
        }
        sequenceCounter += 1
        ctx.sequence = sequenceCounter
        ctx.result = service
        schedulePublish()
    }

    private func isLoopback(_ interfaceIndex: UInt32) -> Bool {
        interfaceIndex == kDNSServiceInterfaceIndexLocalOnly || (loopbackIndex != 0 && interfaceIndex == loopbackIndex)
    }

    // MARK: Publishing

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + configuration.coalescing) { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.publishNow()
        }
    }

    private func publishNow() {
        // Oldest first so the freshest record of each (device, type) wins in the merge.
        let records = resolves.values.compactMap { ctx in ctx.result.map { (ctx.sequence, $0) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
        var identity = LocalMachineIdentity.current
        identity.deviceIDs.formUnion(configuration.additionalLocalDeviceIDs.compactMap(DeviceID.normalize))
        let next = running
            ? SpeakerCatalog.merge(records, hideThisMachine: configuration.hideThisMachine, localMachine: identity)
            : []
        guard next != snapshot else { return }
        snapshot = next
        for c in subscribers.values { c.yield(next) }
    }

    // MARK: Interface changes

    /// mDNSResponder reports per-interface adds/removes itself; the path monitor additionally
    /// refreshes this machine's host names and re-resolves everything when the set of usable
    /// interfaces changes (e.g. Wi-Fi rejoin, Ethernet plugged), so stale SRV targets cannot linger.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let names = Set(path.availableInterfaces.map(\.name))
            guard self.running, names != self.lastInterfaceNames else { return }
            let first = self.lastInterfaceNames.isEmpty
            self.lastInterfaceNames = names
            guard !first else { return }
            self.log("interfaces changed: \(names.sorted())")
            LocalMachineIdentity.refreshHostNames()
            for (key, regtype) in self.present { self.startResolve(key, regtype: regtype) }
            self.schedulePublish()
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    // MARK: Helpers

    private func log(_ message: @autoclosure () -> String) {
        configuration.log?(message())
    }

    @discardableResult
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    // MARK: C trampolines

    fileprivate static func browseContext(_ raw: UnsafeMutableRawPointer?) -> BrowseContext? {
        raw.map { Unmanaged<BrowseContext>.fromOpaque($0).takeUnretainedValue() }
    }

    fileprivate static func resolveContext(_ raw: UnsafeMutableRawPointer?) -> ResolveContext? {
        raw.map { Unmanaged<ResolveContext>.fromOpaque($0).takeUnretainedValue() }
    }
}

// The contexts are retained by the browser's dictionaries for exactly as long as their
// DNSServiceRef exists; refs are deallocated on the queue before the context is released, and
// DNS-SD never calls back after DNSServiceRefDeallocate returns on the callback queue.

private let speakerBrowserBrowseReply: DNSServiceBrowseReply = { _, flags, interfaceIndex, error, name, regtype, domain, context in
    guard let ctx = SpeakerBrowser.browseContext(context), let browser = ctx.browser else { return }
    browser.handleBrowse(ctx, flags: flags, interfaceIndex: interfaceIndex, error: error,
                         name: name.map { String(cString: $0) } ?? "",
                         regtype: regtype.map { String(cString: $0) } ?? ctx.type.rawValue,
                         domain: domain.map { String(cString: $0) } ?? "local.")
}

private let speakerBrowserResolveReply: DNSServiceResolveReply = { _, _, interfaceIndex, error, _, host, port, txtLen, txt, context in
    guard let ctx = SpeakerBrowser.resolveContext(context), let browser = ctx.browser else { return }
    let txtDict: [String: String]
    if let txt, txtLen > 0 {
        txtDict = TXTRecord.decode(UnsafeRawBufferPointer(start: txt, count: Int(txtLen)))
    } else {
        txtDict = [:]
    }
    browser.handleResolve(ctx, interfaceIndex: interfaceIndex, error: error,
                          host: host.map { String(cString: $0) } ?? "",
                          port: UInt16(bigEndian: port), txt: txtDict)
}
