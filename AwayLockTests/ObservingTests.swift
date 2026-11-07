import Observation
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
}
