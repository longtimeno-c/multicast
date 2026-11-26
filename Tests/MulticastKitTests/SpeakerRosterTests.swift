import XCTest
import MulticastAudio
@testable import MulticastKit

final class SpeakerRosterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func d(_ id: String, _ name: String, port: UInt16 = 7000) -> SpeakerDescriptor {
        SpeakerDescriptor(id: id, name: name, transport: .airplay1, host: "192.0.2.10", port: port)
    }

    func testBlipKeepsSpeakerListedWithoutMark() {
        var r = SpeakerRoster(policy: .init(missingAfter: 20, dropAfter: 180))
        r.observe([d("a", "Patio"), d("b", "Hall Sonos")], at: t0)
        r.observe([d("b", "Hall Sonos")], at: t0.addingTimeInterval(1))
        let l = r.listing(at: t0.addingTimeInterval(5))
        XCTAssertEqual(l.speakers.map(\.id).sorted(), ["a", "b"])
        XCTAssertTrue(l.notSeenSince.isEmpty)
        r.observe([d("a", "Patio"), d("b", "Hall Sonos")], at: t0.addingTimeInterval(6))
        XCTAssertTrue(r.listing(at: t0.addingTimeInterval(60)).notSeenSince.isEmpty)
    }

    func testMarkedAfterMissingWindowThenDropped() {
        var r = SpeakerRoster(policy: .init(missingAfter: 20, dropAfter: 180))
        r.observe([d("a", "Patio")], at: t0)
        let gone = t0.addingTimeInterval(100)  // present a long time, then gone
        r.observe([], at: gone)
        XCTAssertTrue(r.listing(at: gone.addingTimeInterval(19)).notSeenSince.isEmpty)
        XCTAssertEqual(r.listing(at: gone.addingTimeInterval(20)).notSeenSince, ["a": gone])
        XCTAssertFalse(r.prune(at: gone.addingTimeInterval(179)))
        XCTAssertTrue(r.prune(at: gone.addingTimeInterval(180)))
        XCTAssertTrue(r.listing(at: gone.addingTimeInterval(180)).speakers.isEmpty)
    }

    func testReturnUsesFreshDescriptorAndClearsMark() {
        var r = SpeakerRoster(policy: .init(missingAfter: 20, dropAfter: 180))
        r.observe([d("a", "Main Bedroom", port: 5000)], at: t0)
        r.observe([], at: t0.addingTimeInterval(1))
        r.observe([d("a", "Main Bedroom", port: 5001)], at: t0.addingTimeInterval(40))
        let l = r.listing(at: t0.addingTimeInterval(41))
        XCTAssertEqual(l.speakers.first?.port, 5001)
        XCTAssertTrue(l.notSeenSince.isEmpty)
    }

    func testSortedByNameAndResetClears() {
        var r = SpeakerRoster()
        r.observe([d("b", "Patio"), d("a", "Hall Sonos")], at: t0)
        XCTAssertEqual(r.listing(at: t0).speakers.map(\.name), ["Hall Sonos", "Patio"])
        r.reset()
        XCTAssertTrue(r.listing(at: t0).speakers.isEmpty)
    }
}
