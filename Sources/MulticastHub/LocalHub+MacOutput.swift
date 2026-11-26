import Foundation
import MulticastAudio
import MulticastHubModel

// The "Mac output" source: whatever the Mac plays to the "Multicast" output device
// (Drivers/MulticastDevice). Choosing it starts reading the device; any app, or System
// Settings › Sound, sends its sound there by choosing "Multicast" as its output.

extension LocalHub {
    /// What the capture ring holds before the engine reads it (LiveFillController's target).
    static let macOutputCaptureDelay: TimeInterval = 0.1

    func selectMacOutput() throws {
        let sources = deps.sources
        guard sources.macOutputIsInstalled else {
            throw HubCommandError(.unavailable,
                                  "The Multicast output device isn\u{2019}t installed on this Mac. See Drivers/MulticastDevice.")
        }
        let source: AudioSource
        do { source = try sources.makeMacOutputCapture() } catch {
            throw HubCommandError(.failed, "The Mac output couldn\u{2019}t start: \(error.localizedDescription)")
        }
        // Apps that sync video to audio delay their picture by what the device reports.
        sources.reportMacOutputLatency(seconds: deps.session.latencySeconds + Self.macOutputCaptureDelay)
        leaveActiveSource()
        activeSource = .macOutput
        setPosition(0)
        wantsPlay = hasPlayableSpeaker
        publish()
        setEngineSource(source, kind: .macOutput)
        if !hasPlayableSpeaker { throw HubCommandError(.unavailable, Self.needsSpeaker) }
    }

    func macOutputNowPlaying() -> NowPlayingInfo {
        let routed = deps.sources.macOutputIsDefault
        return NowPlayingInfo(title: "Mac output",
                              artist: routed ? "Playing what the Mac plays" : "Choose \u{201C}Multicast\u{201D} as the Mac\u{2019}s output",
                              artworkID: nil)
    }
}
