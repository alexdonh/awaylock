import Testing
@testable import AwayLock

struct RSSIFilterTests {
    @Test func firstReadingPassesThrough() {
        var f = RSSIFilter()
        #expect(f.add(-60) == -60)
    }

    @Test func singleSpikeIsIgnored() {
        var f = RSSIFilter()
        for _ in 0..<5 { f.add(-50) }
        #expect(f.add(-95) == -50)
        #expect(f.add(-50) == -50)
    }

    @Test func followsRealWalkWithinAFewReadings() {
        var f = RSSIFilter()
        for _ in 0..<5 { f.add(-50) }
        var steps = 0
        while f.add(-85) > -75 { steps += 1 }
        #expect(steps <= 6)
    }

    @Test func resetForgetsHistory() {
        var f = RSSIFilter()
        f.add(-50)
        f.reset()
        #expect(f.value == nil)
        #expect(f.add(-80) == -80)
    }
}
