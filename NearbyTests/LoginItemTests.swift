import ServiceManagement
import Testing
@testable import Nearby

@MainActor
final class FakeLoginItem: LoginItemServing {
    var status: SMAppService.Status
    var statusAfterCall: SMAppService.Status
    var error: (any Error)?
    init(before: SMAppService.Status, after: SMAppService.Status, error: (any Error)? = nil) {
        status = before; statusAfterCall = after; self.error = error
    }
    func register() throws { status = statusAfterCall; if let error { throw error } }
    func unregister() throws { status = statusAfterCall; if let error { throw error } }
}

struct BoomError: Error {}

@MainActor
struct LoginItemTests {
    @Test func reportsStatusAfterTheCall() {
        let fake = FakeLoginItem(before: .notRegistered, after: .requiresApproval)
        #expect(LoginItem.apply(true, service: fake) == .requiresApproval)
    }

    @Test func errorButEnabledStillReportsEnabled() {
        let fake = FakeLoginItem(before: .enabled, after: .enabled, error: BoomError())
        #expect(LoginItem.apply(true, service: fake) == .enabled)
    }

    @Test func noErrorButNotRegisteredReportsNotRegistered() {
        let fake = FakeLoginItem(before: .notRegistered, after: .notRegistered)
        #expect(LoginItem.apply(true, service: fake) == .notRegistered)
    }
}
