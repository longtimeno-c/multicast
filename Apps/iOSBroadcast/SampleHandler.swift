import CoreMedia
import Foundation
import MulticastKit
import ReplayKit

/// The broadcast extension behind "iPhone only" mode. iOS lets an app hear what other apps
/// play only through a screen broadcast: while one runs, the system hands this class the
/// playing app's audio, and it plays that to the AirPlay speakers chosen in the app.
///
/// Everything but ReplayKit lives in the package (`PushedAudioSource`, `PhoneBroadcastRunner`),
/// where it is tested on the Mac. What is here cannot run in the simulator.
///
/// The extension has about 50 MB and no UI, and the system may kill it at any moment: nothing
/// is allocated per buffer, the screen's video frames are dropped untouched, and the app works
/// out that a broadcast died from the status going stale.
final class SampleHandler: RPBroadcastSampleHandler {
    private let source = PushedAudioSource(displayName: "iPhone")
    private var runner: PhoneBroadcastRunner?
    private let finishing = NSLock()
    private var hasFinished = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let store = PhoneBroadcastStore.shared() else {
            end(with: .couldNotStart("this copy of Multicast can\u{2019}t share settings with its broadcast extension."))
            return
        }
        let runner = PhoneBroadcastRunner(store: store, source: source) { [weak self] failure in
            // Called from inside the runner: end the broadcast from elsewhere, since ending
            // waits for the runner to stop.
            DispatchQueue.global(qos: .userInitiated).async { self?.end(with: failure) }
        }
        self.runner = runner
        Task { [weak self] in
            do {
                try await runner.start()
            } catch let failure as PhoneBroadcastError {
                self?.end(with: failure)
            } catch {
                self?.end(with: .couldNotStart(error.localizedDescription))
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Only what the apps play. The screen (.video) and the microphone (.audioMic) are not used.
        guard sampleBufferType == .audioApp else { return }
        source.push(sampleBuffer: sampleBuffer)
    }

    override func broadcastPaused() {
        // Whatever was buffered is stale by the time the broadcast resumes.
        source.flush()
    }

    override func broadcastFinished() {
        // The process may be gone as soon as this returns: disconnect the speakers first.
        tearDown(reason: nil)
    }

    /// Ends the broadcast from this side. The system shows the user `failure`'s wording.
    private func end(with failure: PhoneBroadcastError) {
        finishing.lock()
        let already = hasFinished
        hasFinished = true
        finishing.unlock()
        guard !already else { return }
        let message = failure.errorDescription ?? "Multicast stopped playing."
        tearDown(reason: message)
        finishBroadcastWithError(NSError(domain: "io.github.longtimeno-c.multicast.broadcast", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
            NSLocalizedFailureReasonErrorKey: message,
        ]))
    }

    private func tearDown(reason: String?) {
        guard let runner else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await runner.stop(reason: reason)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }
}
extension SampleHandler: @unchecked Sendable {}
