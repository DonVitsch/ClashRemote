import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var tab: MainTab = .control
    @State private var newDomain = ""
    @State private var newRuleProxy = "DIRECT"
    @State private var testHost = ""
    @State private var editingSub: Subscription?
    @State private var addingSub = false

    enum MainTab: String, CaseIterable, Identifiable {
        case control = "控制"
        case subscribe = "订阅"
        case nodes = "节点"
        case rules = "规则"
        case profile = "本地配置"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = state.notice {
                NoticeBar(notice: notice)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Picker("分区", selection: $tab) {
                ForEach(MainTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case .control: controlTab
                case .subscribe: subscribeTab
                case .nodes: nodesTab
                case .rules: rulesTab
                case .profile: ProfileTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await state.refresh(full: true) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(state.isConnecting)
            }
        }
        .sheet(isPresented: $addingSub) {
            SubscriptionEditor(subscription: nil, suggestedName: suggestedSubName)
        }
        .sheet(item: $editingSub) { sub in
            SubscriptionEditor(subscription: sub)
        }
    }

    private var header: some View {
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                deviceHeading
                Spacer(minLength: 8)
                trafficSummary
                deviceActions
            }
            VStack(alignment: .leading, spacing: 10) {
                deviceHeading
                HStack(spacing: 12) {
                    trafficSummary
                    Spacer(minLength: 0)
                    deviceActions
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var deviceHeading: some View {
        let s = state.snapshot.status
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(state.selectedDevice?.name ?? "未选择设备")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                StatusPill(running: s.running && state.isConnected, connecting: state.isConnecting)
            }
            Text(subtitle)
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
                .help(subtitle)
        }
        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
    }

    private var trafficSummary: some View {
        let t = state.snapshot.traffic
        return VStack(alignment: .trailing, spacing: 3) {
            Text("↓ \(t.down.isEmpty ? (t.downTotal.isEmpty ? "—" : t.downTotal) : t.down)   ↑ \(t.up.isEmpty ? (t.upTotal.isEmpty ? "—" : t.upTotal) : t.up)")
                .font(.system(.callout, design: .rounded).monospacedDigit())
                .lineLimit(1)
            Text("连接 \(t.connections) · 内存 \(t.mem.isEmpty ? "—" : t.mem)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var deviceActions: some View {
        let s = state.snapshot.status
        return HStack(spacing: 6) {
            Button { state.setRunning(true) } label: {
                Label("启动", systemImage: "play.fill")
            }
            .disabled(s.running)
            Button { state.setRunning(false) } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .disabled(!s.running)
            Button { state.restart() } label: {
                Label("重启", systemImage: "arrow.clockwise")
            }
        }
        .disabled(state.isBusy || state.isConnecting || state.serviceMissing)
        .controlSize(.regular)
        .fixedSize()
    }

    private var subtitle: String {
        let s = state.snapshot.status
        let device = state.selectedDevice
        var parts: [String] = []
        if let device { parts.append(device.displayAddress) }
        if !s.model.isEmpty { parts.append(s.model) }
        if !s.coreType.isEmpty { parts.append(s.coreType) }
        if !s.runMode.isEmpty { parts.append(s.runMode) }
        if !s.configFileName.isEmpty { parts.append(s.configFileName) }
        return parts.isEmpty ? "选择一台路由器开始" : parts.joined(separator: "  ·  ")
    }

    private var controlTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(state.isConnected ? "当前连接" : "还未连接路由器")
                        .font(.headline)
                    Text(state.isConnected
                         ? "正在使用：\(state.activeNode?.leafName ?? "尚未选择节点")"
                         : "从左侧添加或选择一台路由器。连接后即可选择节点。")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if state.isConnected {
                            Button { tab = .nodes } label: {
                                Label("选择节点", systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            .buttonStyle(.borderedProminent)
                            Button { tab = .profile } label: {
                                Label("设置节点筛选", systemImage: "line.3.horizontal.decrease")
                            }
                        } else if state.selectedDevice != nil {
                            Button { Task { await state.connect() } } label: {
                                Label("重新连接", systemImage: "arrow.clockwise")
                            }
                            .disabled(state.isConnecting)
                        }
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Card(title: "代理模式", subtitle: "日常使用选“规则”；“全局”让所有流量走所选节点，“直连”不走代理。") {
                    Picker("代理模式", selection: Binding(
                        get: { state.snapshot.status.ruleMode },
                        set: { state.setRuleMode($0) }
                    )) {
                        ForEach(RuleMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .disabled(!state.isConnected || state.isBusy)

                Card(title: "流量接管", subtitle: "选择路由器接管设备流量的方式。") {
                    Picker("流量接管", selection: Binding(
                        get: { RunCapture.from(runMode: state.snapshot.status.runMode) },
                        set: { state.setCapture($0) }
                    )) {
                        ForEach(RunCapture.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .disabled(!state.isConnected || state.isBusy)

                deviceFailoverCard

                Card(title: "过滤与开关") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        if state.selectedDevice?.plugin == .openclash {
                            ToggleCard(
                                title: "绕过中国大陆",
                                isOn: Binding(
                                    get: { state.snapshot.status.chinaIPRoute },
                                    set: { state.setChinaIPRoute($0) }
                                )
                            )
                        }
                        ToggleCard(
                            title: "域名嗅探",
                            isOn: Binding(
                                get: { state.snapshot.status.metaSniffer },
                                set: { state.toggleSetting("meta_sniffer", value: $0) }
                            )
                        )
                        if state.selectedDevice?.plugin == .openclash {
                            ToggleCard(
                                title: "尊重规则",
                                isOn: Binding(
                                    get: { state.snapshot.status.respectRules },
                                    set: { state.toggleSetting("respect_rules", value: $0) }
                                )
                            )
                            ToggleCard(
                                title: "海外模式",
                                isOn: Binding(
                                    get: { state.snapshot.status.oversea },
                                    set: { state.toggleSetting("oversea", value: $0) }
                                )
                            )
                        }
                    }
                }

                Card(title: "配置文件") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.snapshot.configs) { file in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .fontWeight(file.current ? .semibold : .regular)
                                    if file.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if file.current {
                                    Text("当前")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.green.opacity(0.15), in: Capsule())
                                } else {
                                    Button("切换") { state.switchConfig(file) }
                                        .disabled(state.isBusy)
                                }
                            }
                            if file.id != state.snapshot.configs.last?.id {
                                Divider()
                            }
                        }
                        if state.snapshot.configs.isEmpty {
                            Text("还没有配置文件")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var deviceFailoverCard: some View {
        let st = state.deviceFailover
        return Card(
            title: "设备超时自动换",
            subtitle: "安装在路由器上独立运行。节点筛选和延迟阈值取自本地配置；修改后请重新安装。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(st.running && st.enabled ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(deviceFailoverHeadline(st))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if st.installed {
                        Toggle(
                            "检测",
                            isOn: Binding(
                                get: { st.enabled },
                                set: { state.setDeviceFailoverEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("写入设备上的开关，下一轮立刻生效")
                    }
                }

                if st.installed {
                    HStack {
                        Text("每")
                            .foregroundStyle(.secondary)
                        Picker("间隔", selection: Binding(
                            get: { st.interval },
                            set: { state.setDeviceFailoverInterval($0) }
                        )) {
                            ForEach(AppState.deviceFailoverIntervals, id: \.self) { seconds in
                                Text(AppState.failoverIntervalTitle(seconds)).tag(seconds)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        Text("测一次当前节点")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(st.phaseTitle)
                        .font(.callout.weight(.medium))
                    Text(st.probeLine)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let updated = st.updatedAt {
                        Text(updated, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !st.log.isEmpty {
                        Text(st.log)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let url = state.deviceFailoverPanelURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("浏览器打开面板") {
                            NSWorkspace.shared.open(url)
                        }
                        .controlSize(.large)
                        Text(url.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 10) {
                    if st.installed {
                        Button("立刻测一轮") { state.probeDeviceFailoverNow() }
                            .disabled(state.isBusy)
                        Button("重新安装") { state.installDeviceFailover() }
                            .disabled(state.isBusy)
                        Button("卸载", role: .destructive) { state.uninstallDeviceFailover() }
                            .disabled(state.isBusy)
                    } else {
                        Button("安装到这台设备") { state.installDeviceFailover() }
                            .disabled(state.isBusy || !state.isConnected)
                    }
                }
                .controlSize(.large)
            }
        }
    }

    private func deviceFailoverHeadline(_ st: DeviceFailoverStatus) -> String {
        if !st.installed { return "还没装到这台设备" }
        if !st.enabled { return "已安装，检测关着" }
        if st.running { return "守护运行中" }
        if st.hooked { return "已挂钩，守护没在跑" }
        return "脚本在，开机启动还没挂上"
    }

    private var subscribeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("订阅链接")
                    .font(.headline)
                Spacer()
                Button("添加订阅") { addingSub = true }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            List {
                ForEach(state.snapshot.subscriptions) { sub in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(sub.name.isEmpty ? sub.section : sub.name)
                                .font(.headline)
                            if !sub.enabled {
                                Text("停用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("更新") {
                                state.updateSubscription(named: sub.name)
                            }
                            .disabled(state.isBusy)
                            Button("编辑") { editingSub = sub }
                        }
                        Text(sub.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            state.deleteSubscription(sub)
                        }
                    }
                }
                if state.snapshot.subscriptions.isEmpty {
                    Text(state.selectedDevice?.plugin == .maomao
                         ? "还没有订阅。添加后会写入猫猫的 config.yaml 并重启核心。"
                         : "还没有订阅。添加后会写入 OpenClash 并立刻拉取节点（可能要一两分钟）。")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private var nodesTab: some View {
        NodesBoard(onOpenProfile: { tab = .profile })
    }

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("规则会同步写到所有路由器；节点页只选择一个当前节点，所有 App 共用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            HStack(spacing: 8) {
                TextField("测规则，例如 guzzoni.apple.com", text: $testHost)
                    .textFieldStyle(.roundedBorder)
                if let hit = ruleTestHit {
                    Text("\(hit.type)  \(hit.payload.isEmpty ? "—" : hit.payload)  →  \(hit.proxy)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(hit.line)
                } else if !DomainRulePolicy.host(from: testHost).isEmpty {
                    Text("没有命中域名规则，可能走 GEOIP / MATCH")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 8) {
                TextField("域名，例如 douyin.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRule() }
                Picker("动作", selection: $newRuleProxy) {
                    Text("直连").tag("DIRECT")
                    Text("拒绝").tag("REJECT")
                    Text("全局").tag("GLOBAL")
                }
                .frame(width: 110)
                Button("写入") { addRule() }
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy)
            }
            .padding(.horizontal, 20)
            Text("自定义规则会同步写到所有路由器并重启核心。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            List(state.snapshot.rules) { rule in
                HStack {
                    Text(rule.type)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(rule.payload.isEmpty ? "—" : rule.payload)
                        .lineLimit(1)
                    Spacer()
                    Text(rule.proxy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private var ruleTestHit: ClashRule? {
        let host = DomainRulePolicy.host(from: testHost)
        guard !host.isEmpty else { return nil }
        return state.matchRule(host: host)
    }

    private var suggestedSubName: String {
        let file = state.snapshot.status.configFileName
        if file.hasSuffix(".yaml") { return String(file.dropLast(5)) }
        if file.hasSuffix(".yml") { return String(file.dropLast(4)) }
        return file
    }

    private func addRule() {
        let domain = newDomain
        let proxy = newRuleProxy
        newDomain = ""
        state.addRule(domain: domain, proxy: proxy)
    }

}

private extension AppState {
    var serviceMissing: Bool { connectedDeviceID == nil }
}

struct StatusPill: View {
    let running: Bool
    let connecting: Bool

    var body: some View {
        Text(connecting ? "连接中" : (running ? "运行中" : "未运行"))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(running ? Color.green : (connecting ? Color.orange : Color.secondary))
            .background(
                (running ? Color.green : (connecting ? Color.orange : Color.secondary)).opacity(0.14),
                in: Capsule()
            )
    }
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct ToggleCard: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
        }
        .toggleStyle(.switch)
        .padding(.vertical, 5)
    }
}

struct SubscriptionEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription?

    @State private var name: String
    @State private var address: String
    @State private var enabled: Bool
    @State private var userAgent: String

    init(subscription: Subscription?, suggestedName: String = "") {
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? suggestedName)
        _address = State(initialValue: subscription?.address ?? "")
        _enabled = State(initialValue: subscription?.enabled ?? true)
        _userAgent = State(initialValue: subscription?.userAgent ?? "clash.meta")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(subscription == nil ? "添加订阅" : "编辑订阅")
                .font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                TextField("订阅链接", text: $address, axis: .vertical)
                    .lineLimit(3...6)
                TextField("UA", text: $userAgent)
                Toggle("启用", isOn: $enabled)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() {
        let sub = Subscription(
            section: subscription?.section ?? "",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            userAgent: userAgent
        )
        state.saveSubscription(sub, isNew: subscription == nil)
        dismiss()
    }
}
