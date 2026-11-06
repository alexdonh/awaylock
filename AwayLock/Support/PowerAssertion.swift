import IOKit.pwr_mgt

protocol PowerAsserting {
    func hold(_ on: Bool)
}

/// Keeps the display (and so the idle lock) from kicking in while the device is near.
// ponytail: PreventUserIdleDisplaySleep only; add IOPMAssertionDeclareUserActivity every 60 s
// if `spike awake` shows the screensaver still locks.
final class PowerAssertion: PowerAsserting {
    private var id = IOPMAssertionID(0)
    private var held = false

    func hold(_ on: Bool) {
        guard on != held else { return }
        if on {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AwayLock: your device is near" as CFString, &id)
            held = result == kIOReturnSuccess
            if !held { Log.session.error("power assertion failed: \(result)") }
        } else {
            IOPMAssertionRelease(id)
            held = false
        }
    }
}
