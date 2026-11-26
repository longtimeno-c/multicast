import Foundation
import MulticastHubModel
import MulticastRemote

// multicast-remote-cli — a scripted iPhone remote for a running Multicast hub.
//
// It connects exactly as the iPhone app does (Bonjour, pairing, the encrypted session) through
// `RemoteHubBackend`, runs a list of steps, and prints every hub state change it sees, so a run
// is a record of what a remote observed. Used to verify the hub end to end without a phone.
//
//   multicast-remote-cli hubs [--seconds 5]
//   multicast-remote-cli run --hub <name|id> [--store <file>] [--code-file <file>] [--name <remote name>] <step>…
//
// Steps (run in order; each waits for its effect where that is observable):
//   pair                 pair if the hub asks; the code is read from --code-file (the hub writes it
//                        there when started with --pairing-code-log <file>)
//   list                 print the hub's speakers
//   wait-speakers=A,B    wait until speakers A and B are listed (name, unique prefix or id)
//   volume=A:0.1         set speaker A's volume (a preset while it is off)
//   on=A / off=A         turn speaker A on / off
//   expect=A:playing     wait until speaker A is in that state (off|connecting|ready|playing|failed)
//   master=0.8           master volume
//   source=files         select a source (appleMusic|spotify|app|files)
//   try-source=spotify   the same, printing a refusal instead of failing
//   play-file=TEXT       play the first file in Files whose title contains TEXT
//   play / pause / next / previous
//   expect-playing / expect-paused
//   sleep=SECONDS
//   files / health       print the Files list / the health flags
//   play-song=TEXT       search the library for TEXT and play the first hit (Up Next: the other hits)
//   queue-song=TEXT      search the library for TEXT and add the first hit to the queue
//   queue-spotify=LINK   add a Spotify song link or spotify:track: URI to the queue
//   upnext               print the hub's Up Next
//   clear-queue          empty Up Next
//   expect-title=TEXT    wait (up to 45 s) until the song playing has TEXT in its title
//   seek-end=SECONDS     seek to SECONDS before the end of the song playing
//   keep-upnext=N        remove all but the first N songs of Up Next
//   queue-spotify=current  queue the song Spotify played most recently this session
//   playlists            print the hub's playlists as a tree (folders indented)
//   request=automation   show the hub's permission prompt and wait for the answer
//   expect-advance       wait (up to 60 s) until the queue moves to another song, or ends
//
// Exit codes: 0 every step done, 1 a step failed, 2 usage.

setvbuf(stdout, nil, _IOLBF, 0)

let started = Date()
func stamp() -> String { String(format: "+%6.2fs", Date().timeIntervalSince(started)) }
func say(_ s: String) { print("\(stamp()) \(s)") }
func fail(_ s: String) -> Never {
    say("FAILED: \(s)")
    exit(1)
}

struct Usage: Error {}

// MARK: - State watching

