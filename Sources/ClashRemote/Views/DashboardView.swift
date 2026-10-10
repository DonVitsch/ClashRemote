import AppKit
import SwiftUI

struct DashboardView: View {
    @ThemePalette private var palette
    @Environment(AppState.self) private var state
    @Binding var section: WorkspaceSection
    let onAddDevice: () -> Void
    var onEditDevice: () -> Void = {}
    var initialSettingsCategory: SettingsCategory = .general
    @State private var newDomain = ""
    @State private var newRuleProxy = "DIRECT"
    @State private var testHost = ""
    @State private var editingSub: Subscription?
    @State private var addingSub = false

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            if let notice = visibleNotice {
                if section == .nodes {
                    compactNotice(notice)
                } else {
                    NoticeBar(notice: notice)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 4)
                }
            }
            Group {
                switch section {
                case .overview: overviewPage
                case .subscriptions: subscribeTab
                case .nodes: nodesTab
                case .rules: rulesTab
                case .device: deviceControlPage
                case .profile: ProfileTab()
                case .settings: AppSettingsView(initialCategory: initialSettingsCategory)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.canvas)
        .foregroundStyle(palette.ink)
        .buttonStyle(ActionButtonStyle(filled: false))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if section == .device {
                        Button(action: onEditDevice) { Label("编辑设备", systemImage: "square.and.pencil") }
                            .disabled(state.selectedDevice == nil)
                    }
                Button {
                    Task { await state.refresh(full: true) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(state.isConnecting || state.isBusy)
                }
            }
        }
        .sheet(isPresented: $addingSub) {
            SubscriptionEditor(subscription: nil, suggestedName: suggestedSubName)
        }
        .sheet(item: $editingSub) { sub in
            SubscriptionEditor(subscription: sub)
        }
    }

    private var visibleNotice: AppNotice? {
        if section == .overview, let notice = state.notice, case .success(let message) = notice,
           message.hasPrefix("已连接 ") { return nil }
        return state.notice
    }

    private var pageHeader: some View {
        HStack(alignment: section == .nodes ? .center : .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(section.rawValue).appFont(.system(size: section == .nodes ? 22 : 27, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
                    if section == .nodes {
                        Text("代理线路").appFont(.caption).foregroundStyle(.secondary)
                    }
                    if section == .overview { StatusPill(running: state.snapshot.status.running && state.isConnected, connecting: state.isConnecting, connected: state.isConnected) }
                }
                if section != .nodes {
                    Text(pageSubtitle).appFont(.callout).foregroundStyle(.secondary).lineLimit(1).help(pageSubtitle)
                }
            }
            Spacer(minLength: 8)
            if state.isBusy {
                ProgressView().controlSize(.small).help("正在处理设备操作")
            }
            if state.isConnected, section != .overview, section != .settings {
                HStack(spacing: 16) {
                    trafficMetric(symbol: "arrow.down", value: state.snapshot.traffic.down.isEmpty ? "—" : state.snapshot.traffic.down, tint: palette.cyan)
                    trafficMetric(symbol: "arrow.up", value: state.snapshot.traffic.up.isEmpty ? "—" : state.snapshot.traffic.up, tint: palette.blue)
                    trafficMetric(symbol: "point.3.connected.trianglepath.dotted", value: "\(state.snapshot.traffic.connections)", tint: palette.green)
                }
                .padding(.horizontal, 14).padding(.vertical, section == .nodes ? 7 : 10)
                .background(palette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, section == .nodes ? 24 : 30)
        .padding(.top, section == .nodes ? 12 : 25)
        .padding(.bottom, section == .nodes ? 10 : 16)
    }

    private func compactNotice(_ notice: AppNotice) -> some View {
        let appearance: (symbol: String, color: Color)
        switch notice {
        case .info: appearance = ("info.circle.fill", palette.blue)
        case .success: appearance = ("checkmark.circle.fill", palette.green)
        case .error: appearance = ("exclamationmark.triangle.fill", .red)
        }
        return HStack(spacing: 6) {
            Image(systemName: appearance.symbol)
            Text(notice.text).lineLimit(2).help(notice.text)
            Spacer(minLength: 0)
        }
        .appFont(.system(size: 11)).foregroundStyle(appearance.color)
        .padding(.horizontal, 24).padding(.bottom, 6)
    }

    private func trafficMetric(symbol: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).appFont(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            Text(value).appFont(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(palette.ink)
        }
    }

    private var pageSubtitle: String {
        switch section {
        case .overview: subtitle
        case .nodes: "选择、测速和管理当前代理线路"
        case .subscriptions: "管理配置来源，并将更新同步到路由器"
        case .rules: "检查域名如何匹配代理策略"
        case .device: "管理核心、流量接管和设备守护"
        case .profile: "筛选节点并配置自动切换行为"
        case .settings: "调整常规偏好、文字大小与界面主题"
        }
    }

    private var overviewPage: some View {
        ThemedOverview(onAddDevice: onAddDevice, navigate: { section = $0 })
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
        .disabled(state.isBusy || state.isConnecting || !state.isConnected)
        .controlSize(.regular)
        .fixedSize()
    }

    private var subtitle: String {
        let s = state.snapshot.status
        let device = state.selectedDevice
        if !state.isConnected { return device.map { "等待连接 · " + $0.displayAddress } ?? "添加路由器，开始管理你的网络" }
        var parts: [String] = []
        if let device { parts.append(device.displayAddress) }
        if !s.model.isEmpty { parts.append(s.model) }
        if !s.coreType.isEmpty { parts.append(s.coreType) }
        if !s.runMode.isEmpty { parts.append(s.runMode) }
        if !s.configFileName.isEmpty { parts.append(s.configFileName) }
        return parts.isEmpty ? "选择一台路由器开始" : parts.joined(separator: "  ·  ")
    }

    private var deviceControlPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    WorkspaceBanner(symbol: "wifi.router.fill", title: state.selectedDevice?.name ?? "设备控制",
                                    detail: state.isConnected ? subtitle : "连接设备后管理代理核心和流量接管", color: palette.cyan)
                    deviceActions
                }
                Card(title: "流量接管", subtitle: "选择路由器接管设备流量的方式", symbol: "network") {
                    HStack(spacing: 12) {
                        ForEach(RunCapture.allCases) { capture in
                            let selected = RunCapture.from(runMode: state.snapshot.status.runMode) == capture
                            Button { state.setCapture(capture) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(capture.title).appFont(.system(size: 15, weight: .bold, design: .rounded))
                                        Spacer()
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? palette.blue : palette.muted)
                                    }
                                    Text(capture.hint).appFont(.caption).foregroundStyle(.secondary)
                                }
                                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? palette.blue.opacity(0.08) : palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? palette.blue.opacity(0.4) : .clear))
                            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                .disabled(!state.isConnected || state.isBusy)

                deviceFailoverCard.disabled(!state.isConnected || state.isBusy)
                Card(title: "网络选项", subtitle: "根据设备插件显示可用设置", symbol: "switch.2") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        if state.selectedDevice?.plugin == .openclash {
                            ToggleCard(title: "绕过中国大陆", isOn: Binding(get: { state.snapshot.status.chinaIPRoute }, set: { state.setChinaIPRoute($0) }))
                        }
                        ToggleCard(title: "域名嗅探", isOn: Binding(get: { state.snapshot.status.metaSniffer }, set: { state.toggleSetting("meta_sniffer", value: $0) }))
                        if state.selectedDevice?.plugin == .openclash {
                            ToggleCard(title: "尊重规则", isOn: Binding(get: { state.snapshot.status.respectRules }, set: { state.toggleSetting("respect_rules", value: $0) }))
                            ToggleCard(title: "海外模式", isOn: Binding(get: { state.snapshot.status.oversea }, set: { state.toggleSetting("oversea", value: $0) }))
                        }
                    }
                }
                .disabled(!state.isConnected || state.isBusy)

                Card(title: "设备配置文件", subtitle: "切换路由器当前使用的配置", symbol: "doc.text") {
                    if !state.isConnected || state.snapshot.configs.isEmpty {
                        Text("设备上还没有配置文件").foregroundStyle(.secondary).appFont(.callout).padding(.vertical, 6)
                    }
                    ForEach(state.isConnected ? state.snapshot.configs : []) { file in
                        HStack(spacing: 12) {
                            GlyphBadge(symbol: "doc.text", color: file.current ? palette.green : palette.muted, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).appFont(.callout.weight(.medium)).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).appFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if file.current {
                                Label("使用中", systemImage: "checkmark.circle.fill").appFont(.caption.weight(.medium)).foregroundStyle(palette.green)
                            } else {
                                Button("切换配置") { state.switchConfig(file) }.disabled(state.isBusy || !state.isConnected)
                            }
                        }
                        .padding(10).background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }
            .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 30)
        }
    }

    private var deviceFailoverCard: some View {
        let st = state.deviceFailover
        return Card(
            title: "设备守护",
            subtitle: "安装在路由器上独立运行。筛选和阈值修改后需重新安装。",
            symbol: "shield.lefthalf.filled", color: palette.green
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(st.running && st.enabled ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(deviceFailoverHeadline(st))
                        .appFont(.callout.weight(.medium))
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
                    .appFont(.callout)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(st.phaseTitle)
                        .appFont(.callout.weight(.medium))
                    Text(st.probeLine)
                        .appFont(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let updated = st.updatedAt {
                        Text(updated, style: .relative)
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !st.log.isEmpty {
                        Text(st.log)
                            .appFont(.system(.caption2, design: .monospaced))
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
                            .appFont(.system(.caption, design: .monospaced))
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
        if !state.isConnected { return "等待设备连接" }
        if !st.installed { return "尚未安装" }
        if !st.enabled { return "检测已暂停" }
        if st.running { return "守护运行中" }
        if st.hooked { return "等待守护启动" }
        return "尚未启用开机启动"
    }

    private var subscribeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceBanner(symbol: "arrow.down.doc", title: "配置来源", detail: "添加或更新订阅，让路由器获取最新节点。", color: palette.blue)
                HStack {
                    Text("设备上的订阅").appFont(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
                    Text("\(state.isConnected ? state.snapshot.subscriptions.count : 0)").appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { addingSub = true } label: { Label("添加订阅", systemImage: "plus") }
                        .buttonStyle(ActionButtonStyle()).disabled(!state.isConnected || state.isBusy)
                }
                if !state.isConnected || state.snapshot.subscriptions.isEmpty {
                    WorkspaceEmptyState(symbol: "tray.and.arrow.down", title: state.isConnected ? "添加你的第一个订阅" : "等待连接路由器",
                                        detail: state.isConnected ? "保存订阅链接后，节点会同步到当前路由器。" : "先选择并连接左侧的路由器，再管理设备订阅。")
                        .panelSurface()
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(state.snapshot.subscriptions) { sub in
                            subscriptionCard(sub)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive").foregroundStyle(palette.blue)
                    Text("想在多台路由器之间复用订阅？").appFont(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开本地配置") { section = .profile }.buttonStyle(ActionButtonStyle(filled: false))
                }.padding(16).panelSurface(radius: 14)
            }
            .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 30)
        }
    }

    private func subscriptionCard(_ sub: Subscription) -> some View {
        HStack(alignment: .top, spacing: 15) {
            GlyphBadge(symbol: "shippingbox", color: sub.enabled ? palette.blue : palette.muted, size: 44)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(sub.name.isEmpty ? sub.section : sub.name).appFont(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(palette.ink)
                    Text(sub.enabled ? "已启用" : "已停用").appFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(sub.enabled ? palette.green : palette.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((sub.enabled ? palette.green : palette.muted).opacity(0.1), in: Capsule())
                }
                Text(sub.address).appFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text("User-Agent · \(sub.userAgent)").appFont(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Button { state.updateSubscription(named: sub.name) } label: { Label("更新", systemImage: "arrow.clockwise") }
                    .buttonStyle(ActionButtonStyle(filled: false)).disabled(state.isBusy || !state.isConnected)
                Menu {
                    Button("编辑订阅") { editingSub = sub }
                    Divider()
                    Button("删除订阅", role: .destructive) { state.deleteSubscription(sub) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(state.isBusy || !state.isConnected)
            }
        }
        .padding(20).panelSurface()
    }

    private var nodesTab: some View {
        NodesBoard(onOpenProfile: { section = .profile })
    }

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Card(title: "匹配检查", subtitle: "输入域名，查看当前规则如何处理", symbol: "magnifyingglass") {
                    TextField("例如 guzzoni.apple.com", text: $testHost).textFieldStyle(.roundedBorder)
                    if let hit = ruleTestHit {
                        HStack(spacing: 8) {
                            Text(hit.type).appFont(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(palette.blue)
                            Text(hit.proxy).appFont(.caption.weight(.semibold)).foregroundStyle(palette.green)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.green)
                        }.padding(10).background(palette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 9)).help(hit.line)
                    } else {
                        Text(testHost.isEmpty ? "等待输入域名" : "未命中域名规则，可能由 GEOIP / MATCH 处理")
                            .appFont(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                Card(title: "快速分流", subtitle: "写入所有已保存的路由器并重启核心", symbol: "arrow.triangle.branch", color: palette.cyan) {
                    TextField("例如 douyin.com", text: $newDomain).textFieldStyle(.roundedBorder).onSubmit { addRule() }
                    HStack {
                        Picker("动作", selection: $newRuleProxy) {
                            Text("直连").tag("DIRECT")
                            Text("拒绝").tag("REJECT")
                            Text("全局代理").tag("GLOBAL")
                        }.labelsHidden()
                        Button { addRule() } label: { Label("写入规则", systemImage: "plus") }
                            .buttonStyle(ActionButtonStyle())
                            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy || state.devices.isEmpty)
                    }
                }
            }
            HStack {
                Text("当前规则").appFont(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
                Text("\(state.isConnected ? state.snapshot.rules.count : 0) 条").appFont(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !state.isConnected || state.snapshot.rules.isEmpty {
                WorkspaceEmptyState(symbol: "arrow.triangle.branch", title: "暂无设备规则", detail: "连接路由器后，这里会展示核心正在使用的规则。")
                    .frame(maxHeight: .infinity).panelSurface()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack {
                            Text("匹配类型").frame(width: 140, alignment: .leading)
                            Text("目标")
                            Spacer()
                            Text("处理方式")
                        }.appFont(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 17).padding(.vertical, 13).background(palette.surfaceMuted)
                        ForEach(state.snapshot.rules) { rule in
                            HStack(spacing: 12) {
                                Text(rule.type).appFont(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(palette.muted).frame(width: 140, alignment: .leading)
                                Text(rule.payload.isEmpty ? "—" : rule.payload).appFont(.callout).lineLimit(1).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(rule.proxy).appFont(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(rule.proxy == "DIRECT" ? palette.green : (rule.proxy == "REJECT" ? palette.amber : palette.blue))
                                    .padding(.horizontal, 8).padding(.vertical, 4).background(palette.surfaceMuted, in: Capsule())
                            }.padding(.horizontal, 17).padding(.vertical, 11)
                            Divider().padding(.horizontal, 17)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18)).panelSurface()
            }
        }
        .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 30)
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

struct SubscriptionEditor: View {
    @ThemePalette private var palette
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
            WorkspaceBanner(symbol: "arrow.down.doc", title: subscription == nil ? "添加设备订阅" : "编辑设备订阅", detail: "保存后将直接更新当前路由器上的配置来源。")
            VStack(alignment: .leading, spacing: 17) {
                EditorField(title: "订阅名称", symbol: "tag") { TextField("例如 主力机场", text: $name) }
                EditorField(title: "订阅链接", symbol: "link") {
                    TextField("https://…", text: $address, axis: .vertical).lineLimit(3...5)
                }
                EditorField(title: "User-Agent", symbol: "text.alignleft") { TextField("clash.meta", text: $userAgent) }
                Toggle("启用这个订阅", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
            }.padding(20).panelSurface()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存到设备") { save() }
                    .buttonStyle(ActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(palette.canvas)
        .tint(palette.blue)
        .foregroundStyle(palette.ink)
        .buttonStyle(ActionButtonStyle(filled: false))
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
