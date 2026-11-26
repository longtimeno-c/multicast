#if os(macOS)
import AppKit
import Foundation
import MulticastHubModel
import MulticastSources

/// End-to-end check of the Music app path: library read, play one library track in Music at a
/// capped volume, find which process renders it, and read it through
/// `MusicAppPlayer.makeAudioSource()` (muted locally while tapped).
///
/// Safety: refuses unless the system default output is the built-in device and Music is not
/// sending to AirPlay speakers itself; caps Music's volume and the output volume before any
/// audio; stops Music, restores both volumes and quits Music if it launched it. Logs no track
/// or device names.
@available(macOS 14.2, *)
public enum MusicAppCaptureProbe {
    public struct Outcome: Sendable, CustomStringConvertible {
        public var automation = "unknown"
        public var librarySongCount: Int?
        public var libraryLoadSeconds: Double?
        public var playlistCount: Int?
        public var artworkBytes: Int?
        public var played = false
        public var reportedPlaying = false
        public var renderingProcesses: [String] = []
        public var measurement: TapMeasurement?
        public var error: String?

        public var description: String {
            var l = ["automation=\(automation)",
                     "librarySongCount=\(librarySongCount.map(String.init) ?? "-")",
                     "libraryLoadSeconds=\(libraryLoadSeconds.map { String(format: "%.2f", $0) } ?? "-")",
                     "playlistCount=\(playlistCount.map(String.init) ?? "-")",
                     "artworkBytes=\(artworkBytes.map(String.init) ?? "-")",
                     "played=\(played) reportedPlaying=\(reportedPlaying)"]
            l += renderingProcesses.map { "renderingProcess: \($0)" }
            if let measurement { l.append("measurement: \(measurement)") }
            if let error { l.append("error: \(error)") }
            return l.joined(separator: "\n")
        }
    }

    public static func run(musicVolumeCap: Int = 10, outputVolumeCap: Float32 = 0.08, tapSeconds: Double = 3,
                           permissionTimeout: TimeInterval = 60, promptForPermission: Bool = true, log: @escaping @Sendable (String) -> Void) async -> Outcome {
        let wasRunning = MusicAppPlayer.isRunning
        log("Music installed=\(MusicAppPlayer.isInstalled) running=\(wasRunning)")
        let out = await body(musicVolumeCap: musicVolumeCap, outputVolumeCap: outputVolumeCap, tapSeconds: tapSeconds,
                             permissionTimeout: permissionTimeout, promptForPermission: promptForPermission, log: log)
        if !wasRunning {
            // Leave things as found: quit Music if this probe opened it.
            for _ in 0..<40 where MusicAppPlayer.isRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: MusicAppPlayer.bundleID).forEach { $0.terminate() }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            log("Music quit=\(!MusicAppPlayer.isRunning)")
        }
        return out
    }

    private static func body(musicVolumeCap: Int, outputVolumeCap: Float32, tapSeconds: Double, permissionTimeout: TimeInterval,
                             promptForPermission: Bool, log: @escaping @Sendable (String) -> Void) async -> Outcome {
        var out = Outcome()
        let player = MusicAppPlayer(launchPolicy: .launchInBackground)

        // Permission (prompts once if undecided and allowed to; waits up to permissionTimeout).
        let access = await MusicKitRenderProbe.withTimeout(permissionTimeout) {
            promptForPermission ? await player.requestAccess() : await player.currentAccess()
        } ?? .notDetermined
        out.automation = access.rawValue
        log("automation permission for Music = \(access.rawValue)")
        guard access == .granted else {
            out.error = "Automation for Music not granted (\(access.rawValue)); stopping"
            log(out.error!)
            return out
        }

        var restoreMusicVolume: Int?
        var restoreOutput: (device: DefaultOutputDevice, volume: Float32)?

        // Library.
        do {
            let t0 = Date()
            let first = try await player.songs(PageRequest(limit: 5))
            out.libraryLoadSeconds = Date().timeIntervalSince(t0)
            out.librarySongCount = first.totalCount
            log("library: \(first.totalCount ?? -1) songs, first page \(first.items.count), loaded in \(String(format: "%.2f", out.libraryLoadSeconds!)) s")
            let pls = try await player.playlists(PageRequest(limit: 500))
            out.playlistCount = pls.totalCount
            log("playlists: \(pls.totalCount ?? -1)")
            if let art = first.items.compactMap(\.artworkID).first {
                out.artworkBytes = await player.artwork(id: art, maxPixel: 300)?.count
                log("artwork bytes (maxPixel 300) = \(out.artworkBytes.map(String.init) ?? "none")")
            }
            guard let track = first.items.first else {
                out.error = "library is empty; nothing to play"
                log(out.error!)
                return out
            }

            // Safety.
            guard let device = DefaultOutputDevice.current(), device.isBuiltIn else {
                out.error = "default output is not the built-in device; refusing to play"
                log(out.error!)
                return out
            }
            let elsewhere = try await player.airPlayDevicesElsewhere()
            guard elsewhere == 0 else {
                out.error = "Music is sending to \(elsewhere) AirPlay device(s) itself; refusing to play"
                log(out.error!)
                return out
            }
            let savedMusicVolume = try await player.musicVolume()
            restoreMusicVolume = savedMusicVolume
            try await player.setMusicVolume(min(savedMusicVolume, musicVolumeCap))
            let savedOutput = device.volume
            if let savedOutput, savedOutput > outputVolumeCap {
                restoreOutput = (device, savedOutput)
                guard device.setVolume(outputVolumeCap) else {
                    throw HubCommandError(.failed, "could not cap the output volume; refusing to play")
                }
            }
            log("Music volume \(savedMusicVolume) -> \(try await player.musicVolume()); output volume \(savedOutput.map { String($0) } ?? "n/a") -> \(device.volume.map { String($0) } ?? "n/a")")

            // Play, look, tap.
            let before = Set(AudioProcessDirectory.snapshot().filter(\.isRunningOutput).map(\.objectID))
            try await player.play(trackID: track.id, context: .songs)
            out.played = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let state = try await player.playerState()
            out.reportedPlaying = state.state == .playing && state.track?.persistentID == track.id
            log("Music reports state=\(state.state) sameTrack=\(state.track?.persistentID == track.id) position=\(state.position.map { String(format: "%.2f", $0) } ?? "-")")
            for p in AudioProcessDirectory.snapshot().filter(\.isRunningOutput) {
                let line = TapProbe.describe(p) + (before.contains(p.objectID) ? "" : " [NEW]")
                log("running output: \(line)")
                if p.belongs(toApp: MusicAppPlayer.bundleID) || !before.contains(p.objectID) { out.renderingProcesses.append(line) }
            }
            if let tap = player.makeAudioSource() as? AppAudioTapSource {
                let m = await TapProbe.measure(tap, seconds: tapSeconds)
                out.measurement = m
                log("Music tap: \(m)")
            }

            // Transport round trip, then tear down.
            try await player.pause()
            try? await Task.sleep(nanoseconds: 400_000_000)
            log("after pause: state=\(try await player.playerState().state)")
            try await player.stop()
            log("stopped")
        } catch {
            out.error = "\(error)"
            log("error: \(error)")
            try? await player.stop()
        }
        if let v = restoreMusicVolume { try? await player.setMusicVolume(v) }
        if let r = restoreOutput { r.device.setVolume(r.volume) }
        log("volumes restored")
        return out
    }
}
#endif
