import XCTest
@testable import MulticastKit

final class ReconnectScheduleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testBacksOffThenRepeatsLastDelay() {
        var r = ReconnectSchedule(delays: [2, 5, 10])
        let f: [String: String?] = ["a": "Not responding"]
        XCTAssertEqual(r.due(failing: f, at: at(0)), [])
        XCTAssertEqual(r.due(failing: f, at: at(1.9)), [])
        XCTAssertEqual(r.due(failing: f, at: at(2)), ["a"])
        XCTAssertEqual(r.due(failing: f, at: at(6.9)), [])
        XCTAssertEqual(r.due(failing: f, at: at(7)), ["a"])
        XCTAssertEqual(r.due(failing: f, at: at(17)), ["a"])
        XCTAssertEqual(r.due(failing: f, at: at(26)), [])
        XCTAssertEqual(r.due(failing: f, at: at(27)), ["a"])
        XCTAssertEqual(r.attempts(for: "a"), 4)
    }

    func testRecoveryForgetsAndStartsOver() {
        var r = ReconnectSchedule(delays: [2, 5])
        _ = r.due(failing: ["a": nil], at: at(0))
        XCTAssertEqual(r.due(failing: ["a": nil], at: at(2)), ["a"])
        XCTAssertEqual(r.due(failing: [:], at: at(3)), [])
        XCTAssertEqual(r.attempts(for: "a"), 0)
        XCTAssertEqual(r.due(failing: ["a": nil], at: at(4)), [])
        XCTAssertEqual(r.due(failing: ["a": nil], at: at(6)), ["a"])
    }

    func testPermanentFailuresAreNotRetried() {
        var r = ReconnectSchedule(delays: [1])
        let f: [String: String?] = ["p": "Speaker requires a password", "d": "same physical device as Hall Sonos",
                                    "a": "the receiver refused access (403 Forbidden to OPTIONS)"]
        _ = r.due(failing: f, at: at(0))
        XCTAssertEqual(r.due(failing: f, at: at(100)), [])
    }

    func testRetrySoonBringsTryForward() {
        var r = ReconnectSchedule(delays: [30])
        _ = r.due(failing: ["a": "timed out"], at: at(0))
        r.retrySoon("a", at: at(1))
        XCTAssertEqual(r.due(failing: ["a": "timed out"], at: at(1)), ["a"])
        r.retrySoon("b", at: at(2))
        XCTAssertEqual(r.due(failing: ["a": "timed out", "b": "timed out"], at: at(2)), ["b"])
    }
}
