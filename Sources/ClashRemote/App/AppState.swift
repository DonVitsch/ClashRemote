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
    var deviceFailover = DeviceFailoverStatus()
    var failoverHistory: [FailoverEvent] = []
    var deviceFailoverHistory: [FailoverEvent] = []
    var trafficHistory: [TrafficSample] = []
    @ObservationIgnored private var previousTrafficCounter: TrafficCounterReading?
    @ObservationIgnored private var connectionGeneration = UUID()
    static let deviceFailoverIntervals = [5, 15, 30]
    private static let historyKey = "failoverHistory"
    private static let historyLimit = 80

    var displayedFailoverHistory: [FailoverEvent] {
        (failoverHistory + deviceFailoverHistory)
            .sorted { $0.at > $1.at }
    }
    var autoFailoverEnabled: Bool = (UserDefaults.standard.object(forKey: "autoFailoverEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoFailoverEnabled, forKey: "autoFailoverEnabled")
            restartFailoverWatch()
        }
    }
    var autoFailoverInterval: Int = {
        let stored = UserDefaults.standard.object(forKey: "autoFailoverInterval") as? Int ?? 30
        return AppState.failoverIntervals.contains(stored) ? stored : 30
    }() {
        didSet {
            UserDefaults.standard.set(autoFailoverInterval, forKey: "autoFailoverInterval")
            restartFailoverWatch()
        }
    }

    static let failoverIntervals = [5, 15, 30, 60, 120]

    /// 单节点测速超时。够长到不会误杀正常节点，卡住时也不用干等。
    private static let nodeProbeTimeoutMs = 3_000
    /// 整组测速超时：内核在服务端并发跑完整组，整个请求的耗时上限就是这个值。
    private static let groupProbeTimeoutMs = 3_000
    /// 当前节点只是「慢」而不是超时时，新节点至少要比它快这么多才切 ——
    /// 否则两个都健康的节点会因为几十毫秒的抖动来回跳。
    private static let switchHysteresisMs = 40
    /// 「整组测速」覆盖不到时逐个补测的上限（只有老内核没有整组测速接口才会走到）。
    private static let fallbackProbeLimit = 24

    @ObservationIgnored private let store = DeviceStore()
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let profileStore = ProfileStore()
    var profile = LocalProfile.default
    @ObservationIgnored private var service: (any ClashBackend)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var failoverTask: Task<Void, Never>?
    @ObservationIgnored private var pingAllTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var failoverBusy = false
    @ObservationIgnored private var failoverNoCandidateNotified = false

    var selectedDevice: RouterDevice? {
        devices.first { $0.id == selectedID }
    }

    var isConnected: Bool {
        connectedDeviceID != nil && connectedDeviceID == selectedID && lastError == nil
    }

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        let loaded = store.load()
        devices = loaded.devices
        selectedID = loaded.selected ?? loaded.devices.first?.id
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let items = try? JSONDecoder().decode([FailoverEvent].self, from: data) {
            failoverHistory = items
        }
        profile = profileStore.load()
    }

    func persist() {
        store.save(devices: devices, selected: selectedID)
    }

    func persistProfile() {
        do {
            try profileStore.save(profile)
        } catch {
            notice = .error("本地配置保存失败：\(error.localizedDescription)")
        }
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

    func connect(preservingOperation: Bool = false) async {
        guard let device = selectedDevice else { return }
        disconnect(cancelOperation: !preservingOperation)
        let generation = connectionGeneration
        isConnecting = true
        lastError = nil
        notice = .info("正在连接 \(device.displayAddress)…")
        do {
            let next: any ClashBackend = device.plugin == .maomao
                ? MaoMaoService(device: device)
                : OpenClashService(device: device)
            let snap = try await next.connect()
            guard connectionGeneration == generation, selectedID == device.id else { return }
            service = next
            snapshot = snap
            recordTraffic()
            connectedDeviceID = device.id
            isConnecting = false
            notice = .success("已连接 \(snap.status.model.isEmpty ? device.name : snap.status.model)")
            startPolling()
            await refreshDeviceFailover()
        } catch {
            guard connectionGeneration == generation, selectedID == device.id else { return }
            isConnecting = false
            connectedDeviceID = nil
            service = nil
            let text = Self.describe(error)
            lastError = text
            notice = .error(text)
        }
    }

    func disconnect(cancelOperation: Bool = true) {
        connectionGeneration = UUID()
        pollTask?.cancel()
        pollTask = nil
        failoverTask?.cancel()
        failoverTask = nil
        pingAllTask?.cancel()
        pingAllTask = nil
        if cancelOperation {
            runTask?.cancel()
            runTask = nil
        }
        failoverBusy = false
        pingingAll = false
        testingNodes.removeAll()
        isBusy = false
        isConnecting = false
        service = nil
        connectedDeviceID = nil
        deviceFailover = DeviceFailoverStatus()
        trafficHistory.removeAll()
        previousTrafficCounter = nil
    }

    func refresh(full: Bool = false) async {
        guard let service, connectedDeviceID == selectedID else { return }
        let generation = connectionGeneration
        let deviceID = selectedID
        do {
            let snap = try await service.refresh(full: full)
            guard connectionGeneration == generation, selectedID == deviceID else { return }
            snapshot.status = snap.status
            let olderTraffic = snap.traffic.counterReadAt.map { readAt in
                previousTrafficCounter.map { readAt <= $0.date } ?? false
            } ?? false
            if !olderTraffic {
                snapshot.traffic = snap.traffic
                recordTraffic()
            }
            snapshot.configs = snap.configs
            if full || !snap.subscriptions.isEmpty {
                // 猫猫只在 full 刷新时才去读 config.yaml 拿订阅列表，别把空结果盖上去。
                snapshot.subscriptions = snap.subscriptions
            }
            // 代理组每次都拉：当前节点 / now 需要实时，规则仍只在 full 时更新。
            // 但测速/换节点期间不覆盖：那时的 now 是本地刚推上去的，别被这一轮读回来的旧值冲掉。
            if !snap.groups.isEmpty, !pingingAll, !failoverBusy {
                snapshot.groups = snap.groups
            }
            if full {
                snapshot.rules = snap.rules
            }
            lastError = nil
        } catch {
            guard connectionGeneration == generation, selectedID == deviceID else { return }
            lastError = error.localizedDescription
        }
    }

    private func recordTraffic() {
        guard snapshot.status.running else {
            previousTrafficCounter = nil
            trafficHistory.removeAll()
            return
        }
        let date = snapshot.traffic.counterReadAt ?? Date()
        var download = TrafficRate.parse(snapshot.traffic.down)
        var upload = TrafficRate.parse(snapshot.traffic.up)
        if let downBytes = snapshot.traffic.downloadBytes, let upBytes = snapshot.traffic.uploadBytes {
            let current = TrafficCounterReading(date: date, download: downBytes, upload: upBytes)
            if let previous = previousTrafficCounter {
                guard date > previous.date else { return }
                let elapsed = date.timeIntervalSince(previous.date)
                if downBytes < previous.download || upBytes < previous.upload {
                    // Restarted cores reset their counters. Begin a fresh timeline.
                    trafficHistory.removeAll()
                } else if elapsed >= 0.5, elapsed <= 30 {
                    download = Double(downBytes - previous.download) / elapsed
                    upload = Double(upBytes - previous.upload) / elapsed
                    snapshot.traffic.down = TrafficRate.format(download ?? 0)
                    snapshot.traffic.up = TrafficRate.format(upload ?? 0)
                }
            }
            previousTrafficCounter = current
        } else {
            previousTrafficCounter = nil
        }
        if let download, let upload, download.isFinite, upload.isFinite {
            trafficHistory.append(TrafficSample(date: date, download: download, upload: upload))
        }
        trafficHistory.removeAll { date.timeIntervalSince($0.date) > 300 }
        if trafficHistory.count > 300 {
            trafficHistory.removeFirst(trafficHistory.count - 300)
        }
    }

    func run(_ message: String, restartWait: Bool = false, _ work: @escaping @MainActor (any ClashBackend) async throws -> Void) {
        guard let service else {
            notice = .error("还没连上路由器")
            return
        }
        runTask?.cancel()
        let generation = connectionGeneration
        let deviceID = selectedID
        // 长操作（重下订阅、重启内核）期间先停掉 3 秒轮询：
        // 它每轮都要向路由器发 root shell，会和长命令抢同一条通道，
        // 而 UFI 的服务端在执行长命令时是整体阻塞的 —— 两边互等，看起来就是"卡住"。
        pollTask?.cancel()
        pollTask = nil
        failoverTask?.cancel()
        failoverTask = nil
        isBusy = true
        notice = .info(message)
        runTask = Task { @MainActor [weak self] in
            do {
                try await work(service)
                guard self?.connectionGeneration == generation, self?.selectedID == deviceID else { return }
                if restartWait {
                    try await Task.sleep(for: .seconds(2.4))
                }
                await self?.refresh(full: true)
                guard self?.connectionGeneration == generation, self?.selectedID == deviceID else { return }
                self?.isBusy = false
                self?.notice = .success("完成")
            } catch is CancellationError {
                guard self?.connectionGeneration == generation, self?.selectedID == deviceID else { return }
                self?.startPolling()
                return
            } catch {
                guard self?.connectionGeneration == generation, self?.selectedID == deviceID else { return }
                self?.isBusy = false
                self?.notice = .error(error.localizedDescription)
            }
            self?.startPolling()
            self?.runTask = nil
        }
    }

    func setRunning(_ running: Bool) {
        let generation = connectionGeneration
        run(running ? "正在启动…" : "正在停止…", restartWait: true) {
            try await $0.setRunning(running)
            guard self.connectionGeneration == generation else { return }
            self.snapshot.status.running = running
            self.resetTraffic()
        }
    }

    func restart() {
        let generation = connectionGeneration
        run("正在重启核心…", restartWait: true) {
            try await $0.restart()
            guard self.connectionGeneration == generation else { return }
            self.resetTraffic()
        }
    }

    private func resetTraffic() {
        previousTrafficCounter = nil
        trafficHistory.removeAll()
        snapshot.traffic = TrafficSnapshot()
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
        let path = file.path.isEmpty ? file.name : file.path
        let filter = profile.nodeExcludeRegex()
        run("切换配置 \(file.name)…", restartWait: true) {
            try await $0.switchConfig(file)
            try await $0.flattenPolicyGroups(configPath: path, nodeFilter: filter)
        }
    }

    func updateSubscription(named name: String) {
        let path = snapshot.status.configPath
        let filter = profile.nodeExcludeRegex()
        run("正在更新订阅 \(name)，可能需要一两分钟…", restartWait: true) {
            try await $0.updateConfig(filename: name)
            try await $0.flattenPolicyGroups(configPath: path, nodeFilter: filter)
        }
    }

    func saveSubscription(_ sub: Subscription, isNew: Bool) {
        let path = snapshot.status.configPath
        let filter = profile.nodeExcludeRegex()
        run(isNew ? "正在添加并更新订阅，可能需要一两分钟…" : "正在保存订阅…", restartWait: true) {
            try await $0.saveSubscription(sub, isNew: isNew)
            try await $0.flattenPolicyGroups(configPath: path, nodeFilter: filter)
        }
    }

    func deleteSubscription(_ sub: Subscription) {
        run("删除订阅…") {
            try await $0.deleteSubscription(sub)
        }
    }

    /// 按当前代理模式解析正在使用的叶子节点。
    var activeNode: ActiveNodeInfo? {
        switch snapshot.status.ruleMode {
        case .direct:
            return ActiveNodeInfo(rootGroup: "DIRECT", leafName: "DIRECT", chain: ["DIRECT"])
        case .global:
            return resolveLeaf(startingAt: "GLOBAL")
        case .rule:
            guard let group = preferredPolicyGroup() else { return nil }
            return resolveLeaf(startingAt: group.name)
        }
    }

    func preferredPolicyGroup() -> ProxyGroup? {
        let candidates = snapshot.groups.filter {
            $0.selectable
                && $0.name != "GLOBAL"
                && !Self.hiddenProxyGroupNames.contains($0.name)
                && !isDirectOrDomesticName($0.name)
        }
        let preferred = ["节点选择", "漏网之鱼", "手动选择", "PROXY", "Proxy", "proxy", "代理", "🚀", "Select"]
        for key in preferred {
            if let match = candidates.first(where: { $0.name == key || $0.name.localizedCaseInsensitiveContains(key) }) {
                return match
            }
        }
        return candidates.first
    }

    func resolveLeaf(startingAt name: String, depth: Int = 0) -> ActiveNodeInfo? {
        guard depth < 8 else {
            return ActiveNodeInfo(rootGroup: name, leafName: name, chain: [name])
        }
        guard let group = snapshot.groups.first(where: { $0.name == name }) else {
            return ActiveNodeInfo(rootGroup: name, leafName: name, chain: [name])
        }
        let now = group.now
        guard !now.isEmpty else {
            return ActiveNodeInfo(rootGroup: name, leafName: "—", chain: [name])
        }
        if snapshot.groups.contains(where: { $0.name == now && !$0.nodes.isEmpty }) {
            if let child = resolveLeaf(startingAt: now, depth: depth + 1) {
                return ActiveNodeInfo(
                    rootGroup: name,
                    leafName: child.leafName,
                    chain: [name] + child.chain
                )
            }
        }
        return ActiveNodeInfo(rootGroup: name, leafName: now, chain: [name, now])
    }

    private static let hiddenProxyGroupNames: Set<String> = [
        "DIRECT", "REJECT", "PASS", "COMPATIBLE", "Reject", "Direct", "MATCH"
    ]

    func selectNode(group: String, name: String) {
        applySelect(group: group, name: name)
        Task { await pushSelect(group: group, name: name) }
    }

    /// 选中叶子节点。全局模式下会同步写入 GLOBAL；规则模式下可把主组一起切到这个节点。
    func selectLeafNode(_ node: ProxyItem, syncGlobal: Bool = false) {
        Task { _ = await selectLeafNodeAwait(node, syncGlobal: syncGlobal) }
    }

    @discardableResult
    private func selectLeafNodeAwait(_ node: ProxyItem, syncGlobal: Bool = false) async -> Bool {
        let owner = node.ownerGroup.isEmpty ? node.name : node.ownerGroup
        applySelect(group: owner, name: node.name)

        // 主组里已经有这个节点（扁平「节点选择」）→ 直接切主组
        // 否则如果主组里是地区组，就把主组切到那个地区组
        var rootRetarget: (group: String, name: String)?
        if snapshot.status.ruleMode == .rule, let root = preferredPolicyGroup(), owner != root.name {
            if root.nodes.contains(where: { $0.name == node.name }) {
                applySelect(group: root.name, name: node.name)
                rootRetarget = (root.name, node.name)
            } else if root.nodes.contains(where: { $0.name == owner }) {
                applySelect(group: root.name, name: owner)
                rootRetarget = (root.name, owner)
            }
        }

        var globalTarget: String?
        if syncGlobal || snapshot.status.ruleMode == .global, owner != "GLOBAL",
           let global = snapshot.groups.first(where: { $0.name == "GLOBAL" }) {
            let names = Set(global.nodes.map(\.name))
            if names.contains(node.name) {
                globalTarget = node.name
            } else if names.contains(owner) {
                globalTarget = owner
            }
            if let globalTarget {
                applySelect(group: "GLOBAL", name: globalTarget)
            }
        }

        var ok = await pushSelect(group: owner, name: node.name)
        if let rootRetarget {
            ok = await pushSelect(group: rootRetarget.group, name: rootRetarget.name) && ok
        }
        if let globalTarget {
            ok = await pushSelect(group: "GLOBAL", name: globalTarget) && ok
        }
        return ok
    }

    private func applySelect(group: String, name: String) {
        guard let idx = snapshot.groups.firstIndex(where: { $0.name == group }) else { return }
        snapshot.groups[idx].now = name
    }

    /// 真正把选择写到路由器。返回是否成功 —— 失败就不要再报「已切换」。
    private func pushSelect(group: String, name: String) async -> Bool {
        guard let service else { return false }
        do {
            try await service.selectProxy(group: group, name: name)
            return true
        } catch {
            notice = .error(error.localizedDescription)
            return false
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

    func ping(_ name: String, failoverOnTimeout: Bool = false) {
        Task {
            let delay = await pingAwait(name)
            guard failoverOnTimeout else { return }
            // 手动点「测试当前节点」= 用户明确要求处理这个结果，不受「自动换节点」开关限制。
            await evaluateFailover(currentDelay: delay, manual: true)
        }
    }

    func pingGroup(_ names: [String]) {
        guard !names.isEmpty else { return }
        pingAllTask?.cancel()
        pingingAll = true
        notice = .info("正在测延迟…")
        pingAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                if self.pingingAll {
                    self.pingingAll = false
                    self.notice = .error("测速超时，请重试")
                }
            }
            defer {
                watchdog.cancel()
                self.pingingAll = false
                self.pingAllTask = nil
            }
            let started = Date()
            // 一次请求让内核把整组测完，正常情况下几秒就结束。
            let results = await self.probeDelays(names, timeoutMs: Self.groupProbeTimeoutMs)
            guard !Task.isCancelled else { return }
            self.applyDelays(results)
            let usable = names.filter { (results[$0] ?? -1) > 0 }.count
            let seconds = Int(Date().timeIntervalSince(started).rounded())
            self.notice = .success("测速完成：\(usable)/\(names.count) 个可用（\(seconds) 秒）")
            // 刚测完就把结果用起来：当前节点要是超时/偏慢，这一轮就换掉，
            // 而不是等下一次周期检测（用户会以为"测出来超时了却不动"）。
            let known = self.activeNode.map { results[$0.leafName] } ?? nil
            await self.evaluateFailover(currentDelay: known, manual: false, preMeasured: results)
        }
    }

    /// 批量测延迟，结果写进 `delayByNode`（`-1` = 测了但没通）。
    ///
    /// 走内核的「整组测速」：一个请求测完一个策略组，内核内部并发，
    /// 耗时上限就是一个超时时间；逐个 `/proxies/{name}/delay` 则要 N 个请求，
    /// 本机侧还要分批等，一批里只要有一个超时节点，整批都得等满超时
    /// —— 几十个节点就是几十秒，这是以前"全部测速很慢"的根因。
    private func probeDelays(_ names: [String], timeoutMs: Int) async -> [String: Int] {
        guard let service, !names.isEmpty else { return [:] }
        let wanted = Set(names)
        var results: [String: Int] = [:]
        var covered: Set<String> = []

        let targets = coveringGroups(for: names)
        if !targets.isEmpty {
            // 有多个地区组时并发发出，互不排队，总耗时仍是一个超时。
            let replies = await withTaskGroup(of: (String, [String: Int]?).self) { group in
                for target in targets {
                    group.addTask { [weak self] in
                        await self?.groupDelayOnce(target.name, timeoutMs: timeoutMs)
                            ?? (target.name, nil)
                    }
                }
                var out: [(String, [String: Int]?)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (groupName, delays) in replies {
                guard let delays else { continue }
                guard let definition = snapshot.groups.first(where: { $0.name == groupName }) else { continue }
                for node in definition.nodes where wanted.contains(node.name) {
                    covered.insert(node.name)
                    // 内核只返回测通的节点：在这个组里却没返回 = 超时/失败。
                    results[node.name] = delays[node.name] ?? -1
                }
            }
        }

        let leftovers = names.filter { !covered.contains($0) }
        if !leftovers.isEmpty {
            for name in leftovers.prefix(Self.fallbackProbeLimit) {
                guard !Task.isCancelled else { break }
                let value = await pingAwait(name, timeoutMs: timeoutMs)
                results[name] = value
            }
        }
        return results
    }

    /// 单个策略组的整组测速（失败返回 nil，用 nil 区分「测了但都不通」和「没测成」）。
    private func groupDelayOnce(_ group: String, timeoutMs: Int) async -> (String, [String: Int]?) {
        guard let service else { return (group, nil) }
        do {
            return (group, try await service.testGroupDelay(group: group, timeoutMs: timeoutMs))
        } catch {
            return (group, nil)
        }
    }

    /// 挑出能覆盖目标节点的策略组。整组测速必须用「节点直接挂在下面的组」，
    /// 例如猫猫的「选择节点」，否则测不到东西。
    private func coveringGroups(for names: [String]) -> [ProxyGroup] {
        let wanted = Set(names)
        return snapshot.groups
            .filter { $0.selectable && $0.name != "GLOBAL" && !isDirectOrDomesticName($0.name) }
            .map { group -> (group: ProxyGroup, hits: Int) in
                let hits = group.nodes.reduce(0) { $0 + (wanted.contains($1.name) ? 1 : 0) }
                return (group, hits)
            }
            .filter { $0.hits >= 4 }
            .sorted { $0.hits > $1.hits }
            .prefix(4)
            .map(\.group)
    }

    private func applyDelays(_ results: [String: Int]) {
        guard !results.isEmpty else { return }
        for (name, delay) in results {
            delayByNode[name] = delay
        }
    }

    @discardableResult
    private func pingAwait(_ name: String, timeoutMs: Int = AppState.nodeProbeTimeoutMs) async -> Int {
        testingNodes.insert(name)
        defer { testingNodes.remove(name) }
        do {
            guard let service else { return -1 }
            let delay = try await service.testDelay(name: name, timeoutMs: timeoutMs)
            let value = delay == 0 ? -1 : delay
            delayByNode[name] = value
            return value
        } catch {
            delayByNode[name] = -1
            return -1
        }
    }

    func addRule(domain: String, proxy: String) {
        runAcrossDevices("正在同步规则到所有路由器…") { service, configPath in
            try await service.addDirectRule(domain: domain, proxy: proxy, configPath: configPath)
        }
    }

    func matchRule(host: String) -> ClashRule? {
        DomainRulePolicy.match(host: host, rules: snapshot.rules)
    }

    private func runAcrossDevices(
        _ message: String,
        restartWait: Bool = true,
        refreshCurrent: Bool = true,
        _ work: @escaping @MainActor (any ClashBackend, String) async throws -> Void
    ) {
        guard !devices.isEmpty else {
            notice = .error("还没有路由器")
            return
        }
        runTask?.cancel()
        isBusy = true
        notice = .info(message)
        let allDevices = devices
        let currentID = selectedID
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for device in allDevices {
                guard !Task.isCancelled else { return }
                do {
                    let backend: any ClashBackend = device.plugin == .maomao
                        ? MaoMaoService(device: device)
                        : OpenClashService(device: device)
                    let snap = try await backend.connect()
                    try Task.checkCancellation()
                    try await work(backend, snap.status.configPath)
                    if restartWait {
                        try await Task.sleep(for: .milliseconds(800))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    failures.append("\(device.name)：\(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, currentID == self.selectedID else { return }
            if refreshCurrent, currentID == self.selectedID {
                await self.connect(preservingOperation: true)
            }
            guard !Task.isCancelled, currentID == self.selectedID else { return }
            self.isBusy = false
            if failures.isEmpty {
                self.notice = .success("已同步到所有路由器")
            } else {
                self.notice = .error("部分同步失败：\(failures.joined(separator: "；"))")
            }
            self.runTask = nil
        }
    }

    func refreshDeviceFailover() async {
        guard selectedDevice != nil, let service else {
            deviceFailover = DeviceFailoverStatus()
            return
        }
        let generation = connectionGeneration
        let deviceID = selectedID
        do {
            let status = try await service.deviceFailoverStatus()
            guard connectionGeneration == generation, selectedID == deviceID else { return }
            deviceFailover = status
        } catch {
            guard connectionGeneration == generation, selectedID == deviceID else { return }
            deviceFailover.detail = error.localizedDescription
        }
    }

    var deviceFailoverPanelURL: URL? {
        guard let device = selectedDevice, isConnected else { return nil }
        let port: Int
        switch device.plugin {
        case .maomao:
            port = device.plugin.defaultClashPort
        case .openclash:
            port = snapshot.status.dashboardPort == 0 ? 9090 : snapshot.status.dashboardPort
        }
        return URL(string: "http://\(device.host):\(port)/ui/cr-failover.html")
    }

    func installDeviceFailover() {
        let interval = deviceFailover.installed ? deviceFailover.interval : 5
        let enabled = deviceFailover.installed ? deviceFailover.enabled : true
        run("正在安装到路由器…") { service in
            try await service.installDeviceFailover(interval: interval, enabled: enabled, profile: self.profile)
            await self.refreshDeviceFailover()
        }
    }

    func uninstallDeviceFailover() {
        run("正在卸载设备守护…") { service in
            try await service.uninstallDeviceFailover()
            await self.refreshDeviceFailover()
        }
    }

    func setDeviceFailoverEnabled(_ enabled: Bool) {
        deviceFailover.enabled = enabled
        run(enabled ? "正在开启设备检测…" : "正在关闭设备检测…") { service in
            try await service.updateDeviceFailover(interval: self.deviceFailover.interval, enabled: enabled, profile: self.profile)
            await self.refreshDeviceFailover()
        }
    }

    func setDeviceFailoverInterval(_ seconds: Int) {
        deviceFailover.interval = seconds
        run("正在把检测间隔改成 \(Self.failoverIntervalTitle(seconds))…") { service in
            try await service.updateDeviceFailover(interval: seconds, enabled: self.deviceFailover.enabled, profile: self.profile)
            await self.refreshDeviceFailover()
        }
    }

    func probeDeviceFailoverNow() {
        run("设备上正在测当前节点…") { service in
            try await service.runDeviceFailoverOnce()
            await self.refreshDeviceFailover()
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
            // 超时的本质是"路由器没应答"，绝大多数时候跟代理无关，别再把人往代理上带。
            return "请求超时：路由器没有应答。请依次检查 ① 系统设置 → 隐私与安全性 → 本地网络，" +
                "确认「Clash Remote」已打开；② 地址是否在当前网段（例如 192.168.0.x）；" +
                "③ 本机系统代理是否已关闭；④ 路由器后台忙或插件正在重启时稍等几秒再刷新。"
        }
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotConnectToHost {
            return "连不上 \(ns.userInfo[NSURLErrorFailingURLStringErrorKey] ?? "路由器")（端口没有在监听）。"
        }
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet {
            return "本机没有网络连接，请先连上路由器的 Wi-Fi。"
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == 61 || ns.code == 65) {
            return "连不上路由器。请在系统设置 → 隐私与安全性 → 本地网络里允许「Clash Remote」。"
        }
        return error.localizedDescription
    }

    func updatePollingFrequency() {
        guard service != nil, !isConnecting, !isBusy else { return }
        startPolling(restartFailover: false)
    }

    private func startPolling(restartFailover: Bool = true) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var nextGuardRefresh = Date().addingTimeInterval(15)
            while !Task.isCancelled {
                let seconds = self?.preferences.refreshInterval.seconds ?? 3
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { break }
                await self?.refresh(full: false)
                guard !Task.isCancelled else { break }
                // 设备守护的状态几秒内不会变，而每问一次都要在路由器上开一次 root shell：
                // 每 3 秒问一次是纯浪费，还会和测速抢路由器的 CPU。
                if Date() >= nextGuardRefresh {
                    await self?.refreshDeviceFailover()
                    nextGuardRefresh = Date().addingTimeInterval(15)
                }
            }
        }
        if restartFailover { restartFailoverWatch() }
    }

    static func failoverIntervalTitle(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 分钟" : "\(minutes) 分钟"
    }

    private func restartFailoverWatch() {
        failoverTask?.cancel()
        failoverTask = nil
        guard autoFailoverEnabled, connectedDeviceID != nil else { return }
        failoverTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(self?.autoFailoverInterval ?? 30, 5)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { break }
                await self?.runAutoFailover()
            }
        }
    }

    private func runAutoFailover() async {
        await evaluateFailover(currentDelay: nil, manual: false)
    }

    /// 当前节点不行了就换掉。周期检测、手动测试、整组测速共用这一条路径。
    ///
    /// - Parameters:
    ///   - currentDelay: 已经测出来的当前节点延迟（`-1` = 超时）。传 `nil` 表示还没测，这里自己测一次。
    ///   - manual: 用户手动点击触发。手动是最明确的意图，不看「自动换节点」开关。
    ///   - preMeasured: 刚刚这批节点的测速结果（例如「全部测速」跑完）。有就直接用，不用再测一遍。
    private func evaluateFailover(
        currentDelay: Int?,
        manual: Bool,
        preMeasured: [String: Int]? = nil
    ) async {
        // 手动点击时把「为什么没换」说清楚：以前这些分支都是静默 return，
        // 用户点了半天只看到"超时"，完全不知道卡在哪一步。
        guard manual || autoFailoverEnabled else { return }
        guard !failoverBusy, !isBusy, !isConnecting else {
            if manual { notice = .info("正在忙别的操作，稍后再试") }
            return
        }
        guard connectedDeviceID != nil, connectedDeviceID == selectedID, service != nil else {
            if manual { notice = .error("还没连上路由器") }
            return
        }
        guard snapshot.status.running else {
            if manual { notice = .error("内核没在运行，切不了节点") }
            return
        }
        guard snapshot.status.ruleMode != .direct else {
            if manual { notice = .info("当前是直连模式，不走节点") }
            return
        }
        guard let active = activeNode else { return }
        let leaf = active.leafName
        guard isSwitchableLeaf(leaf) else {
            if manual { notice = .info("当前生效的不是可切换节点（\(leaf)）") }
            return
        }

        // 被拉黑的节点不讲条件：延迟再好也换走，也不做「抖一下就留下」的宽容。
        let leafBlocked = profile.isBlocked(leaf)

        failoverBusy = true
        defer { failoverBusy = false }

        let delay: Int
        if leafBlocked {
            // 已经被拉黑，不必再花时间测它。
            delay = -1
        } else if let currentDelay, currentDelay > 0 || manual {
            // 手动测出来的是单节点实测结果，直接采信；
            // 整组测速报"通了"也是可信的。
            delay = currentDelay
        } else {
            // 要么还没测，要么是整组测速报的"没通"——批量结果偶尔会因为内核忙而漏测，
            // 而换节点是不可逆的动作，所以先单独复核一次再动手。
            guard !testingNodes.contains(leaf) else { return }
            delay = await pingAwait(leaf)
        }
        guard !Task.isCancelled, service != nil else { return }

        // 通了而且没超过阈值 → 保持现状（「固定当前节点」开着时阈值是 0，也就是只要还通就不换）。
        if !leafBlocked, delay > 0, !isDirectOrDomesticName(leaf) {
            let threshold = profile.effectiveFailoverThreshold
            if threshold <= 0 || delay < threshold {
                failoverNoCandidateNotified = false
                return
            }
        }

        let candidates = failoverCandidates(excluding: leaf, active: active)
        guard !candidates.isEmpty else {
            notifyNoFailoverCandidate(timedOut: delay <= 0)
            return
        }

        // 关键：一次请求让内核把整组测完（几秒），而不是逐个测所有候选
        // —— 逐个测是以前"半天不换节点"的根因（几十个节点要等几十秒）。
        let measured: [String: Int]
        if let preMeasured {
            measured = preMeasured
        } else {
            notice = .info(leafBlocked
                ? "当前节点已被拉黑，正在换到其它节点…"
                : (delay <= 0 ? "当前节点超时，正在找可用节点…" : "当前节点偏慢，正在找更快的节点…"))
            // 顺带把当前节点也放进去：整组测速本来就是整组跑，不额外花时间，
            // 但能拿到一次"复核"结果（见下面的抖动判断）。
            measured = await probeDelays(candidates + [leaf], timeoutMs: Self.groupProbeTimeoutMs)
        }
        guard !Task.isCancelled, service != nil else { return }

        // 复核：整组测速里当前节点其实是通的 → 刚才那次单节点失败多半是抖动（弱网下很常见），先不换。
        if !leafBlocked, delay <= 0, let recheck = measured[leaf], recheck > 0 {
            let threshold = profile.effectiveFailoverThreshold
            if threshold <= 0 || recheck < threshold {
                delayByNode[leaf] = recheck
                failoverNoCandidateNotified = false
                notice = .info("当前节点只是抖了一下（\(recheck) ms），保持 \(leaf)")
                return
            }
        }

        var bestName: String?
        var bestDelay = Int.max
        for name in candidates {
            guard let value = measured[name], value > 0, value < bestDelay else { continue }
            bestName = name
            bestDelay = value
        }

        guard let bestName else {
            notifyNoFailoverCandidate(timedOut: delay <= 0)
            return
        }
        // 只超时才是"必须换"；只是慢的话，要求新节点明显更快，避开测量抖动带来的来回跳。
        if !leafBlocked, delay > 0, delay - bestDelay < Self.switchHysteresisMs {
            failoverNoCandidateNotified = false
            notice = .info("没有明显更快的节点，保持 \(leaf)")
            return
        }
        guard let item = proxyItem(named: bestName, preferredOwner: active.ownerGroupName) else {
            notifyNoFailoverCandidate(timedOut: delay <= 0)
            return
        }

        let switched = await selectLeafNodeAwait(item, syncGlobal: snapshot.status.ruleMode == .global)
        do {
            try await service?.closeConnections()
        } catch {}
        guard switched else {
            notice = .error("换节点失败：路由器没有接受这次切换")
            return
        }
        failoverNoCandidateNotified = false
        recordFailover(from: leaf, to: bestName, delay: bestDelay, source: "本机")
        notice = .success("已切换到 \(bestName)（\(bestDelay) ms）")
    }

    func recordFailover(from: String, to: String, delay: Int, source: String) {
        let event = FailoverEvent(from: from, to: to, delay: delay, source: source)
        failoverHistory.insert(event, at: 0)
        if failoverHistory.count > Self.historyLimit {
            failoverHistory = Array(failoverHistory.prefix(Self.historyLimit))
        }
        persistFailoverHistory()
    }

    func clearFailoverHistory() {
        failoverHistory = []
        persistFailoverHistory()
    }

    private func persistFailoverHistory() {
        if let data = try? JSONEncoder().encode(failoverHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    func refreshDeviceFailoverHistory() async {
        guard selectedDevice != nil, let service else {
            deviceFailoverHistory = []
            return
        }
        deviceFailoverHistory = (try? await service.deviceFailoverHistory()) ?? []
    }

    private func notifyNoFailoverCandidate(timedOut: Bool = true) {
        guard !failoverNoCandidateNotified else { return }
        failoverNoCandidateNotified = true
        // 有黑名单时最容易踩的坑：其实是自己把可用节点都拉黑了，这里直接点出来。
        if blockedCount > 0 {
            notice = .error("没有可换的节点（黑名单挡掉了 \(blockedCount) 项，可在「本地配置 → 黑名单」里解除）")
            return
        }
        notice = .error(timedOut ? "当前节点超时，没有其它能连通的节点" : "当前节点偏慢，但没有更快的可用节点")
    }

    private func allLeafNodes() -> [ProxyItem] {
        var nodes: [ProxyItem] = []
        var seen: Set<String> = []
        let groupNames = Set(snapshot.groups.map(\.name))

        func walk(_ group: ProxyGroup, depth: Int) {
            guard depth < 8 else { return }
            for item in group.nodes {
                if let child = snapshot.groups.first(where: { $0.name == item.name && !$0.nodes.isEmpty }) {
                    walk(child, depth: depth + 1)
                    continue
                }
                guard !groupNames.contains(item.name), seen.insert(item.name).inserted else { continue }
                var leaf = item
                leaf.ownerGroup = group.name
                nodes.append(leaf)
            }
        }

        if let root = preferredPolicyGroup() {
            walk(root, depth: 0)
        } else {
            for group in snapshot.groups where group.selectable && group.name != "GLOBAL" {
                walk(group, depth: 0)
            }
        }
        return nodes
    }

    private func isSwitchableLeaf(_ name: String) -> Bool {
        if name.isEmpty || name == "—" { return false }
        if Self.hiddenProxyGroupNames.contains(name) { return false }
        if snapshot.groups.contains(where: { $0.name == name }) { return false }
        return true
    }

    /// 自动换节点时先排除非代理节点；地区和关键词由 profile 控制。
    private func isFailoverCandidate(_ node: ProxyItem) -> Bool {
        guard isSwitchableLeaf(node.name) else { return false }
        let type = node.type.lowercased()
        if type == "direct" || type == "reject" || type == "pass" || type == "compatible" {
            return false
        }
        return !isDirectOrDomesticName(node.name)
    }

    private func isDirectOrDomesticName(_ name: String) -> Bool {
        let folded = name.lowercased()
        if name.contains("直连") {
            return true
        }
        if folded.contains("direct") || folded.contains("reject") {
            return true
        }
        return false
    }

    private func isHongKongName(_ name: String) -> Bool {
        NodeRegion.of(name) == .hongkong
    }

    private func failoverCandidates(excluding current: String, active: ActiveNodeInfo) -> [String] {
        var names: [String] = []
        var seen: Set<String> = [current]

        func appendLeaves(from groupName: String) {
            guard let group = snapshot.groups.first(where: { $0.name == groupName }) else { return }
            for node in group.nodes {
                guard !seen.contains(node.name), isFailoverCandidate(node) else { continue }
                guard !profile.shouldExcludeNode(node.name) else { continue }
                seen.insert(node.name)
                names.append(node.name)
            }
        }

        appendLeaves(from: active.ownerGroupName)

        if let root = preferredPolicyGroup() {
            if root.name != active.ownerGroupName {
                appendLeaves(from: root.name)
            }
            for node in root.nodes where snapshot.groups.contains(where: { $0.name == node.name }) {
                appendLeaves(from: node.name)
            }
        }

        if snapshot.status.ruleMode == .global {
            appendLeaves(from: "GLOBAL")
            if let global = snapshot.groups.first(where: { $0.name == "GLOBAL" }) {
                for node in global.nodes where snapshot.groups.contains(where: { $0.name == node.name }) {
                    appendLeaves(from: node.name)
                }
            }
        }

        return names.sorted { a, b in
            failoverScore(a) < failoverScore(b)
        }
    }

    private func failoverScore(_ name: String) -> Int {
        guard let delay = delayByNode[name] else { return 5_000 }
        if delay < 0 { return 100_000 }
        return delay
    }

    private func proxyItem(named name: String, preferredOwner: String?) -> ProxyItem? {
        if let preferredOwner,
           let group = snapshot.groups.first(where: { $0.name == preferredOwner }),
           let item = group.nodes.first(where: { $0.name == name }) {
            return item
        }
        for group in snapshot.groups {
            if let item = group.nodes.first(where: { $0.name == name }) {
                return item
            }
        }
        return nil
    }

    // MARK: - 固定当前节点

    /// 「固定当前节点」：不再因为「慢」而换节点，只有当前节点真的超时才自动换。
    var pinnedNode: Bool { profile.pinnedNode }

    func setPinnedNode(_ on: Bool) {
        guard profile.pinnedNode != on else { return }
        profile.pinnedNode = on
        persistProfile()
        failoverNoCandidateNotified = false
        notice = .success(on
            ? "已固定当前节点：只要还通就不换，只有超时才自动换"
            : "已取消固定：按 \(profile.failoverThreshold) ms 阈值换节点")
    }

    // MARK: - 黑名单（拉黑节点）

    /// 已拉黑条目数（节点名 + 关键词）。
    var blockedCount: Int { profile.blockedCount }

    func isBlocked(_ name: String) -> Bool { profile.isBlocked(name) }

    /// 当前可见节点里名字含该关键词的节点，用于「拉黑整个订阅」的实时预览。
    func nodesMatching(keyword: String) -> [String] {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        let groupNames = Set(snapshot.groups.map(\.name))
        var out: [String] = []
        var seen: Set<String> = []
        for group in snapshot.groups {
            for node in group.nodes {
                guard !groupNames.contains(node.name) else { continue }
                guard node.name.localizedCaseInsensitiveContains(value) else { continue }
                guard seen.insert(node.name).inserted else { continue }
                out.append(node.name)
            }
        }
        return out
    }

    /// 猜一个能代表「这个节点所属订阅 / 机场」的关键词。
    /// 先拿本地订阅名去套，套不上就从节点名里挑第一个像机场名的词。
    func suggestedBlockKeyword(for nodeName: String) -> String {
        let hits = profile.subscriptions
            .map(\.name)
            .filter { !$0.isEmpty && nodeName.localizedCaseInsensitiveContains($0) }
        if let longest = hits.max(by: { $0.count < $1.count }) { return longest }

        let separators = CharacterSet(charactersIn: " -_|/\\[](){}<>·、,，。｜【】")
            .union(.whitespacesAndNewlines)
        let regionWords: Set<String> = [
            "香港", "台湾", "澳门", "日本", "美国", "新加坡", "韩国", "德国", "英国",
            "法国", "俄罗斯", "加拿大", "澳大利亚", "印度", "土耳其", "越南", "泰国",
            "马来西亚", "菲律宾", "巴西", "荷兰", "直连", "中转", "官网", "到期"
        ]
        for token in nodeName.components(separatedBy: separators) {
            let word = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= 2 else { continue }
            guard word.rangeOfCharacter(from: .letters) != nil else { continue }
            guard !regionWords.contains(word) else { continue }
            return word
        }
        return ""
    }

    /// 拉黑单个节点（精确名称）。
    func blockNode(_ name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !profile.blockedNodes.contains(value) else {
            notice = .info("「\(value)」已经在黑名单里了")
            return
        }
        profile.blockedNodes.append(value)
        finishBlocking("已拉黑 \(value)")
    }

    /// 拉黑一批节点（整个订阅 / 机场）。
    func blockKeyword(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !profile.blockedKeywords.contains(value) else {
            notice = .info("已经拉黑过「\(value)」了")
            return
        }
        let hits = nodesMatching(keyword: value).count
        profile.blockedKeywords.append(value)
        finishBlocking(hits > 1 ? "已拉黑「\(value)」，共 \(hits) 个节点" : "已拉黑「\(value)」")
    }

    func unblockNode(_ name: String) {
        guard profile.blockedNodes.contains(name) else { return }
        profile.blockedNodes.removeAll { $0 == name }
        persistProfile()
        notice = .success("已解除拉黑 \(name)")
    }

    func unblockKeyword(_ keyword: String) {
        guard profile.blockedKeywords.contains(keyword) else { return }
        profile.blockedKeywords.removeAll { $0 == keyword }
        persistProfile()
        notice = .success("已解除拉黑「\(keyword)」")
    }

    func clearBlocklist() {
        guard profile.blockedCount > 0 else { return }
        profile.blockedNodes = []
        profile.blockedKeywords = []
        persistProfile()
        notice = .success("已清空黑名单")
    }

    /// 拉黑之后：存盘、提示；如果当前生效节点正好被拉黑，立刻换走，不等下一轮周期。
    private func finishBlocking(_ message: String) {
        persistProfile()
        notice = .success(message)
        guard let leaf = activeNode?.leafName, !leaf.isEmpty, leaf != "—",
              profile.isBlocked(leaf) else { return }
        Task { await evaluateFailover(currentDelay: nil, manual: true) }
    }

    // MARK: - Profile Sync

    func syncSubscriptionsToRouter() {
        guard service != nil else {
            notice = .error("还没连上路由器")
            return
        }
        let subs = profile.subscriptions.filter(\.enabled)
        guard !subs.isEmpty else {
            notice = .error("没有启用的订阅")
            return
        }
        let path = snapshot.status.configPath
        let existing = snapshot.subscriptions
        run("正在同步 \(subs.count) 个订阅到路由器…", restartWait: true) { svc in
            for sub in subs {
                let installed = existing.first { $0.name == sub.name }
                let routerSub = Subscription(
                    section: installed?.section ?? "", name: sub.name, address: sub.url,
                    enabled: true, userAgent: sub.userAgent
                )
                if installed?.address != routerSub.address || installed?.userAgent != routerSub.userAgent
                    || installed?.enabled != true {
                    try await svc.saveSubscription(routerSub, isNew: installed == nil)
                }
            }
            try await svc.flattenPolicyGroups(configPath: path, nodeFilter: self.profile.nodeExcludeRegex())
        }
    }

    func syncDomainRulesToAllRouters() {
        let rules = profile.domainRules
        guard !rules.isEmpty else {
            notice = .error("没有自定义域名规则")
            return
        }
        runAcrossDevices("正在同步 \(rules.count) 条域名规则到所有路由器…") { service, configPath in
            for rule in rules {
                try await service.upsertProfileRule(rule, configPath: configPath)
            }
        }
    }

    func syncFilterToRouter() {
        guard service != nil else {
            notice = .error("还没连上路由器")
            return
        }
        let path = snapshot.status.configPath
        let filter = profile.nodeExcludeRegex()
        run("正在同步过滤规则…", restartWait: true) { svc in
            try await svc.flattenPolicyGroups(configPath: path, nodeFilter: filter)
        }
    }

    func syncAllToRouter() {
        guard service != nil else {
            notice = .error("还没连上路由器")
            return
        }
        let subs = profile.subscriptions.filter(\.enabled)
        let rules = profile.domainRules
        let path = snapshot.status.configPath
        let filter = profile.nodeExcludeRegex()
        let existing = snapshot.subscriptions
        run("正在同步所有设置到路由器…", restartWait: true) { svc in
            // 订阅的写法每台设备不一样：OpenClash 加 proxy-providers，猫猫要写插件自己的订阅清单。
            try await svc.applySubscriptions(subs, existing: existing)
            for rule in rules {
                try await svc.upsertProfileRule(rule, configPath: path)
            }
            // 猫猫生成的策略组自带 filter 正则（按用途分组），折叠会毁掉它们，所以由设备自己决定。
            if svc.needsGroupFlattening {
                try await svc.flattenPolicyGroups(configPath: path, nodeFilter: filter)
            }
        }
    }
}
