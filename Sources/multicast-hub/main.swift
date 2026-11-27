import Foundation
import MulticastAppleMusic
import MulticastHub
import MulticastHubModel
import MulticastRemote

// multicast-hub — the Mac hub without its window: the same `LocalHub` (speakers, sources,
// engine) and `HubServer` (Bonjour, pairing, encrypted sessions for iPhone remotes) the app
// runs, in a terminal. For a Mac without a screen, and for scripted end-to-end checks.
//
//   multicast-hub [--name <shown to remotes>] [--add <audio file>]… [--store <keys.json>]
//                 [--pairing-code-log <file>] [--apple-music musicApp|musicKit|off]
//                 [--seconds <run time>] [--latency-ms 2000]
//
//   --store             keep pairing keys in this file (0600) instead of the Keychain
//   --pairing-code-log  also write each pairing code to this file (0600) for a script to read
//   --seconds           shut down cleanly after this long (default: until Ctrl-C / SIGTERM)
//
// Pairing codes are always printed on stdout ("PAIRING <name> <code>"), as the app shows them.
// Speaker settings (volumes, trims, which speakers are on) are kept in memory only, so a run
// never changes what the app remembers.

setvbuf(stdout, nil, _IOLBF, 0)
let started = Date()
func say(_ s: String) { print(String(format: "+%6.2fs ", Date().timeIntervalSince(started)) + s) }

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
var adds: [URL] = []
while let f = option("--add") { adds.append(URL(fileURLWithPath: f)) }
let name = option("--name") ?? Host.current().localizedName ?? "Mac"
let store: PairingKeyStore = option("--store").map { FilePairingKeyStore(url: URL(fileURLWithPath: $0)) }
    ?? CachingPairingKeyStore(wrapping: KeychainPairingKeyStore(service: "io.github.longtimeno-c.multicast.hub-pairings"))
let codeLog = option("--pairing-code-log").map { URL(fileURLWithPath: $0) }
let musicChoice = option("--apple-music") ?? "musicApp"
let seconds = option("--seconds").flatMap(Double.init)
let latencyMs = option("--latency-ms").flatMap(Int.init) ?? 2000
guard args.isEmpty else {
    print("unknown arguments: \(args.joined(separator: " ")) (see the header of Sources/multicast-hub/main.swift)")
    exit(2)
}

let hubIDKey = "MulticastHub.cli.hubID"
let hubID: String = {
    if let id = UserDefaults.standard.string(forKey: hubIDKey), !id.isEmpty { return id }
    let id = UUID().uuidString.lowercased()
    UserDefaults.standard.set(id, forKey: hubIDKey)
    return id
}()

var session = LocalHub.defaultSessionConfiguration()
session.engine.latencyNanos = UInt64(min(max(latencyMs, 500), 5000)) * 1_000_000
let hub = LocalHub.live(settings: InMemorySettingsStore(), sessionConfiguration: session)
await hub.start()
say("hub started")

var musicPlayer: AppleMusicHubPlayer?
if musicChoice != "off", #available(macOS 14.2, *), let kind = AppleMusicBackendKind(rawValue: musicChoice) {
    musicPlayer = AppleMusicHubPlayer(provider: AppleMusicProviderFactory.make(kind))
}

var config = HubServer.Configuration(hubID: hubID, name: name)
config.advertises = true
let phones = RemoteSpeakerHost(
    add: { descriptor, sink in await hub.addExternalSpeaker(descriptor, sink: sink) },
    remove: { id in await hub.removeExternalSpeaker(id: id) })
let server = HubServer(backend: hub, configuration: config, keyStore: store, speakerHost: phones)
if let cached = store as? CachingPairingKeyStore { Task { await cached.load() } }
let events = server.events()
let eventTask = Task {
    for await e in events {
        switch e {
        case .pairingRequested(let p):
            say("PAIRING \"\(p.remoteName)\" \(p.code)")
            if let codeLog {
                FileManager.default.createFile(atPath: codeLog.path, contents: Data((p.code + "\n").utf8),
                                               attributes: [.posixPermissions: 0o600])
            }
        case .pairingEnded(_, let remote, let outcome): say("pairing with \"\(remote)\" ended: \(outcome)")
        case .remoteConnected(let r): say("remote connected: \"\(r.remoteName)\"")
        case .remoteDisconnected(let r, let reason): say("remote disconnected: \"\(r.remoteName)\" (\(reason))")
        case .stopped(let reason): say("SERVER STOPPED: \(reason)")
        }
    }
}
do {
    let port = try await server.start()
    say("serving remotes as \"\(name)\" on port \(port), hub id \(hubID)")
} catch {
    say("server failed: \(error.localizedDescription)")
}
if let musicPlayer { await hub.setMusicPlayer(musicPlayer) }
if !adds.isEmpty {
    do {
        try await hub.perform(.addFiles(urls: adds))
        say("added \(adds.count) file(s) to Files")
    } catch {
        say("adding files failed: \(error.localizedDescription)")
    }
}

// Run until the time is up or a signal arrives, then tear everything down.
let stop = AsyncStream<String>.makeStream()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { stop.continuation.yield(sig == SIGINT ? "interrupt" : "terminate") }
    src.resume()
    signalSources.append(src)
}
if let seconds {
    Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        stop.continuation.yield("time up")
    }
}
var why = "stopped"
for await reason in stop.stream { why = reason; break }
say("shutting down (\(why))")
await server.stop()
await hub.shutdown()
musicPlayer?.close()
if let cached = store as? CachingPairingKeyStore { await cached.flush() }
eventTask.cancel()
say("hub shut down")
exit(0)
