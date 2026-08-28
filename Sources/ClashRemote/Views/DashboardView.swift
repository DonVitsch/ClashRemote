import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var tab: MainTab = .control
    @State private var newDomain = ""
    @State private var newRuleProxy = "DIRECT"
    @State private var editingSub: Subscription?
    @State private var addingSub = false

    enum MainTab: String, CaseIterable, Identifiable {
        case control = "控制"
        case subscribe = "订阅"
        case nodes = "节点"
        case rules = "规则"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
            SubscriptionEditor(subscription: nil)
        }
        .sheet(item: $editingSub) { sub in
            SubscriptionEditor(subscription: sub)
        }
    }

    private var header: some View {
        let s = state.snapshot.status
        let t = state.snapshot.traffic
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(state.selectedDevice?.name ?? "未选择设备")
                        .font(.title2.weight(.semibold))
                    StatusPill(running: s.running && state.isConnected, connecting: state.isConnecting)
                }
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("↓ \(t.down.isEmpty ? (t.downTotal.isEmpty ? "—" : t.downTotal) : t.down)   ↑ \(t.up.isEmpty ? (t.upTotal.isEmpty ? "—" : t.upTotal) : t.up)")
                    .font(.system(.body, design: .rounded).monospacedDigit())
                Text("连接 \(t.connections) · 内存 \(t.mem.isEmpty ? "—" : t.mem)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("启动") { state.setRunning(true) }
                Button("停止") { state.setRunning(false) }
                Button("重启") { state.restart() }
            }
            .disabled(state.isBusy || state.isConnecting || state.serviceMissing)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
                Card(title: "代理模式") {
                    HStack(spacing: 10) {
                        ForEach(RuleMode.allCases) { mode in
                            ModeButton(
                                title: mode.title,
                                selected: state.snapshot.status.ruleMode == mode
                            ) {
                                state.setRuleMode(mode)
                            }
                        }
                    }
                }

                Card(title: "流量接管") {
                    HStack(spacing: 10) {
                        ForEach(RunCapture.allCases) { item in
                            ModeButton(
                                title: item.title,
                                selected: RunCapture.from(runMode: state.snapshot.status.runMode) == item
                            ) {
                                state.setCapture(item)
                            }
                        }
                    }
                }

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
                         : "这台路由器还没有订阅。添加一条就能更新节点。")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private var nodesTab: some View {
        NodesBoard()
    }

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            .padding(.top, 8)
            Text("会写进当前配置文件顶部并重启 OpenClash，适合常用直连/拦截。")
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
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ModeButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    init(subscription: Subscription?) {
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? "")
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
