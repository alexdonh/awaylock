import Observation
import os
import Testing
@testable import AwayLock

@Observable private final class Box {
    var a = 0
    var b = 0
}

@MainActor struct ObservingTests {
    @Test func yieldsNowThenOncePerTurnOfChanges() async {
        let box = Box()
        var it = observing { box.a + box.b }.makeAsyncIterator()
        #expect(await it.next() == 0)

        box.a = 1
        box.b = 2          // same turn: one value, not two
        #expect(await it.next() == 3)

        box.b = 5          // still tracking after the first change
        #expect(await it.next() == 6)
    }

    @Test func stopsTrackingWhenConsumerIsGone() async {
        let box = Box()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var stream: AsyncStream<Int>? = observing { reads.withLock { $0 += 1 }; return box.a }
        var it = stream!.makeAsyncIterator()
        _ = await it.next()
        stream = nil
        it = observing { 0 }.makeAsyncIterator()   // drop the last reference to the first stream
        _ = it
        box.a = 1
        await Task.yield(); await Task.yield()
        box.a = 2
        await Task.yield(); await Task.yield()
        #expect(reads.withLock { $0 } == 1)
    }
}