/// The latest hub state, plus a printed line for every change a person would care about.
actor StateLog {
    private(set) var state: HubState?
    private var waiters: [(id: UUID, check: (HubState) -> Bool, c: CheckedContinuation<Bool, Never>)] = []

    func apply(_ s: HubState) {
        let old = state
        state = s
        for line in Self.changes(from: old, to: s) { say("state r\(s.revision): \(line)") }
        var remaining: [(id: UUID, check: (HubState) -> Bool, c: CheckedContinuation<Bool, Never>)] = []
        for w in waiters { if w.check(s) { w.c.resume(returning: true) } else { remaining.append(w) } }
        waiters = remaining
    }

    /// Waits up to `timeout` for `check` to hold.
    func wait(timeout: TimeInterval, _ check: @escaping @Sendable (HubState) -> Bool) async -> Bool {
        if let state, check(state) { return true }
        let id = UUID()
        return await withCheckedContinuation { c in
            waiters.append((id, check, c))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).c.resume(returning: false)
    }

    static func describe(_ st: SpeakerState) -> String {
        switch st {
        case .off: "off"
        case .connecting: "connecting"
        case .ready: "ready"
        case .playing: "playing"
        case .failed(let r): "failed(\(r))"
        }
    }

    static func changes(from old: HubState?, to new: HubState) -> [String] {
        var out: [String] = []
        let before = Dictionary((old?.speakers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in new.speakers {
            guard let o = before[s.id] else {
                out.append("speaker found \"\(s.name)\" [\(s.transport.rawValue)] \(describe(s.state)) vol=\(fmt(s.volume))")
                continue
            }
            if o.state != s.state { out.append("\"\(s.name)\" \(describe(o.state)) -> \(describe(s.state))") }
            if o.volume != s.volume { out.append("\"\(s.name)\" volume \(fmt(o.volume)) -> \(fmt(s.volume))") }
            if o.isEnabled != s.isEnabled { out.append("\"\(s.name)\" enabled \(o.isEnabled) -> \(s.isEnabled)") }
            if o.syncTrimMs != s.syncTrimMs { out.append("\"\(s.name)\" trim \(o.syncTrimMs) -> \(s.syncTrimMs) ms") }
        }
        let ids = Set(new.speakers.map(\.id))
        for (id, o) in before where !ids.contains(id) { out.append("speaker lost \"\(o.name)\"") }
        if old?.masterVolume != new.masterVolume { out.append("master \(fmt(new.masterVolume))") }
        if old?.activeSource != new.activeSource { out.append("source \(new.activeSource?.rawValue ?? "none")") }
        if old?.transport.isPlaying != new.transport.isPlaying { out.append(new.transport.isPlaying ? "transport playing" : "transport paused") }
        if old?.nowPlaying?.identity != new.nowPlaying?.identity {
            out.append("now playing \(new.nowPlaying.map { "\"\($0.title)\" by \($0.artist)" } ?? "nothing")")
        }
        if old?.queue != new.queue {
            let q = new.queue
            out.append("queue current=\(q.currentID ?? "none") from=\(q.currentSource?.rawValue ?? "-") upNext=\(q.upcomingCount) held=\(q.isHeld)")
        }
        if old?.isDiscovering != new.isDiscovering { out.append("discovering \(new.isDiscovering)") }
        if old?.health != new.health { out.append("health \(healthLine(new.health))") }
        return out
    }

    static func healthLine(_ h: HubHealth) -> String {
        let p = h.permissions
        return "localNetwork=\(p.localNetwork.rawValue) audioCapture=\(p.audioCapture.rawValue) appleMusic=\(p.appleMusic.rawValue) automation=\(p.automation.rawValue) issues=\(h.issues.count)"
    }
}

func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

// MARK: - Commands

func listHubs(seconds: Double) async {
    let stream = HubBrowser().hubs()
    var latest: [DiscoveredHub] = []
    let reader = Task { for await hubs in stream { latest = hubs } }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    reader.cancel()
    if latest.isEmpty { print("No hubs found.") }
    for h in latest { print("\(h.name)\tid=\(h.id)\tprotocol=\(h.protocolVersion.map(String.init) ?? "?")") }
}

func findHub(_ query: String, timeout: TimeInterval) async -> DiscoveredHub? {
    let stream = HubBrowser().hubs()
    let deadline = Date().addingTimeInterval(timeout)
    let finder = Task { () -> DiscoveredHub? in
        for await hubs in stream {
            if let h = hubs.first(where: { $0.id == query || $0.name == query })
                ?? hubs.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) { return h }
            if Date() > deadline { return nil }
        }
        return nil
    }
    let timer = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); finder.cancel() }
    let found = await finder.value
    timer.cancel()
    return found
}

func speaker(_ query: String, in state: HubState) -> SpeakerItem? {
    let all = state.speakers
    if let s = all.first(where: { $0.id.rawValue == query || $0.name == query }) { return s }
    let prefixed = all.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
    return prefixed.count == 1 ? prefixed[0] : nil
}

func parseState(_ s: String) -> ((SpeakerState) -> Bool)? {
    switch s {
    case "off": return { $0 == .off }
    case "connecting": return { $0 == .connecting }
    case "ready": return { $0 == .ready }
    case "playing": return { $0 == .playing }
    case "failed": return { if case .failed = $0 { true } else { false } }
    default: return nil
    }
}

