#if os(macOS)
import AppKit
import CoreAudio
import Darwin
import Foundation

/// One client process of the Core Audio server, as listed by
/// `kAudioHardwarePropertyProcessObjectList`.
public struct AudioProcessInfo: Sendable, Hashable, Identifiable {
    /// The Core Audio process object (what `CATapDescription` takes).
    public let objectID: AudioObjectID
    public let pid: pid_t
    /// Bundle id Core Audio reports for the process (helpers have their own, e.g.
    /// "com.google.Chrome.helper").
    public let bundleID: String?
    /// Display name of the app the user would recognise (the outermost enclosing .app).
    public let name: String
    /// The outermost enclosing .app bundle (use with NSWorkspace.icon(forFile:)).
    public let appBundleURL: URL?
    /// Bundle id of `appBundleURL` (e.g. "com.google.Chrome" for its helpers).
    public let appBundleID: String?
    public let executablePath: String?
    public let isRunning: Bool
    public let isRunningOutput: Bool
    public let isRunningInput: Bool
    /// True for this process (Multicast itself).
    public let isCurrentProcess: Bool

    public var id: AudioObjectID { objectID }

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, name: String, appBundleURL: URL?,
                appBundleID: String?, executablePath: String?, isRunning: Bool, isRunningOutput: Bool,
                isRunningInput: Bool, isCurrentProcess: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.appBundleURL = appBundleURL
        self.appBundleID = appBundleID
        self.executablePath = executablePath
        self.isRunning = isRunning
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
        self.isCurrentProcess = isCurrentProcess
    }

    /// Whether this process belongs to the app `bundleID` (exact match, a helper such as
    /// "<bundleID>.helper", or a process inside that app's bundle).
    public func belongs(toApp bundleID: String) -> Bool {
        AudioProcessDirectory.bundleID(self.bundleID, matchesApp: bundleID)
            || AudioProcessDirectory.bundleID(appBundleID, matchesApp: bundleID)
    }
}

