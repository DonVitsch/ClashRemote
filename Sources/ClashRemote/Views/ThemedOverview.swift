import AppKit
import Charts
import SwiftUI

/// The overview uses three arrangements shared by the five appearance themes.
struct ThemedOverview: View {
    @Environment(AppState.self) private var state
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.appTextScale) private var textScale
    @Environment(\.appTheme) private var theme
    @ThemePalette private var palette
    @State private var trendMinutes = 5

    let onAddDevice: () -> Void
    let navigate: (WorkspaceSection) -> Void

    private var running: Bool { state.isConnected && state.snapshot.status.running }
    private var canControl: Bool { state.isConnected && !state.isBusy && !state.isConnecting }
    private var usesProxy: Bool { state.snapshot.status.ruleMode != .direct }
    private var activeName: String {
        if !state.isConnected { return state.isConnecting ? "正在连接设备" : "尚未连接路由器" }
        if !state.snapshot.status.running { return "代理核心已停止" }
        if !usesProxy { return "直连模式" }
        return state.activeNode?.leafName ?? "尚未选择节点"
    }
    private var statusText: String {
        if state.isConnecting { return "连接中" }
        if !state.isConnected { return "未连接" }
        return running ? (usesProxy ? "代理运行中" : "直连运行中") : "核心已停止"
    }
    private var statusColor: Color { running ? palette.green : palette.muted }
    private var samples: [TrafficSample] {
        guard running else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(trendMinutes * 60))
        return state.trafficHistory.filter { $0.date >= cutoff }
    }
    private var panelSpacing: CGFloat { preferences.density == .comfortable ? 20 : 14 }
    private var panelPadding: CGFloat { preferences.density == .comfortable ? 23 : 18 }
    private var mainPanelHeight: CGFloat {
        (theme.usesCatArtwork ? 310 : 286) + max(textScale - 1, 0) * 180 + (preferences.density == .comfortable ? 20 : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 48, 1)
            ScrollView {
                VStack(spacing: panelSpacing) {
                    switch theme.layout {
                    case .dashboard:
                        mainPanels(width: width)
                        metricStrip(width: width)
                        lowerPanels(width: width)
                    case .cat:
                        mainPanels(width: width)
                        metricStrip(width: width)
                        lowerPanels(width: width)
                    case .console:
                        metricStrip(width: width)
                        mainPanels(width: width)
                        lowerPanels(width: width)
                    }
                    shortcutBar(narrow: width < 680 * textScale)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(palette.ink)
    }

    @ViewBuilder private func mainPanels(width: CGFloat) -> some View {
        if width < 680 * textScale {
            VStack(spacing: panelSpacing) {
                proxyPanel.frame(height: mainPanelHeight)
                trafficPanel.frame(height: mainPanelHeight)
            }
        } else if theme.layout == .cat {
            HStack(alignment: .top, spacing: panelSpacing) {
                proxyPanel.frame(width: (width - panelSpacing) * 0.51, height: mainPanelHeight)
                trafficPanel.frame(maxWidth: .infinity).frame(height: mainPanelHeight)
            }
        } else {
            HStack(alignment: .top, spacing: panelSpacing) {
                trafficPanel.frame(width: (width - panelSpacing) * (theme.layout == .console ? 0.57 : 0.56), height: mainPanelHeight)
                proxyPanel.frame(maxWidth: .infinity).frame(height: mainPanelHeight)
            }
        }
    }

    private var trafficPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("流量趋势").appFont(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Menu {
                    Button("最近 1 分钟") { trendMinutes = 1 }
                    Button("最近 5 分钟") { trendMinutes = 5 }
                } label: {
                    HStack(spacing: 5) {
                        Text("最近 \(trendMinutes) 分钟")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .appFont(.system(size: 10))
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            HStack(spacing: 15) {
                trafficLegend("下载", value: metric(state.snapshot.traffic.down), color: palette.blue)
                trafficLegend("上传", value: metric(state.snapshot.traffic.up), color: uploadColor)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            if samples.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("单位：MB/s").appFont(.system(size: 9)).foregroundStyle(palette.muted)
                    trendChart.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: running ? "waveform.path" : "chart.xyaxis.line")
                        .font(.system(size: 31, weight: .light)).foregroundStyle(palette.blue.opacity(0.65))
                    Text(chartEmptyTitle).appFont(.system(size: 12, weight: .medium))
                    Text(chartEmptyDetail).appFont(.system(size: 10)).foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: 250)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.surfaceMuted.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(panelPadding)
        .overviewSurface()
    }

    private var uploadColor: Color { theme.usesCatArtwork ? palette.amber : palette.cyan }
    private var chartEmptyTitle: String {
        if !state.isConnected { return "连接设备后查看流量" }
        if !running { return "代理核心已停止" }
        return "正在采集流量"
    }
    private var chartEmptyDetail: String {
        if !state.isConnected { return "流量趋势来自路由器的实时数据" }
        if !running { return "启动核心后将继续采集实时数据" }
        return "收到至少两次速率数据后，趋势会显示在这里"
    }

    private var trendChart: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("时间", sample.date), y: .value("下载速率", sample.download / 1_000_000))
                    .foregroundStyle(LinearGradient(colors: [palette.blue.opacity(0.25), palette.blue.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", sample.date), y: .value("速率", sample.download / 1_000_000), series: .value("流量", "下载"))
                    .foregroundStyle(palette.blue).lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", sample.date), y: .value("速率", sample.upload / 1_000_000), series: .value("流量", "上传"))
                    .foregroundStyle(uploadColor).lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(samples.map { max($0.download, $0.upload) / 1_000_000 }.max() ?? 0, 0.1) * 1.15)
        .chartXAxis {
            AxisMarks(values: trendAxisDates) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(palette.border)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute()).appFont(.system(size: 9)).foregroundStyle(palette.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(palette.border)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number == 0 ? "0" : String(format: "%.1f", number))
                            .appFont(.system(size: 9)).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .accessibilityLabel("最近 \(trendMinutes) 分钟下载和上传速率趋势，数据来自路由器")
    }

    private var trendAxisDates: [Date] {
        guard let first = samples.first?.date, let last = samples.last?.date else { return [] }
        let span = last.timeIntervalSince(first)
        return [0.15, 0.5, 0.85].map { first.addingTimeInterval(span * $0) }
    }

    private func trafficLegend(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(palette.muted)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .appFont(.system(size: 10))
    }

    private var proxyPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("当前代理").appFont(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusText).appFont(.system(size: 9, weight: .medium))
                }.foregroundStyle(statusColor)
            }
            if theme.usesCatArtwork {
                HStack(spacing: 4) {
                    currentNodeInfo
                    CatNetworkIllustration().frame(width: 160, height: 90)
                }
            }
            RouterConnectionDiagram(deviceName: state.selectedDevice?.name ?? "路由器", connected: state.isConnected,
                                    running: running, usesProxy: usesProxy)
                .frame(maxWidth: .infinity).frame(height: (theme.usesCatArtwork ? 80 : 105) + max(textScale - 1, 0) * 30)
            if !theme.usesCatArtwork { currentNodeInfo }
            Spacer(minLength: 0)
            connectionActions
        }
        .padding(panelPadding)
        .overviewSurface()
    }

    private var currentNodeInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(activeName).appFont(.system(size: theme.usesCatArtwork ? 17 : 13, weight: .semibold, design: .rounded))
                    .lineLimit(2).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading).help(activeName)
                if !theme.usesCatArtwork { activeDelayBadge }
            }
            if theme.usesCatArtwork { activeDelayBadge }
            Text(routeDetail).appFont(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var activeDelayBadge: some View {
        if running && usesProxy, let node = state.activeNode, let delay = state.delay(for: node.leafName) {
            Text(delay < 0 ? "超时" : "\(delay) ms")
                .appFont(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(delay < 0 ? palette.amber : palette.green)
                .fixedSize()
        }
    }

    private var routeDetail: String {
        if !state.isConnected { return state.selectedDevice?.displayAddress ?? "添加设备以管理代理与节点" }
        if !running { return "启动核心后恢复代理服务" }
        if !usesProxy { return "流量直接访问网络，不经过代理节点" }
        if state.pinnedNode { return "已固定当前节点" }
        return state.autoFailoverEnabled ? "自动切换已开启 · 每 \(state.autoFailoverInterval) 秒检测" : "自动切换已关闭"
    }

    private var connectionActions: some View {
        HStack(spacing: 8) {
            if state.selectedDevice == nil {
                Button(action: onAddDevice) { Label("添加路由器", systemImage: "plus") }
                    .buttonStyle(OverviewButtonStyle(filled: true))
            } else if !state.isConnected {
                Button { Task { await state.connect() } } label: { Label(state.isConnecting ? "连接中" : "连接设备", systemImage: "link") }
                    .buttonStyle(OverviewButtonStyle(filled: true)).disabled(state.isConnecting || state.isBusy)
            } else {
                Button { state.setRunning(!state.snapshot.status.running) } label: {
                    Label(state.snapshot.status.running ? "停止代理" : "启动代理", systemImage: state.snapshot.status.running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(OverviewButtonStyle(filled: true, caution: running)).disabled(!canControl)
            }
            Button { navigate(.nodes) } label: { Label("切换节点", systemImage: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(OverviewButtonStyle(filled: false)).disabled(!state.isConnected || state.isBusy)
        }
    }

    private func metricStrip(width: CGFloat) -> some View {
        VStack(spacing: 14) {
            if width < 700 * textScale {
                HStack(spacing: 0) { downloadMetric; metricDivider; uploadMetric }
                Divider().padding(.horizontal, 14)
                HStack(spacing: 0) { connectionsMetric; metricDivider; memoryMetric }
            } else {
                HStack(spacing: 0) {
                    downloadMetric
                    metricDivider
                    uploadMetric
                    metricDivider
                    connectionsMetric
                    metricDivider
                    memoryMetric
                }
            }
        }
        .padding(.vertical, preferences.density == .comfortable ? 20 : 16)
        .overviewSurface()
    }

    private var downloadMetric: some View {
        metricCell(title: "下载速率", value: metric(state.snapshot.traffic.down), detail: "累计 " + metric(state.snapshot.traffic.downTotal), symbol: "arrow.down", color: palette.blue)
    }
    private var uploadMetric: some View {
        metricCell(title: "上传速率", value: metric(state.snapshot.traffic.up), detail: "累计 " + metric(state.snapshot.traffic.upTotal), symbol: "arrow.up", color: uploadColor)
    }
    private var connectionsMetric: some View {
        metricCell(title: "活动连接", value: running ? "\(state.snapshot.traffic.connections)" : "—", detail: "当前设备", symbol: "point.3.connected.trianglepath.dotted", color: palette.cyan)
    }
    private var memoryMetric: some View {
        metricCell(title: "核心内存", value: metric(state.snapshot.traffic.mem), detail: state.snapshot.status.coreType.isEmpty ? "等待核心信息" : state.snapshot.status.coreType, symbol: "cpu", color: palette.green)
    }

    private var metricDivider: some View {
        Rectangle().fill(palette.border.opacity(0.7)).frame(width: 1, height: 43)
    }

    private func metricCell(title: String, value: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
                .frame(width: 29, height: 29)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: theme.usesCatArtwork ? 15 : 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).appFont(.system(size: 10)).foregroundStyle(palette.muted)
                Text(value).appFont(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text(detail).appFont(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ value: String) -> String {
        guard running, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "—" }
        return value
    }

    @ViewBuilder private func lowerPanels(width: CGFloat) -> some View {
        if width < 700 * textScale {
            VStack(spacing: panelSpacing) {
                modePanel
                guardPanel.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: panelSpacing) {
                modePanel.frame(width: (width - panelSpacing) * 0.62)
                guardPanel.frame(maxWidth: .infinity)
            }
        }
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(palette.blue)
                Text("代理模式").appFont(.system(size: 14, weight: .semibold))
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(RuleMode.allCases) { mode in
                    modeButton(mode)
                }
            }
            .disabled(!canControl)
            Text(state.isConnected ? state.snapshot.status.ruleMode.hint : "连接设备后可切换代理模式")
                .appFont(.system(size: 9)).foregroundStyle(palette.muted)
        }
        .padding(preferences.density == .comfortable ? 22 : 17).frame(minHeight: 138 * textScale, alignment: .topLeading).overviewSurface()
    }

    private func modeButton(_ mode: RuleMode) -> some View {
        let selected = state.isConnected && state.snapshot.status.ruleMode == mode
        return Button { state.setRuleMode(mode) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: mode == .rule ? "arrow.triangle.branch" : (mode == .global ? "globe" : "arrow.right"))
                        .foregroundStyle(selected ? palette.blue : palette.muted)
                    Text(mode.title).appFont(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11)).foregroundStyle(selected ? palette.blue : palette.border)
                }
                Text(mode.hint).appFont(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.blue.opacity(0.07) : palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? palette.blue.opacity(0.6) : palette.border.opacity(0.35), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var guardPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(palette.green)
                Text("设备守护").appFont(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Circle().fill(state.isConnected && state.deviceFailover.isLive ? palette.green : palette.muted).frame(width: 5, height: 5)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(guardTitle).appFont(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(guardDetail).appFont(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(2)
            }
            Button { navigate(.device) } label: { Label("管理守护", systemImage: "arrow.up.right") }
                .buttonStyle(OverviewButtonStyle(filled: false)).disabled(state.selectedDevice == nil)
        }
        .padding(preferences.density == .comfortable ? 22 : 17).frame(maxWidth: .infinity, minHeight: 138 * textScale, alignment: .topLeading).overviewSurface()
    }

    private var guardTitle: String {
        if !state.isConnected { return "连接后查看守护状态" }
        if !state.deviceFailover.installed { return "尚未安装设备守护" }
        if !state.deviceFailover.enabled { return "自动检测已关闭" }
        if !state.deviceFailover.running { return "等待守护启动" }
        if !running { return "守护运行中 · 等待核心" }
        return "设备守护运行中"
    }
    private var guardDetail: String {
        if !state.isConnected { return "守护程序在路由器上独立检测节点" }
        if !state.deviceFailover.installed { return "节点失效时，可在路由器上自动切换" }
        if !running && state.deviceFailover.isLive { return "代理核心启动后恢复节点检测" }
        return state.deviceFailover.phaseTitle
    }

    private func shortcutBar(narrow: Bool) -> some View {
        let layout = narrow ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            shortcut(.subscriptions, title: "订阅", detail: "\(state.snapshot.subscriptions.count) 个来源")
            shortcut(.rules, title: "分流规则", detail: "\(state.snapshot.rules.count) 条规则")
            shortcut(.profile, title: "本地配置", detail: "筛选与自动切换")
        }
    }

    private func shortcut(_ destination: WorkspaceSection, title: String, detail: String) -> some View {
        Button { navigate(destination) } label: {
            HStack(spacing: 8) {
                Image(systemName: destination.symbol).foregroundStyle(palette.blue)
                Text(title).appFont(.system(size: 11, weight: .medium))
                Text(detail).appFont(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 12).overviewSurface(radius: 11)
        }.buttonStyle(.plain)
    }
}

/// The horizontal diagram is code-native, so it remains sharp in all window sizes and themes.
struct RouterConnectionDiagram: View {
    @ThemePalette private var palette
    let deviceName: String
    let connected: Bool
    let running: Bool
    let usesProxy: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let centerY: CGFloat = 30
            let sideX = width * 0.12
            let routerX = width * 0.5
            let nodeX = width * 0.88
            ZStack {
                Canvas { context, _ in
                    var first = Path()
                    first.move(to: CGPoint(x: sideX + 20, y: centerY))
                    first.addLine(to: CGPoint(x: routerX - 30, y: centerY))
                    context.stroke(first, with: .color(connected && running ? palette.cyan.opacity(0.8) : palette.border),
                                   style: StrokeStyle(lineWidth: 1.5, dash: connected && running ? [3, 2] : [3, 4]))
                    var second = Path()
                    second.move(to: CGPoint(x: routerX + 30, y: centerY))
                    second.addLine(to: CGPoint(x: nodeX - 20, y: centerY))
                    context.stroke(second, with: .color(running && usesProxy ? palette.cyan.opacity(0.8) : palette.border),
                                   style: StrokeStyle(lineWidth: 1.5, dash: running && usesProxy ? [3, 2] : [3, 4]))
                }
                endpoint(symbol: "laptopcomputer", label: "本机").position(x: sideX, y: centerY + 12)
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(palette.cyan.opacity(connected && running ? 0.13 : 0.03)).frame(width: 65, height: 65).blur(radius: 7)
                        Circle().fill(palette.surfaceMuted).frame(width: 55, height: 55)
                        Circle().stroke(connected && running ? palette.cyan : palette.border, lineWidth: 1.4).frame(width: 55, height: 55)
                        ThreeAntennaRouter().stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(connected && running ? palette.cyan : palette.muted)
                            .frame(width: 29, height: 24)
                    }
                    Text(deviceName).appFont(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink)
                        .lineLimit(2).multilineTextAlignment(.center).frame(width: max(width * 0.35, 80)).help(deviceName)
                }.position(x: routerX, y: centerY + 11)
                endpoint(symbol: usesProxy ? "globe" : "arrow.right", label: usesProxy ? "节点" : "直连")
                    .position(x: nodeX, y: centerY + 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本机通过 \(deviceName) \(running ? (usesProxy ? "访问代理节点" : "直接访问网络") : "，代理核心未运行")")
    }

    private func endpoint(symbol: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(palette.ink.opacity(0.82))
                .frame(width: 43, height: 43)
                .background(palette.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(palette.border.opacity(0.8), lineWidth: 1))
            Text(label).appFont(.system(size: 9)).foregroundStyle(palette.muted)
        }
    }
}

private struct ThreeAntennaRouter: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.58, width: rect.width * 0.88, height: rect.height * 0.35)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: 2.5, height: 2.5))
        for fraction: CGFloat in [0.2, 0.5, 0.8] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: body.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY + rect.height * (fraction == 0.5 ? 0.06 : 0.2)))
        }
        for fraction: CGFloat in [0.25, 0.42, 0.59] {
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * fraction, y: body.midY - 0.7, width: 1.4, height: 1.4))
        }
        return path
    }
}

