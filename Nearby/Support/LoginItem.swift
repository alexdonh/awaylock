import ServiceManagement

protocol LoginItemServing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServing {}

enum LoginItem {
    /// Applies the choice, then trusts the status after the call, not the absence of an error.
    @discardableResult
    static func apply(_ enabled: Bool, service: any LoginItemServing = SMAppService.mainApp) -> SMAppService.Status {
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            Log.session.error("login item \(enabled ? "register" : "unregister") threw: \(error.localizedDescription)")
        }
        return service.status
    }
}
