import Foundation
import Testing
import MulticastAudio
@testable import MulticastLocalOutput

@Suite struct BroadcasterTests {
    @Test func newSubscribersGetTheCurrentValueFirst() async {
        let b = ReplayingBroadcaster<SinkState>(.idle)
        b.send(.connecting)
        b.send(.playing)
        var it = b.makeStream().makeAsyncIterator()
        #expect(await it.next() == .playing)
        b.send(.failed("gone"))
        #expect(await it.next() == .failed("gone"))
        b.finishAll()
        #expect(await it.next() == nil)
    }

    @Test func sendIfChangedSuppressesDuplicates() async {
        let b = ReplayingBroadcaster<Int>(1)
        var it = b.makeStream().makeAsyncIterator()
        #expect(await it.next() == 1)
        b.sendIfChanged(1)
        b.sendIfChanged(2)
        #expect(await it.next() == 2)
    }

    @Test func errorDescriptionsAreReadable() {
        #expect(LocalOutputError.coreAudio(operation: "AudioUnitInitialize", status: 0x2177_6174).description.contains("'!wat'"))
        #expect(LocalOutputError.deviceNotFound(uid: "X").description == "Output device X is not connected")
    }
}
