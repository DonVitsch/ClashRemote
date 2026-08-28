import Foundation

@MainActor
protocol ClashBackend: AnyObject {
    func connect() async throws -> DashboardSnapshot
    func refresh(full: Bool) async throws -> DashboardSnapshot
    func setRunning(_ running: Bool) async throws
    func restart() async throws
    func setRuleMode(_ mode: RuleMode) async throws
    func setCapture(_ capture: RunCapture) async throws
    func setOCSetting(_ name: String, value: Bool) async throws
    func setChinaIPRoute(_ enabled: Bool) async throws
    func switchConfig(_ file: ConfigFile) async throws
    func updateConfig(filename: String) async throws
    func saveSubscription(_ sub: Subscription, isNew: Bool) async throws
    func deleteSubscription(_ sub: Subscription) async throws
    func selectProxy(group: String, name: String) async throws
    func testDelay(name: String) async throws -> Int
    func addDirectRule(domain: String, proxy: String, configPath: String) async throws
    func closeConnections() async throws
}

extension OpenClashService: ClashBackend {}
