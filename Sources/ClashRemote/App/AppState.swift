import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var devices: [RouterDevice] = []
    var selectedID: UUID?
    var snapshot = DashboardSnapshot()
    var isConnecting = false
    var isBusy = false
    var notice: AppNotice?
    var lastError: String?
    var connectedDeviceID: UUID?
    var delayByNode: [String: Int] = [:]
    var testingNodes: Set<String> = []
    var pingingAll = false

    @ObservationIgnored private let store = DeviceStore()
    @ObservationIgnored private var service: (any ClashBackend)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var selectedDevice: RouterDevice? {
        devices.first { $0.id == selectedID }
    }

    var isConnected: Bool {
        connectedDeviceID != nil && connectedDeviceID == selectedID && lastError == nil
    }

    init() {
        let loaded = store.load()
        devices = loaded.devices
        selectedID = loaded.selected ?? loaded.devices.first?.id
    }

    func persist() {
        store.save(devices: devices, selected: selectedID)
    }

    func select(_ id: UUID) {
        selectedID = id
        persist()
        Task { await connect() }
    }

    func addDevice(_ device: RouterDevice) {
        devices.append(device)
        selectedID = device.id
        persist()
        Task { await connect() }
    }

    func updateDevice(_ device: RouterDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx] = device
            persist()
            if connectedDeviceID == device.id {
                Task { await connect() }
            }
        }
    }

    func deleteDevice(_ id: UUID) {
        devices.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = devices.first?.id
        }
        persist()
        if connectedDeviceID == id {
            disconnect()
            if selectedID != nil {
                Task { await connect() }
            }
        }
    }

    func connect() async {
        guard let device = selectedDevice else { return }
        pollTask?.cancel()
        isConnecting = true
        lastError = nil
        notice = .info("正在连接 \(device.displayAddress)…")
        do {
            let next: any ClashBackend = device.plugin == .maomao
                ? MaoMaoService(device: device)
                : OpenClashService(device: device)
            let snap = try await next.connect()
            service = next
            snapshot = snap
            connectedDeviceID = device.id
            isConnecting = false
            notice = .success("已连接 \(snap.status.model.isEmpty ? device.name : snap.status.model)")
            startPolling()
        } catch {
            isConnecting = false
            connectedDeviceID = nil
            service = nil
            let text = Self.describe(error)
            lastError = text
            notice = .error(text)
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        service = nil
        connectedDeviceID = nil
    }

    func refresh(full: Bool = false) async {
        guard let service else { return }
        do {
            let snap = try await service.refresh(full: full)
            snapshot.status = snap.status
            snapshot.traffic = snap.traffic
            snapshot.configs = snap.configs
            snapshot.subscriptions = snap.subscriptions
            if full {
                snapshot.groups = snap.groups
                snapshot.rules = snap.rules
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func run(_ message: String, restartWait: Bool = false, _ work: @escaping @MainActor (any ClashBackend) async throws -> Void) {
        guard let service else {
            notice = .error("还没连上路由器")
            return
        }
        isBusy = true
        notice = .info(message)
        Task { @MainActor in
            do {
                try await work(service)
                if restartWait {
                    try await Task.sleep(for: .seconds(2.4))
                }
                await refresh(full: true)
                isBusy = false
                notice = .success("完成")
            } catch {
                isBusy = false
                notice = .error(error.localizedDescription)
            }
        }
    }

    func setRunning(_ running: Bool) {
        run(running ? "正在启动…" : "正在停止…", restartWait: true) {
            try await $0.setRunning(running)
        }
    }

    func restart() {
        run("正在重启核心…", restartWait: true) {
            try await $0.restart()
        }
    }

    func setRuleMode(_ mode: RuleMode) {
        snapshot.status.ruleMode = mode
        run("切换到\(mode.title)模式…") {
            try await $0.setRuleMode(mode)
            try await $0.closeConnections()
        }
    }

    func setCapture(_ capture: RunCapture) {
        run("切换流量接管…", restartWait: true) {
            try await $0.setCapture(capture)
        }
    }

    func toggleSetting(_ name: String, value: Bool) {
        run("正在保存…") {
            try await $0.setOCSetting(name, value: value)
        }
    }

    func setChinaIPRoute(_ enabled: Bool) {
        snapshot.status.chinaIPRoute = enabled
        run(enabled ? "开启绕过大陆…" : "关闭绕过大陆…", restartWait: true) {
            try await $0.setChinaIPRoute(enabled)
        }
    }

    func switchConfig(_ file: ConfigFile) {
        run("切换配置 \(file.name)…", restartWait: true) {
            try await $0.switchConfig(file)
        }
    }

    func updateSubscription(named name: String) {
        run("更新订阅 \(name)…", restartWait: true) {
            try await $0.updateConfig(filename: name)
        }
    }

    func saveSubscription(_ sub: Subscription, isNew: Bool) {
        run(isNew ? "添加订阅…" : "保存订阅…") {
            try await $0.saveSubscription(sub, isNew: isNew)
        }
    }

    func deleteSubscription(_ sub: Subscription) {
        run("删除订阅…") {
            try await $0.deleteSubscription(sub)
        }
    }

    func selectNode(group: String, name: String) {
        applySelect(group: group, name: name)
        Task { await pushSelect(group: group, name: name) }
    }

    func selectLeafNode(_ node: ProxyItem, viewingGlobal: Bool) {
        let owner = node.ownerGroup.isEmpty ? "GLOBAL" : node.ownerGroup
        applySelect(group: owner, name: node.name)
        if viewingGlobal, owner != "GLOBAL",
           snapshot.groups.contains(where: { $0.name == "GLOBAL" && $0.nodes.contains(where: { $0.name == owner }) }) {
            applySelect(group: "GLOBAL", name: owner)
        }
        Task {
            await pushSelect(group: owner, name: node.name)
            if viewingGlobal, owner != "GLOBAL" {
                await pushSelect(group: "GLOBAL", name: owner)
            }
        }
    }

    private func applySelect(group: String, name: String) {
        guard let idx = snapshot.groups.firstIndex(where: { $0.name == group }) else { return }
        snapshot.groups[idx].now = name
    }

    private func pushSelect(group: String, name: String) async {
        do {
            guard let service else { return }
            try await service.selectProxy(group: group, name: name)
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    func delay(for name: String) -> Int? {
        if let value = delayByNode[name] { return value }
        for group in snapshot.groups {
            if let node = group.nodes.first(where: { $0.name == name }) {
                return node.lastDelay
            }
        }
        return nil
    }

    func ping(_ name: String) {
        Task { await pingAwait(name) }
    }

    func pingGroup(_ names: [String]) {
        guard !names.isEmpty else { return }
        pingingAll = true
        notice = .info("正在测延迟…")
        Task {
            let chunkSize = 8
            var start = names.startIndex
            while start < names.endIndex {
                let end = names.index(start, offsetBy: chunkSize, limitedBy: names.endIndex) ?? names.endIndex
                let chunk = Array(names[start..<end])
                await withTaskGroup(of: Void.self) { group in
                    for name in chunk {
                        group.addTask {
                            await self.pingAwait(name)
                        }
                    }
                }
                start = end
            }
            pingingAll = false
            notice = .success("延迟测试完成")
        }
    }

    private func pingAwait(_ name: String) async {
        testingNodes.insert(name)
        defer { testingNodes.remove(name) }
        do {
            guard let service else { return }
            let delay = try await service.testDelay(name: name)
            delayByNode[name] = delay == 0 ? -1 : delay
        } catch {
            delayByNode[name] = -1
        }
    }

    func addRule(domain: String, proxy: String) {
        let path = snapshot.status.configPath
        run("写入规则并重启…", restartWait: true) {
            try await $0.addDirectRule(domain: domain, proxy: proxy, configPath: path)
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
            return "请求超时。如果本机开了系统代理，请把路由器 IP 加到直连，或关掉代理后再连。"
        }
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotConnectToHost {
            return "连不上 \(ns.userInfo[NSURLErrorFailingURLStringErrorKey] ?? "路由器")。"
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == 61 || ns.code == 65) {
            return "连不上路由器。请在系统弹窗里允许“本地网络”，并确认地址是 192.168.x.x。"
        }
        return error.localizedDescription
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await self?.refresh(full: false)
            }
        }
    }
}
