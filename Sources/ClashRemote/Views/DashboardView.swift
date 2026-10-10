import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Binding var section: WorkspaceSection
    let onAddDevice: () -> Void
    var onEditDevice: () -> Void = {}
    @State private var newDomain = ""
    @State private var newRuleProxy = "DIRECT"
    @State private var testHost = ""
    @State private var editingSub: Subscription?
    @State private var addingSub = false

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            if let notice = state.notice {
                NoticeBar(notice: notice)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 4)
            }
            Group {
                switch section {
                case .overview: overviewPage
                case .subscriptions: subscribeTab
                case .nodes: nodesTab
                case .rules: rulesTab
                case .device: deviceControlPage
                case .profile: ProfileTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClashPalette.canvas)
        .foregroundStyle(ClashPalette.ink)
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

    private var pageHeader: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(section.eyebrow)
                    .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.7)
                    .foregroundStyle(ClashPalette.blue)
                HStack(spacing: 10) {
                    Text(section.rawValue).font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                    if section == .overview { StatusPill(running: state.snapshot.status.running && state.isConnected, connecting: state.isConnecting, connected: state.isConnected) }
                }
                Text(pageSubtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(pageSubtitle)
            }
            Spacer(minLength: 8)
            if state.isBusy {
                ProgressView().controlSize(.small).help("正在处理设备操作")
            }
            if state.isConnected {
                HStack(spacing: 16) {
                    trafficMetric(symbol: "arrow.down", value: state.snapshot.traffic.down.isEmpty ? "—" : state.snapshot.traffic.down, tint: ClashPalette.cyan)
                    trafficMetric(symbol: "arrow.up", value: state.snapshot.traffic.up.isEmpty ? "—" : state.snapshot.traffic.up, tint: ClashPalette.blue)
                    trafficMetric(symbol: "point.3.connected.trianglepath.dotted", value: "\(state.snapshot.traffic.connections)", tint: ClashPalette.green)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ClashPalette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 30).padding(.top, 25).padding(.bottom, 16)
    }

    private func trafficMetric(symbol: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(ClashPalette.ink)
        }
    }

    private var trafficCards: some View {
        let t = state.snapshot.traffic
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: 4), spacing: 13) {
            metricCard("下载速率", value: state.isConnected ? t.down : "—", note: "累计 " + (state.isConnected ? t.downTotal : "—"), symbol: "arrow.down", color: ClashPalette.cyan)
            metricCard("上传速率", value: state.isConnected ? t.up : "—", note: "累计 " + (state.isConnected ? t.upTotal : "—"), symbol: "arrow.up", color: ClashPalette.blue)
            metricCard("活动连接", value: state.isConnected ? "\(t.connections)" : "—", note: "当前设备", symbol: "point.3.connected.trianglepath.dotted", color: ClashPalette.green)
            metricCard("核心内存", value: state.isConnected ? t.mem : "—", note: state.snapshot.status.coreType.isEmpty ? "等待核心信息" : state.snapshot.status.coreType, symbol: "cpu", color: ClashPalette.amber)
        }
    }

    private func metricCard(_ title: String, value: String, note: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            }
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(ClashPalette.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading).panelSurface()
    }

    private var pageSubtitle: String {
        switch section {
        case .overview: subtitle
        case .nodes: "选择、测速和管理当前代理线路"
        case .subscriptions: "管理配置来源，并将更新同步到路由器"
        case .rules: "检查域名如何匹配代理策略"
        case .device: "管理核心、流量接管和设备守护"
        case .profile: "筛选节点并配置自动切换行为"
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                networkHero
                trafficCards
                Card(title: "代理模式", subtitle: "选择流量如何通过你的网络", symbol: "arrow.triangle.branch") {
                    HStack(spacing: 10) {
                        ForEach(RuleMode.allCases) { mode in
                            modeButton(mode)
                        }
                    }
                    .disabled(!state.isConnected || state.isBusy)
                }
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "当前线路", symbol: "globe.asia.australia") {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(state.snapshot.status.ruleMode == .direct ? "全部直连" : (state.activeNode?.leafName ?? "尚未选择节点"))
                                .font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(2).foregroundStyle(ClashPalette.ink)
                            HStack {
                                Label(state.pinnedNode ? "固定当前节点" : "允许自动切换", systemImage: state.pinnedNode ? "pin.fill" : "arrow.triangle.2.circlepath")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let node = state.activeNode, let delay = state.delay(for: node.leafName) {
                                    Text(delay < 0 ? "超时" : "\(delay) ms").font(.caption.weight(.bold)).foregroundStyle(delay < 0 ? .red : ClashPalette.green)
                                }
                            }
                            Button { section = .nodes } label: { Label("打开节点库", systemImage: "arrow.up.right") }
                                .buttonStyle(ActionButtonStyle(filled: false)).disabled(!state.isConnected)
                        }
                    }
                    Card(title: "设备守护", symbol: "shield.lefthalf.filled", color: ClashPalette.green) {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(deviceFailoverHeadline(state.deviceFailover))
                                .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                            Text(state.deviceFailover.installed ? state.deviceFailover.phaseTitle : "在路由器上独立检测，节点失效时自动切换。")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Button { section = .device } label: { Label("管理设备守护", systemImage: "arrow.up.right") }
                                .buttonStyle(ActionButtonStyle(filled: false))
                        }
                    }
                }
                HStack(spacing: 12) {
                    shortcut(.subscriptions, title: "更新订阅", detail: "\(state.snapshot.subscriptions.count) 个配置来源", color: ClashPalette.blue)
                    shortcut(.rules, title: "检查分流", detail: "\(state.snapshot.rules.count) 条当前规则", color: ClashPalette.cyan)
                    shortcut(.profile, title: "筛选与偏好", detail: "本机保存 · 随时同步", color: ClashPalette.amber)
                }
            }
            .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 30)
        }
    }

    private func modeButton(_ mode: RuleMode) -> some View {
        let selected = state.snapshot.status.ruleMode == mode
        let symbol = mode == .rule ? "arrow.triangle.branch" : (mode == .global ? "globe.asia.australia" : "arrow.right")
        return Button { state.setRuleMode(mode) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(selected ? ClashPalette.blue : ClashPalette.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.system(size: 13, weight: .semibold))
                    Text(mode.hint).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? ClashPalette.blue : ClashPalette.border)
            }
            .padding(13).frame(maxWidth: .infinity)
            .background(selected ? ClashPalette.blue.opacity(0.075) : ClashPalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? ClashPalette.blue.opacity(0.45) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shortcut(_ destination: WorkspaceSection, title: String, detail: String, color: Color) -> some View {
        Button { section = destination } label: {
            HStack(spacing: 10) {
                GlyphBadge(symbol: destination.symbol, color: color, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ClashPalette.ink)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14).panelSurface(radius: 14)
        }.buttonStyle(.plain)
    }

    private var networkHero: some View {
        let running = state.snapshot.status.running && state.isConnected
        let currentNode = state.isConnected ? (state.snapshot.status.ruleMode == .direct ? "直连模式 · 不经过代理节点" : (state.activeNode?.leafName ?? "尚未选择节点")) : "连接路由器，开始管理你的网络"
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Circle().fill(running ? ClashPalette.green : ClashPalette.amber).frame(width: 8, height: 8)
                    Text(running ? "PROXY ROUTE ACTIVE" : (state.isConnecting ? "CONNECTING TO ROUTER" : "ROUTE IS INACTIVE"))
                        .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.35)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(state.selectedDevice?.name ?? "让网络，尽在掌握")
                    .font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(ClashPalette.cyan)
                    Text(currentNode).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                HStack(spacing: 9) {
                    if state.selectedDevice == nil {
                        Button(action: onAddDevice) { Label("添加路由器", systemImage: "plus") }
                            .buttonStyle(ActionButtonStyle(color: ClashPalette.cyan, labelColor: Color(red: 0.1, green: 0.16, blue: 0.23)))
                    }
                    Button { state.setRunning(!state.snapshot.status.running) } label: {
                        Label(state.snapshot.status.running ? "停止代理" : "启动代理", systemImage: state.snapshot.status.running ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(ActionButtonStyle(color: running ? ClashPalette.amber : ClashPalette.green, labelColor: running ? Color(red: 0.1, green: 0.16, blue: 0.23) : .white))
                    .disabled(state.isBusy || state.isConnecting || !state.isConnected)
                    Button { section = .nodes } label: { Label("选择节点", systemImage: "point.3.connected.trianglepath.dotted") }
                        .disabled(!state.isConnected)
                        .buttonStyle(ActionButtonStyle(filled: false, onDark: true))
                    if !state.isConnected, state.selectedDevice != nil {
                        Button { Task { await state.connect() } } label: { Label("连接设备", systemImage: "link") }
                            .buttonStyle(ActionButtonStyle(filled: false, onDark: true)).disabled(state.isConnecting)
                    }
                }
                .controlSize(.large)
            }
            Spacer(minLength: 12)
            NetworkArtwork(active: running, usesProxy: state.snapshot.status.ruleMode != .direct)
                .frame(width: 220, height: 150)
                .accessibilityLabel("Mac、路由器和代理节点之间的网络连接示意图")
        }
        .padding(.horizontal, 25).padding(.vertical, 22)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.18, blue: 0.31), Color(red: 0.08, green: 0.34, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(ClashPalette.cyan.opacity(0.12)).frame(width: 250).blur(radius: 20).offset(x: 250, y: -70)
            }.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.13), lineWidth: 1))
        .shadow(color: ClashPalette.ink.opacity(0.12), radius: 18, x: 0, y: 9)
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
                                    detail: state.isConnected ? subtitle : "连接设备后管理代理核心和流量接管", color: ClashPalette.cyan)
                    deviceActions
                }
                Card(title: "流量接管", subtitle: "选择路由器接管设备流量的方式", symbol: "network") {
                    HStack(spacing: 12) {
                        ForEach(RunCapture.allCases) { capture in
                            let selected = RunCapture.from(runMode: state.snapshot.status.runMode) == capture
                            Button { state.setCapture(capture) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(capture.title).font(.system(size: 15, weight: .bold, design: .rounded))
                                        Spacer()
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? ClashPalette.blue : ClashPalette.muted)
                                    }
                                    Text(capture.hint).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? ClashPalette.blue.opacity(0.08) : ClashPalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? ClashPalette.blue.opacity(0.4) : .clear))
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
                        Text("设备上还没有配置文件").foregroundStyle(.secondary).font(.callout).padding(.vertical, 6)
                    }
                    ForEach(state.isConnected ? state.snapshot.configs : []) { file in
                        HStack(spacing: 12) {
                            GlyphBadge(symbol: "doc.text", color: file.current ? ClashPalette.green : ClashPalette.muted, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if file.current {
                                Label("使用中", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(ClashPalette.green)
                            } else {
                                Button("切换配置") { state.switchConfig(file) }.disabled(state.isBusy || !state.isConnected)
                            }
                        }
                        .padding(10).background(ClashPalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 11))
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
            symbol: "shield.lefthalf.filled", color: ClashPalette.green
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
                WorkspaceBanner(symbol: "arrow.down.doc", title: "配置来源", detail: "添加或更新订阅，让路由器获取最新节点。", color: ClashPalette.blue)
                HStack {
                    Text("设备上的订阅").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                    Text("\(state.isConnected ? state.snapshot.subscriptions.count : 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                    Image(systemName: "internaldrive").foregroundStyle(ClashPalette.blue)
                    Text("想在多台路由器之间复用订阅？").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开本地配置") { section = .profile }.buttonStyle(ActionButtonStyle(filled: false))
                }.padding(16).panelSurface(radius: 14)
            }
            .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 30)
        }
    }

    private func subscriptionCard(_ sub: Subscription) -> some View {
        HStack(alignment: .top, spacing: 15) {
            GlyphBadge(symbol: "shippingbox", color: sub.enabled ? ClashPalette.blue : ClashPalette.muted, size: 44)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(sub.name.isEmpty ? sub.section : sub.name).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                    Text(sub.enabled ? "已启用" : "已停用").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(sub.enabled ? ClashPalette.green : ClashPalette.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((sub.enabled ? ClashPalette.green : ClashPalette.muted).opacity(0.1), in: Capsule())
                }
                Text(sub.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text("User-Agent · \(sub.userAgent)").font(.system(size: 10)).foregroundStyle(.tertiary)
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
                            Text(hit.type).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(ClashPalette.blue)
                            Text(hit.proxy).font(.caption.weight(.semibold)).foregroundStyle(ClashPalette.green)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(ClashPalette.green)
                        }.padding(10).background(ClashPalette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 9)).help(hit.line)
                    } else {
                        Text(testHost.isEmpty ? "等待输入域名" : "未命中域名规则，可能由 GEOIP / MATCH 处理")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                Card(title: "快速分流", subtitle: "写入所有已保存的路由器并重启核心", symbol: "arrow.triangle.branch", color: ClashPalette.cyan) {
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
                Text("当前规则").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                Text("\(state.isConnected ? state.snapshot.rules.count : 0) 条").font(.caption).foregroundStyle(.secondary)
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
                        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 17).padding(.vertical, 13).background(ClashPalette.surfaceMuted)
                        ForEach(state.snapshot.rules) { rule in
                            HStack(spacing: 12) {
                                Text(rule.type).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(ClashPalette.muted).frame(width: 140, alignment: .leading)
                                Text(rule.payload.isEmpty ? "—" : rule.payload).font(.callout).lineLimit(1).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(rule.proxy).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(rule.proxy == "DIRECT" ? ClashPalette.green : (rule.proxy == "REJECT" ? ClashPalette.amber : ClashPalette.blue))
                                    .padding(.horizontal, 8).padding(.vertical, 4).background(ClashPalette.surfaceMuted, in: Capsule())
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
        .background(ClashPalette.canvas)
        .tint(ClashPalette.blue)
        .foregroundStyle(ClashPalette.ink)
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
