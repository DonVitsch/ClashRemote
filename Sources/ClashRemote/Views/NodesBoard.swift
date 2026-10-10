import SwiftUI

private struct DisplayGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var nodes: [ProxyItem]
    var selectable: Bool
    var now: String
    var typeLabel: String
}

struct NodesBoard: View {
    @Environment(AppState.self) private var state
    @State private var selectedGroup = ""
    @State private var searchText = ""
    @State private var showFailoverHistory = false
    @State private var blockRequest: BlockRequest?
    let onOpenProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.snapshot.groups.isEmpty {
                ContentUnavailableView(
                    state.isConnected ? "没有节点" : "还没连上路由器",
                    systemImage: "point.3.filled.connected.trianglepath.dotted",
                    description: Text(state.isConnected ? "核心没开，或者 Clash API 连不上。" : "先在左侧选一台路由器。")
                )
            } else {
                if state.snapshot.status.ruleMode == .direct {
                    ContentUnavailableView(
                        "直连模式",
                        systemImage: "arrow.right.circle",
                        description: Text("当前全部直连，不走代理节点。切到「规则」后再选节点。")
                    )
                } else {
                    activeNodeBar
                    if state.deviceFailover.installed || state.selectedDevice?.plugin == .maomao {
                        deviceGuardBar
                    }
                    nodeBar
                    if state.blockedCount > 0 {
                        blockedBar
                    }
                    Divider()
                    nodeGrid
                }
            }
        }
        .sheet(item: $blockRequest) { request in
            BlockNodeSheet(request: request)
        }
        .onAppear { ensureGroup() }
        .onChange(of: state.snapshot.groups.map(\.name)) { _, _ in
            ensureGroup()
        }
        .onChange(of: state.snapshot.status.ruleMode) { _, _ in
            ensureGroup()
        }
    }

    private var displayGroups: [DisplayGroup] {
        NodeBoardLayout.build(
            from: state.snapshot.groups,
            mode: state.snapshot.status.ruleMode,
            profile: state.profile
        )
    }

    private var current: DisplayGroup? {
        displayGroups.first { $0.id == selectedGroup } ?? displayGroups.first
    }

    private var activeNodeBar: some View {
        let active = state.activeNode
        let leaf = active?.leafName ?? "—"
        let delay = active.map { state.delay(for: $0.leafName) } ?? nil
        let testing = active.map { state.testingNodes.contains($0.leafName) } ?? false
        let canPing = active != nil && leaf != "—" && leaf != "DIRECT" && !testing

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(leaf)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .help(active?.displayPath ?? leaf)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if testing {
                    Text("测速中").foregroundStyle(.secondary)
                } else if let delay {
                    Text(delay < 0 ? "超时" : "\(delay) ms")
                        .foregroundStyle(delay < 0 ? .red : delayColor(delay))
                }
                if state.pinnedNode {
                    Label("已固定", systemImage: "pin.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .help("已固定当前节点：延迟再高也不换，只有超时才自动换。")
                }
            }
            HStack(spacing: 12) {
                Toggle("自动换节点", isOn: Binding(
                    get: { state.autoFailoverEnabled },
                    set: { state.autoFailoverEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .help("按间隔检测当前节点；超过本地配置中的阈值时寻找更快的可用节点。")

                Toggle("固定当前节点", isOn: Binding(
                    get: { state.pinnedNode },
                    set: { state.setPinnedNode($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .help("打开后不再因为「慢」而换节点，只有当前节点超时才自动换。设备守护要重新安装一次才用得上。")

                Menu {
                    ForEach(AppState.failoverIntervals, id: \.self) { seconds in
                        Button(AppState.failoverIntervalTitle(seconds)) {
                            state.autoFailoverInterval = seconds
                        }
                    }
                } label: {
                    Text("每 \(AppState.failoverIntervalTitle(state.autoFailoverInterval))")
                }
                .disabled(!state.autoFailoverEnabled)
                .controlSize(.small)

                Spacer(minLength: 0)
                Button {
                    showFailoverHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("自动换节点历史")
                .sheet(isPresented: $showFailoverHistory) {
                    FailoverHistorySheet()
                }
                Button {
                    guard canPing else { return }
                    state.ping(leaf, failoverOnTimeout: true)
                } label: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                }
                .help("测试当前节点；超时或明显偏慢时会立刻换到可用节点。")
                .disabled(!canPing)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var deviceGuardBar: some View {
        let st = state.deviceFailover
        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(st.isLive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text("设备守护")
                .fontWeight(.medium)
            Text(st.isLive ? st.probeLine : st.phaseTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(st.detail)
            Spacer(minLength: 0)
            Button {
                state.probeDeviceFailoverNow()
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .disabled(state.isBusy || !st.installed)
            .help("让设备立即测试当前节点")
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(st.isLive ? Color.green.opacity(0.06) : Color.orange.opacity(0.06))
    }

    private var nodeBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("可选节点")
                    .font(.headline)
                if let current {
                    Text(searchText.isEmpty ? "\(current.nodes.count) 个" : "\(visibleNodes(in: current).count) / \(current.nodes.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            TextField("搜索节点", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 130, maxWidth: 240)
            Button {
                if let current {
                    state.pingGroup(current.nodes.map(\.name))
                }
            } label: {
                Label(state.pingingAll ? "测试中" : "全部测速", systemImage: "speedometer")
            }
            .disabled(state.pingingAll || current?.nodes.isEmpty != false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var blockedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text("黑名单 \(state.blockedCount) 项：自动换节点不会选它们（仍可手动点选）")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("管理") { onOpenProfile() }
                .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private func choose(_ node: ProxyItem, in board: DisplayGroup) {
        state.selectLeafNode(
            node,
            syncGlobal: board.id == "GLOBAL" || state.snapshot.status.ruleMode == .global
        )
        if node.name != "DIRECT" {
            state.ping(node.name)
        }
    }

    private var nodeGrid: some View {
        ScrollView {
            if let current {
                let nodes = visibleNodes(in: current)
                if nodes.isEmpty {
                    ContentUnavailableView {
                        Label(searchText.isEmpty ? "筛选后没有节点" : "没有匹配的节点", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(searchText.isEmpty ? "当前筛选条件隐藏了所有节点，可到本地配置调整地区或机场白名单。" : "试试其他关键词，或清空搜索。")
                    } actions: {
                        Button(searchText.isEmpty ? "调整节点筛选" : "清空搜索") {
                            if searchText.isEmpty { onOpenProfile() }
                            else { searchText = "" }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections(for: nodes), id: \.id) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                if let title = section.title {
                                    Text(title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 210, maximum: 400), spacing: 8)],
                                    spacing: 8
                                ) {
                                    ForEach(section.nodes) { node in
                                        NodeCard(
                                            node: node,
                                            selected: isSelected(node, in: current),
                                            delay: state.delay(for: node.name),
                                            testing: state.testingNodes.contains(node.name),
                                            enabled: current.selectable,
                                            blocked: state.isBlocked(node.name),
                                            action: {
                                                choose(node, in: current)
                                            },
                                            onBlock: {
                                                blockRequest = BlockRequest(node: node, keywordMode: false)
                                            },
                                            onBlockSubscription: {
                                                blockRequest = BlockRequest(node: node, keywordMode: true)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func visibleNodes(in board: DisplayGroup) -> [ProxyItem] {
        guard !searchText.isEmpty else { return board.nodes }
        return board.nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func sections(for proxies: [ProxyItem]) -> [(id: String, title: String?, nodes: [ProxyItem])] {
        let hk = proxies.filter { NodeRegion.of($0.name) == .hongkong }
        let sg = proxies.filter { NodeRegion.of($0.name) == .singapore }
        let rest = proxies.filter { NodeRegion.of($0.name) == .other }
        let regionCount = [hk, sg, rest].filter { !$0.isEmpty }.count
        if regionCount >= 2 && proxies.count >= 8 {
            let regions: [(id: String, title: String?, nodes: [ProxyItem])] = [
                (id: "hk", title: "香港", nodes: hk),
                (id: "sg", title: "新加坡", nodes: sg),
                (id: "rest", title: "其它", nodes: rest)
            ]
            return regions.filter { !$0.nodes.isEmpty }
        }
        return [("nodes", nil, proxies)]
    }

    private func isSelected(_ node: ProxyItem, in board: DisplayGroup) -> Bool {
        if let leaf = state.activeNode?.leafName, leaf != "—" {
            return leaf == node.name
        }
        let owner = node.ownerGroup.isEmpty ? board.id : node.ownerGroup
        return state.snapshot.groups.first { $0.name == owner }?.now == node.name
            || state.snapshot.groups.first { $0.name == board.id }?.now == node.name
    }

    private func ensureGroup() {
        let ids = displayGroups.map(\.id)
        if ids.isEmpty {
            selectedGroup = ""
            return
        }
        if !ids.contains(selectedGroup) {
            if let owner = state.activeNode?.ownerGroupName, ids.contains(owner) {
                selectedGroup = owner
            } else if let preferred = state.preferredPolicyGroup()?.name, ids.contains(preferred) {
                selectedGroup = preferred
            } else {
                selectedGroup = ids.first ?? ""
            }
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 400 { return .green }
        if delay < 1500 { return .orange }
        return .red
    }
}

enum NodeBoardLayout {
    private static let hiddenNames: Set<String> = [
        "DIRECT", "REJECT", "PASS", "COMPATIBLE", "Reject", "Direct", "MATCH", "REJECT-DROP"
    ]

    fileprivate static func build(from groups: [ProxyGroup], mode: RuleMode, profile: LocalProfile) -> [DisplayGroup] {
        if mode == .global, let global = groups.first(where: { $0.name == "GLOBAL" }) {
            let leaves = flattenLeaves(from: global, groups: groups, putGroup: "GLOBAL", profile: profile)
            return [
                DisplayGroup(
                    id: "GLOBAL",
                    title: "节点",
                    nodes: leaves,
                    selectable: true,
                    now: global.now,
                    typeLabel: "选择"
                )
            ]
        }

        var boards: [DisplayGroup] = []
        if let root = preferredGroup(from: groups) {
            let leaves = flattenLeaves(from: root, groups: groups, putGroup: root.name, profile: profile)
            boards.append(
                DisplayGroup(
                    id: root.name,
                    title: "节点",
                    nodes: leaves,
                    selectable: true,
                    now: root.now,
                    typeLabel: "选择"
                )
            )
        }
        return boards
    }

    static func preferredGroup(from groups: [ProxyGroup]) -> ProxyGroup? {
        let candidates = groups.filter {
            $0.selectable
                && $0.name != "GLOBAL"
                && !hiddenNames.contains($0.name)
                && !isDomesticAlias($0.name)
        }
        let keys = ["节点选择", "漏网之鱼", "手动选择", "PROXY", "Proxy", "proxy", "代理", "🚀"]
        for key in keys {
            if let match = candidates.first(where: { $0.name == key || $0.name.localizedCaseInsensitiveContains(key) }) {
                return match
            }
        }
        return candidates.first
    }

    /// 把策略组嵌套拆成真正的节点，界面只选节点、不选组。
    static func flattenLeaves(
        from root: ProxyGroup,
        groups: [ProxyGroup],
        putGroup: String,
        profile: LocalProfile
    ) -> [ProxyItem] {
        var nodes: [ProxyItem] = []
        var seen: Set<String> = []

        func walk(_ group: ProxyGroup, depth: Int) {
            guard depth < 8 else { return }
            let groupNames = Set(groups.map(\.name))
            for item in group.nodes {
                if item.name == "DIRECT" {
                    continue
                }
                if hiddenNames.contains(item.name) { continue }
                if let child = groups.first(where: { $0.name == item.name && !$0.nodes.isEmpty }) {
                    walk(child, depth: depth + 1)
                    continue
                }
                if groupNames.contains(item.name) { continue }
                // 只用「展示筛选」：被用户拉黑的节点保留在列表里（灰掉，可一键解除）。
                if profile.isFilteredOut(item.name) { continue }
                guard seen.insert(item.name).inserted else { continue }
                var leaf = item
                // 能直接写进主组就写主组，否则写所在的那一层（例如旧的地区 url-test）
                if root.nodes.contains(where: { $0.name == item.name }) {
                    leaf.ownerGroup = putGroup
                } else {
                    leaf.ownerGroup = group.name
                }
                nodes.append(leaf)
            }
        }

        walk(root, depth: 0)
        return sortedRegions(nodes)
    }

    static func isDomesticAlias(_ name: String) -> Bool {
        name == "国内直连" || name == "大陆直连" || name == "境内直连" || name == "直连"
    }

    static func sortedRegions(_ nodes: [ProxyItem]) -> [ProxyItem] {
        nodes.sorted { a, b in
            let order: [NodeRegion] = [.hongkong, .singapore, .other]
            let ia = order.firstIndex(of: NodeRegion.of(a.name)) ?? 9
            let ib = order.firstIndex(of: NodeRegion.of(b.name)) ?? 9
            if ia != ib { return ia < ib }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isPolicyGroupName(_ name: String, in groups: [ProxyGroup]) -> Bool {
        groups.contains { $0.name == name }
    }
}

private struct NodeCard: View {
    let node: ProxyItem
    let selected: Bool
    let delay: Int?
    let testing: Bool
    var enabled: Bool = true
    var blocked: Bool = false
    let action: () -> Void
    var onBlock: (() -> Void)?
    var onBlockSubscription: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(node.name)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .foregroundStyle(blocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .strikethrough(blocked, color: .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        delayLabel
                        if selected {
                            Text("当前")
                                .foregroundStyle(.tint)
                        }
                        if blocked {
                            Label("已拉黑", systemImage: "hand.raised.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
                trailingMark
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.09), lineWidth: 1)
            )
            .opacity(enabled ? (blocked ? 0.7 : 1) : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .help(helpText)
        .accessibilityLabel("\(node.name)，\(blocked ? "已拉黑" : selected ? "当前节点" : "选择节点")")
    }

    private var helpText: String {
        if !enabled { return "当前组不可手动选择" }
        if blocked { return "已在黑名单：自动换节点不会选它，仍可手动使用" }
        return "点击切换到这个节点；右上角按钮可拉黑"
    }

    @ViewBuilder
    private var trailingMark: some View {
        VStack(spacing: 6) {
            if let onBlock {
                Button(action: onBlock) {
                    Image(systemName: blocked ? "hand.raised.fill" : "hand.raised.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(blocked ? Color.orange : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 常显一点点，鼠标移上去才完全亮起来 —— 不然这个入口太容易被忽略。
                .opacity(blocked ? 1 : (hovering ? 1 : 0.25))
                .help(blocked ? "已拉黑 —— 点击可解除或调整范围" : "拉黑：自动换节点时不会选它")
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let onBlock {
            Button(blocked ? "拉黑 / 解除…" : "拉黑此节点…") { onBlock() }
        }
        if let onBlockSubscription {
            Button("拉黑同一订阅的节点…") { onBlockSubscription() }
        }
    }

    @ViewBuilder
    private var delayLabel: some View {
        if testing {
            Text("测速中")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        } else if let delay {
            if delay < 0 {
                Text("Timeout")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text("\(delay) ms")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(delayColor(delay))
            }
        } else {
            Text("—")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 400 { return .green }
        if delay < 1500 { return .orange }
        return .red
    }
}

private struct FailoverHistorySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if state.displayedFailoverHistory.isEmpty {
                    Text("还没有自动切换记录。节点超时被换掉之后会出现在这里。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.displayedFailoverHistory) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(event.from)  →  \(event.to)")
                                .font(.body.weight(.medium))
                                .textSelection(.enabled)
                            Text("\(event.delay) ms · \(event.source)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("切换历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清空本机") { state.clearFailoverHistory() }
                        .disabled(state.failoverHistory.isEmpty)
                }
            }
            .task { await state.refreshDeviceFailoverHistory() }
        }
        .frame(minWidth: 440, minHeight: 520)
    }
}

/// 打开拉黑面板的请求。同一个面板覆盖两个入口：只拉黑这个节点 / 拉黑整批（订阅、机场）。
struct BlockRequest: Identifiable {
    let node: ProxyItem
    let keywordMode: Bool

    var id: String { node.name + (keywordMode ? "#batch" : "#one") }
}

private struct BlockNodeSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: BlockRequest

    private enum Scope: String, CaseIterable, Identifiable {
        case single = "只拉黑这个节点"
        case keyword = "拉黑整批（订阅/机场）"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .single
    @State private var keyword = ""
    @State private var prepared = false

    private var node: ProxyItem { request.node }
    private var cleanKeyword: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nodeIsBlocked: Bool { state.isBlocked(node.name) }
    private var nodeIsBlockedByName: Bool { state.profile.blockedNodes.contains(node.name) }
    private var keywordIsBlocked: Bool { !cleanKeyword.isEmpty && state.profile.blockedKeywords.contains(cleanKeyword) }
    private var matches: [String] { state.nodesMatching(keyword: cleanKeyword) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("拉黑节点").font(.title2.weight(.semibold))
                Text(node.name)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("范围").font(.callout.weight(.medium))
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if scope == .single {
                Text("只影响这一个节点。拉黑后它会灰掉留在列表里，随时能解除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("关键词").foregroundStyle(.secondary)
                        TextField("机场或订阅名，例如 乌拉", text: $keyword)
                            .textFieldStyle(.roundedBorder)
                    }
                    if cleanKeyword.isEmpty {
                        Text("填一个关键词，名字里带它的节点会被一起拉黑。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if matches.isEmpty {
                        Text("当前列表里没有名字带「\(cleanKeyword)」的节点。仍然可以拉黑这个关键词，以后出现的也会被挡住。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("会一起拉黑 \(matches.count) 个节点：\(matches.prefix(6).joined(separator: "、"))\(matches.count > 6 ? " …" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            if nodeIsBlocked {
                Label(
                    scope == .single
                        ? "这个节点现在在黑名单里（自动换节点不会选它，仍可手动使用）。"
                        : "「\(cleanKeyword.isEmpty ? node.name : cleanKeyword)」相关的节点已在黑名单里。",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Text("黑名单也会同步到路由器和设备守护（需在「本地配置」里点同步）。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 12)
                Button("取消") { dismiss() }
                Button(primaryTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryDisabled)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if keyword.isEmpty {
            keyword = state.suggestedBlockKeyword(for: node.name)
        }
        if request.keywordMode, !cleanKeyword.isEmpty {
            scope = .keyword
        }
    }

    private var primaryTitle: String {
        if scope == .single {
            return nodeIsBlockedByName ? "解除拉黑" : "拉黑这个节点"
        }
        guard !cleanKeyword.isEmpty else { return "请输入关键词" }
        if keywordIsBlocked { return "解除拉黑「\(cleanKeyword)」" }
        return matches.isEmpty ? "拉黑这个关键词" : "拉黑这 \(matches.count) 个节点"
    }

    private var primaryDisabled: Bool {
        scope == .single ? false : cleanKeyword.isEmpty
    }

    private func confirm() {
        if scope == .single {
            if nodeIsBlockedByName {
                state.unblockNode(node.name)
            } else {
                state.blockNode(node.name)
            }
        } else {
            if keywordIsBlocked {
                state.unblockKeyword(cleanKeyword)
            } else {
                state.blockKeyword(cleanKeyword)
            }
        }
        dismiss()
    }
}