struct CatNetworkIllustration: View {
    @ThemePalette private var palette

    var body: some View {
        if let illustration = loadIllustration() {
            Image(nsImage: illustration).resizable().aspectRatio(contentMode: .fit).accessibilityHidden(true)
        } else {
            ZStack {
                Ellipse().fill(palette.green.opacity(0.07)).frame(width: 100, height: 58)
                SimpleCatSilhouette().fill(palette.ink.opacity(0.8)).frame(width: 43, height: 58).offset(x: -5, y: 4)
                Image(systemName: "globe").font(.system(size: 23, weight: .light)).foregroundStyle(palette.green.opacity(0.6)).offset(x: 33, y: -20)
            }.accessibilityHidden(true)
        }
    }

    private func loadIllustration() -> NSImage? {
        if let installedURL = Bundle.main.resourceURL?.appendingPathComponent("ClashRemote_ClashRemote.bundle/CatNetworkIllustration.png"),
           let image = NSImage(contentsOf: installedURL) {
            return image
        }
        // Packaged applications must also render safely when an optional artwork is missing.
        // SwiftPM's generated bundle accessor can terminate if its development bundle is absent.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        if let developmentURL = Bundle.module.url(forResource: "CatNetworkIllustration", withExtension: "png") {
            return NSImage(contentsOf: developmentURL)
        }
        return nil
    }
}

