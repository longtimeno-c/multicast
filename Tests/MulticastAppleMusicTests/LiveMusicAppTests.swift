#if os(macOS)
import Foundation
import MulticastHubModel
import Testing
@testable import MulticastAppleMusic

/// Live check against the real Music app. Off unless `MULTICAST_LIVE_MUSIC=1`.
///
/// Never prompts: it reads the Automation status for the process running the tests and skips
/// when it is not granted. Plays one library track for about 3 s with Music's volume ≤ 10 and
/// the built-in output ≤ 0.08 (refuses on any other output, or if Music is AirPlaying itself),
/// taps Music muted, then stops and restores everything. Prints no track names.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MULTICAST_LIVE_MUSIC"] == "1"))
struct LiveMusicAppTests {
    @available(macOS 14.2, *)
    @Test func playsAndCapturesThroughMusicApp() async throws {
        let outcome = await MusicAppCaptureProbe.run(permissionTimeout: 20, promptForPermission: false) { print("[live] \($0)") }
        print("[live] OUTCOME\n\(outcome)")
        try #require(outcome.automation == PermissionStatus.granted.rawValue, "Automation for Music not granted to the test host")
        #expect(outcome.error == nil)
        #expect((outcome.librarySongCount ?? 0) > 0)
        #expect(outcome.played)
        #expect(outcome.reportedPlaying)
        let m = try #require(outcome.measurement)
        #expect(m.isNonSilent, "tap delivered no samples: \(m)")
    }
}
#endif