func run(hubQuery: String, store: PairingKeyStore, codeFile: URL?, remoteName: String, remoteID: String, steps: [String]) async {
    say("looking for hub \"\(hubQuery)\"")
    guard let hub = await findHub(hubQuery, timeout: 15) else { fail("no hub matching \"\(hubQuery)\" on the network") }
    say("found hub \"\(hub.name)\" id=\(hub.id)")
    var config = RemoteHubBackend.Configuration(remoteID: remoteID, remoteName: remoteName, target: .hub(id: hub.id))
    config.deviceKind = "Mac (test client)"
    let backend = RemoteHubBackend(configuration: config, keyStore: store)
    let log = StateLog()
    let links = backend.connectionStates()
    let linkTask = Task {
        var last = ""
        for await l in links {
            let line = "\(l)"
            if line != last { say("link: \(line)"); last = line }
        }
    }
    let states = await backend.states()
    let stateTask = Task { for await s in states { await log.apply(s) } }

    func waitLink(_ timeout: TimeInterval, _ check: (RemoteConnectionState) -> Bool) async -> RemoteConnectionState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = backend.connectionState
            if check(s) { return s }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return backend.connectionState
    }
    func isConnected(_ s: RemoteConnectionState) -> Bool { if case .connected = s { true } else { false } }
    func needsPairing(_ s: RemoteConnectionState) -> Bool {
        switch s {
        case .pairingNeeded, .notRecognised: true
        default: false
        }
    }
    func send(_ c: HubCommand) async {
        do { try await backend.perform(c) } catch { fail("hub refused \(c): \(error)") }
    }
    func current() async -> HubState {
        guard let s = await log.state else { fail("no state from the hub yet") }
        return s
    }
    func resolve(_ name: String) async -> SpeakerItem {
        guard let s = speaker(name, in: await current()) else { fail("no single speaker matches \"\(name)\"") }
        return s
    }

    let first = await waitLink(20) { isConnected($0) || needsPairing($0) }
    if !isConnected(first) && !needsPairing(first) { fail("could not reach the hub: \(first)") }

    for step in steps {
        let (verb, arg): (String, String) = {
            if let i = step.firstIndex(of: "=") { return (String(step[..<i]), String(step[step.index(after: i)...])) }
            return (step, "")
        }()
        say("step \(step)")
        switch verb {
        case "pair":
            if isConnected(backend.connectionState) { say("already paired"); continue }
            guard let codeFile else { fail("pair needs --code-file") }
            let before = (try? FileManager.default.attributesOfItem(atPath: codeFile.path)[.modificationDate] as? Date) ?? .distantPast
            backend.startPairing()
            let asking = await waitLink(20) { if case .pairing(_, .enterCode) = $0 { true } else { false } }
            guard case .pairing(_, .enterCode) = asking else { fail("hub did not ask for a code: \(asking)") }
            var code: String?
            for _ in 0..<100 {
                let mod = (try? FileManager.default.attributesOfItem(atPath: codeFile.path)[.modificationDate] as? Date) ?? .distantPast
                if mod > before, let text = try? String(contentsOf: codeFile, encoding: .utf8) {
                    code = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let code else { fail("no new code appeared in \(codeFile.path)") }
            say("code read from the hub's code file (\(code.count) digits)")
            backend.submitPairingCode(code)
            let done = await waitLink(20) { isConnected($0) }
            guard isConnected(done) else { fail("pairing did not finish: \(done)") }
        case "list":
            for s in await current().speakers {
                say("  \"\(s.name)\" id=\(s.id) [\(s.transport.rawValue)] \(StateLog.describe(s.state)) on=\(s.isEnabled) vol=\(fmt(s.volume)) trim=\(s.syncTrimMs)")
            }
        case "wait-speakers":
            let names = arg.split(separator: ",").map(String.init)
            let ok = await log.wait(timeout: 20) { st in names.allSatisfy { speaker($0, in: st) != nil } }
            if !ok { fail("not every speaker in \(names) appeared") }
        case "volume", "expect":
            guard let i = arg.lastIndex(of: ":") else { throw2() }
            let name = String(arg[..<i]), value = String(arg[arg.index(after: i)...])
            let s = await resolve(name)
            if verb == "volume" {
                guard let v = Double(value) else { throw2() }
                await send(.setSpeakerVolume(id: s.id, volume: v))
                let id = s.id
                if !(await log.wait(timeout: 5) { $0.speaker(id)?.volume == v }) { fail("volume of \(name) never became \(v)") }
            } else {
                guard let check = parseState(value) else { throw2() }
                let id = s.id
                if !(await log.wait(timeout: 15) { st in st.speaker(id).map { check($0.state) } ?? false }) {
                    fail("\(name) never reached \(value)")
                }
            }
        case "on", "off":
            let s = await resolve(arg)
            await send(.setSpeakerEnabled(id: s.id, enabled: verb == "on"))
            let id = s.id, want = verb == "on"
            if !(await log.wait(timeout: 5) { $0.speaker(id)?.isEnabled == want }) { fail("\(arg) never turned \(verb)") }
        case "master":
            guard let v = Double(arg) else { throw2() }
            await send(.setMasterVolume(volume: v))
        case "source":
            guard let k = SourceKind(rawValue: arg) else { throw2() }
            await send(.selectSource(source: k))
            if !(await log.wait(timeout: 10) { $0.activeSource == k }) { fail("source never became \(arg)") }
        case "try-source":
            // Like source=, but a refusal is printed rather than failing the run.
            guard let k = SourceKind(rawValue: arg) else { throw2() }
            do {
                try await backend.perform(.selectSource(source: k))
                let ok = await log.wait(timeout: 10) { $0.activeSource == k }
                say(ok ? "  source is now \(arg)" : "  hub accepted but source did not change")
            } catch {
                say("  hub refused: \(error.localizedDescription)")
            }
        case "files":
            let page = (try? await backend.files(PageRequest(limit: 100)))?.items ?? []
            for f in page { say("  file \"\(f.title)\" by \(f.artist) id=\(f.id)") }
        case "play-file":
            let page = (try? await backend.files(PageRequest(limit: 200)))?.items ?? []
            guard let f = page.first(where: { $0.title.localizedCaseInsensitiveContains(arg) }) else { fail("no file matching \"\(arg)\"") }
            await send(.playTrack(id: f.id, context: .files))
        case "play": await send(.play)
        case "pause": await send(.pause)
        case "next": await send(.next)
        case "previous": await send(.previous)
        case "expect-playing", "expect-paused":
            let want = verb == "expect-playing"
            if !(await log.wait(timeout: 10) { $0.transport.isPlaying == want }) { fail("transport never became \(want ? "playing" : "paused")") }
        case "sleep":
            guard let s = Double(arg) else { throw2() }
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
        case "play-song", "queue-song":
            let hits = (try? await backend.search(arg, PageRequest(limit: 50)))?.items ?? []
            guard let t = hits.first else { fail("no library song matching \"\(arg)\"") }
            say("  \"\(t.title)\" by \(t.artist) (\(Int(t.duration)) s)")
            if verb == "play-song" {
                await send(.playTrack(id: t.id, context: .search(query: arg)))
            } else {
                await send(.addToQueue(tracks: [t], source: .appleMusic, placement: .last))
            }
        case "queue-spotify" where arg == "current":
            let page = (try? await backend.spotifyHistory(PageRequest(limit: 20)))?.items ?? []
            guard let t = page.first(where: { $0.id.hasPrefix("spotify:track:") }) else { fail("Spotify hasn't played a song this session") }
            say("  \"\(t.title)\" by \(t.artist) (\(Int(t.duration)) s)")
            await send(.addToQueue(tracks: [t], source: .spotify, placement: .last))
        case "queue-spotify":
            await send(.addSpotifyLink(link: arg, placement: .last))
        case "keep-upnext":
            guard let n = Int(arg) else { throw2() }
            var all: [QueueItem] = []
            var request = PageRequest(limit: 500)
            while let page = try? await backend.upNext(request) {
                all += page.items
                guard let next = page.nextCursor else { break }
                request = PageRequest(cursor: next, limit: 500)
            }
            let drop = all.dropFirst(n).map(\.id)
            var i = 0
            while i < drop.count {
                await send(.removeFromQueue(ids: Array(drop[i..<min(i + 1000, drop.count)])))
                i += 1000
            }
        case "expect-advance":
            let before = await current().queue.currentID
            let started = Date()
            if !(await log.wait(timeout: 60) { $0.queue.currentID != before }) { fail("the queue never moved on") }
            let s = await current()
            say(String(format: "  moved after %.1f s to %@ (%@): %@", Date().timeIntervalSince(started),
                       s.queue.currentID ?? "end of queue", s.queue.currentSource?.rawValue ?? "-",
                       s.nowPlaying.map { "\"\($0.title)\"" } ?? "nothing"))
        case "upnext":
            let page = (try? await backend.upNext(PageRequest(limit: 50)))?.items ?? []
            for q in page { say("  \(q.id) [\(q.source.rawValue)] \"\(q.track.title)\" by \(q.track.artist)") }
            if page.isEmpty { say("  (empty)") }
        case "clear-queue":
            await send(.clearQueue)
        case "expect-title":
            let started = Date()
            if !(await log.wait(timeout: 45) { $0.nowPlaying?.title.localizedCaseInsensitiveContains(arg) ?? false }) {
                fail("\"\(arg)\" never started")
            }
            say(String(format: "  started after %.1f s", Date().timeIntervalSince(started)))
        case "seek-end":
            guard let before = Double(arg) else { throw2() }
            guard let d = await current().nowPlaying?.duration, d > before else { fail("the song playing has no known length") }
            await send(.seek(position: d - before))
        case "request":
            // Puts up the hub's permission prompt; a person at the Mac answers it.
            guard let perm = HubPermission(rawValue: arg) else { throw2() }
            await send(.requestPermission(permission: perm))
            say("  waiting up to 90 s for someone at the Mac to answer")
            if !(await log.wait(timeout: 90) { $0.health.permission(perm) != .notDetermined }) { say("  still not answered") }
            say("  \(arg) is \(await current().health.permission(perm).rawValue)")
        case "playlists":
            // The hub's playlist tree: folders, then what is in them, indented.
            var all: [PlaylistItem] = []
            var request = PageRequest(limit: 500)
            while let page = try? await backend.playlists(request) {
                all += page.items
                guard let next = page.nextCursor else { break }
                request = PageRequest(cursor: next, limit: 500)
            }
            let tree = PlaylistTree(all)
            func show(_ folder: String?, _ depth: Int) {
                for p in tree.items(in: folder) {
                    let pad = String(repeating: "  ", count: depth + 1)
                    say("\(pad)\(p.isFolder ? "[folder] " : "")\"\(p.name)\" \(p.trackCount) songs")
                    if p.isFolder { show(p.id, depth + 1) }
                }
            }
            say("  \(all.count) items, \(all.filter(\.isFolder).count) folders")
            show(nil, 0)
        case "health":
            let h = await current().health
            say("  \(StateLog.healthLine(h))")
            for i in h.issues { say("  issue \(i)") }
        default:
            throw2()
        }
    }
    say("all steps done")
    linkTask.cancel()
    stateTask.cancel()
    await backend.stop()
}

func throw2() -> Never {
    print("Bad step. See the header of Sources/multicast-remote-cli/main.swift.")
    exit(2)
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

switch args.first {
case "hubs":
    args.removeFirst()
    let seconds = option("--seconds").flatMap(Double.init) ?? 5
    await listHubs(seconds: seconds)
case "run":
    args.removeFirst()
    guard let hub = option("--hub") else { throw2() }
    let store: PairingKeyStore = option("--store").map { FilePairingKeyStore(url: URL(fileURLWithPath: $0)) } ?? InMemoryPairingKeyStore()
    let codeFile = option("--code-file").map { URL(fileURLWithPath: $0) }
    let name = option("--name") ?? "Test Remote"
    let id = option("--remote-id") ?? "multicast-remote-cli"
    await run(hubQuery: hub, store: store, codeFile: codeFile, remoteName: name, remoteID: id, steps: args)
default:
    print("usage: multicast-remote-cli hubs [--seconds N] | run --hub <name|id> [--store F] [--code-file F] [--name N] <steps…>")
    exit(2)
}