/// Lists the processes Core Audio knows about and publishes updates as apps start or stop
/// audio. Feeds the source picker.
public final class AudioProcessDirectory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Multicast.AudioProcessDirectory")
    private var listListener: CAListener?
    private var processListeners: [AudioObjectID: [CAListener]] = [:]
    private var continuations: [UUID: AsyncStream<[AudioProcessInfo]>.Continuation] = [:]
    private var lastSnapshot: [AudioProcessInfo] = []
    private var pendingPublish = false

    public init() {}

    deinit {
        listListener?.cancel()
        for ls in processListeners.values { ls.forEach { $0.cancel() } }
        for c in continuations.values { c.finish() }
    }

    // MARK: Static queries

    /// All process objects currently registered with Core Audio.
    public static func snapshot() -> [AudioProcessInfo] {
        CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyProcessObjectList).compactMap(info(for:))
    }

    /// Only processes that are currently producing output.
    public static func activeOutputProcesses() -> [AudioProcessInfo] {
        snapshot().filter { $0.isRunningOutput }
    }

    /// The process object for `pid`, or nil if that process is not a Core Audio client.
    public static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        CAProp.processObject(forPID: pid)
    }

    /// This process's own process object (nil until it has become a Core Audio client).
    public static func currentProcessObject() -> AudioObjectID? {
        CAProp.processObject(forPID: getpid())
    }

    /// Process objects that belong to app `bundleID` (including its helpers).
    public static func processObjects(forApp bundleID: String) -> [AudioObjectID] {
        snapshot().filter { $0.belongs(toApp: bundleID) }.map(\.objectID)
    }

    public static func info(for object: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = CAProp.scalar(object, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
        let bundleID = CAProp.string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
        let running = (CAProp.uint32(object, kAudioProcessPropertyIsRunning) ?? 0) != 0
        let out = (CAProp.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
        let inp = (CAProp.uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        let path = executablePath(pid: pid)
        let appURL = path.flatMap { outermostAppBundle(containing: $0) }
        let appBundle = appURL.flatMap { Bundle(url: $0) }
        let appBundleID = appBundle?.bundleIdentifier
        let name = displayName(pid: pid, appBundle: appBundle, executablePath: path, bundleID: bundleID)
        return AudioProcessInfo(
            objectID: object, pid: pid, bundleID: bundleID, name: name, appBundleURL: appURL,
            appBundleID: appBundleID, executablePath: path, isRunning: running, isRunningOutput: out,
            isRunningInput: inp, isCurrentProcess: pid == getpid())
    }

    // MARK: Pure helpers (tested)

    /// "com.spotify.client" matches "com.spotify.client" and "com.spotify.client.helper…",
    /// never "com.spotify.clientX".
    public static func bundleID(_ candidate: String?, matchesApp app: String) -> Bool {
        guard let c = candidate?.lowercased(), !app.isEmpty else { return false }
        let a = app.lowercased()
        return c == a || c.hasPrefix(a + ".")
    }

    /// The OUTERMOST ".app" directory in `path` (helpers live in nested .apps inside the main one).
    public static func outermostAppBundle(containing path: String) -> URL? {
        let components = (path as NSString).pathComponents
        var acc: [String] = []
        for c in components {
            acc.append(c)
            if c.lowercased().hasSuffix(".app") {
                return URL(fileURLWithPath: NSString.path(withComponents: acc), isDirectory: true)
            }
        }
        return nil
    }

    // MARK: Private

    private static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private static func displayName(pid: pid_t, appBundle: Bundle?, executablePath: String?, bundleID: String?) -> String {
        if let b = appBundle {
            if let n = b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !n.isEmpty { return n }
            if let n = b.object(forInfoDictionaryKey: "CFBundleName") as? String, !n.isEmpty { return n }
            return b.bundleURL.deletingPathExtension().lastPathComponent
        }
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName, !n.isEmpty { return n }
        if let p = executablePath { return (p as NSString).lastPathComponent }
        return bundleID ?? "pid \(pid)"
    }

    // MARK: Updates

    /// Current list now, then a new list whenever a process appears/disappears or starts/stops IO.
    public var updates: AsyncStream<[AudioProcessInfo]> {
        AsyncStream { continuation in
            let token = UUID()
            queue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                self.continuations[token] = continuation
                self.startListeningIfNeeded()
                continuation.yield(self.lastSnapshot)
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async {
                    self?.continuations[token] = nil
                    if self?.continuations.isEmpty == true { self?.stopListening() }
                }
            }
        }
    }

    private func startListeningIfNeeded() {
        guard listListener == nil else { return }
        listListener = CAListener(object: CAProp.system, selector: kAudioHardwarePropertyProcessObjectList, queue: queue) {
            [weak self] in self?.processListChanged()
        }
        refreshProcessListeners()
        lastSnapshot = Self.snapshot()
    }

    private func stopListening() {
        listListener?.cancel()
        listListener = nil
        for ls in processListeners.values { ls.forEach { $0.cancel() } }
        processListeners = [:]
    }

    private func processListChanged() {
        refreshProcessListeners()
        schedulePublish()
    }

    private func refreshProcessListeners() {
        let ids = Set(CAProp.objectIDs(CAProp.system, kAudioHardwarePropertyProcessObjectList))
        for gone in processListeners.keys where !ids.contains(gone) {
            processListeners[gone]?.forEach { $0.cancel() }
            processListeners[gone] = nil
        }
        for id in ids where processListeners[id] == nil {
            var ls: [CAListener] = []
            for sel in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunning] {
                if let l = CAListener(object: id, selector: sel, queue: queue, handler: { [weak self] in self?.schedulePublish() }) {
                    ls.append(l)
                }
            }
            processListeners[id] = ls
        }
    }

    /// Coalesces bursts of property notifications into one published snapshot.
    private func schedulePublish() {
        guard !pendingPublish else { return }
        pendingPublish = true
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self else { return }
            self.pendingPublish = false
            let snap = Self.snapshot()
            guard snap != self.lastSnapshot else { return }
            self.lastSnapshot = snap
            for c in self.continuations.values { c.yield(snap) }
        }
    }
}
#endif