private struct SimpleCatSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.32, y: h * 0.37))
        path.addLine(to: CGPoint(x: w * 0.27, y: h * 0.08))
        path.addQuadCurve(to: CGPoint(x: w * 0.44, y: h * 0.19), control: CGPoint(x: w * 0.3, y: 0))
        path.addQuadCurve(to: CGPoint(x: w * 0.65, y: h * 0.18), control: CGPoint(x: w * 0.55, y: h * 0.14))
        path.addLine(to: CGPoint(x: w * 0.79, y: h * 0.04))
        path.addQuadCurve(to: CGPoint(x: w * 0.8, y: h * 0.38), control: CGPoint(x: w * 0.88, y: h * 0.22))
        path.addQuadCurve(to: CGPoint(x: w * 0.69, y: h * 0.48), control: CGPoint(x: w * 0.83, y: h * 0.45))
        path.addCurve(to: CGPoint(x: w * 0.87, y: h * 0.9), control1: CGPoint(x: w * 0.74, y: h * 0.58), control2: CGPoint(x: w * 0.9, y: h * 0.69))
        path.addQuadCurve(to: CGPoint(x: w * 0.32, y: h * 0.93), control: CGPoint(x: w * 0.6, y: h * 1.04))
        path.addCurve(to: CGPoint(x: w * 0.14, y: h * 0.56), control1: CGPoint(x: w * 0.14, y: h * 0.91), control2: CGPoint(x: w * 0.31, y: h * 0.5))
        path.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.84), control1: CGPoint(x: -w * 0.1, y: h * 0.54), control2: CGPoint(x: -w * 0.1, y: h * 0.78))
        path.addCurve(to: CGPoint(x: w * 0.3, y: h * 0.98), control1: CGPoint(x: w * 0.18, y: h * 0.96), control2: CGPoint(x: w * 0.05, y: h * 1.04))
        path.addLine(to: CGPoint(x: w * 0.32, y: h * 0.87))
        path.addCurve(to: CGPoint(x: w * 0.26, y: h * 0.48), control1: CGPoint(x: w * 0.4, y: h * 0.74), control2: CGPoint(x: w * 0.32, y: h * 0.63))
        path.addQuadCurve(to: CGPoint(x: w * 0.32, y: h * 0.37), control: CGPoint(x: w * 0.23, y: h * 0.4))
        path.closeSubpath()
        return path
    }
}

private struct OverviewSurface: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ThemePalette private var palette
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(palette.border.opacity(theme.isDark ? 0.9 : 0.8), lineWidth: 1))
            .shadow(color: palette.ink.opacity(theme.isDark ? 0 : 0.025), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func overviewSurface(radius: CGFloat = 15) -> some View { modifier(OverviewSurface(radius: radius)) }
}

private struct OverviewButtonStyle: ButtonStyle {
    @ThemePalette private var palette
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    var filled: Bool
    var caution = false
    func makeBody(configuration: Configuration) -> some View {
        let color = caution ? palette.amber : palette.blue
        let foreground = filled ? palette.onAccent : palette.blue
        return configuration.label.appFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(filled ? color : palette.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(filled ? .clear : palette.blue.opacity(0.16), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}
