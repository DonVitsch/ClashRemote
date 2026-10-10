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
    @State private var regionFilter: NodeRegion?
    @State private var sortByDelay = false
    @State private var showFailoverHistory = false
    @State private var blockRequest: BlockRequest?
    let onOpenProfile: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if !state.isConnected || state.snapshot.groups.isEmpty {
                WorkspaceEmptyState(symbol: "point.3.connected.trianglepath.dotted",
                                    title: state.isConnected ? "暂无可用节点" : "先连接你的路由器",
                                    detail: state.isConnected ? "检查代理核心是否运行，或更新订阅获取节点。" : "从左侧选择一台路由器，连接后即可浏览和测速。")
                    .frame(maxHeight: .infinity)
            } else if state.snapshot.status.ruleMode == .direct {
                VStack(spacing: 0) {
                    WorkspaceEmptyState(symbol: "arrow.right", title: "当前使用直连模式", detail: "切换到规则模式，即可挑选代理节点。")
                    Button { state.setRuleMode(.rule) } label: { Label("切换到规则模式", systemImage: "arrow.triangle.branch") }
                        .buttonStyle(ActionButtonStyle()).controlSize(.large).disabled(state.isBusy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                activeNodeBar
                if state.deviceFailover.installed || state.selectedDevice?.plugin == .maomao {
                    deviceGuardBar
                }
                nodeBar
                if state.blockedCount > 0 { blockedBar }
                nodeGrid
            }
        }
        .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 20)
        .sheet(item: $blockRequest) { request in BlockNodeSheet(request: request) }
        .onAppear { ensureGroup() }
        .onChange(of: state.snapshot.groups.map(\.name)) { _, _ in ensureGroup() }
        .onChange(of: state.snapshot.status.ruleMode) { _, _ in ensureGroup() }
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
        let leaf = active?.leafName ?? "尚未选择节点"
        let delay = active.flatMap { state.delay(for: $0.leafName) }
        let testing = active.map { state.testingNodes.contains($0.leafName) } ?? false
        let canPing = active != nil && leaf != "DIRECT" && !testing
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GlyphBadge(symbol: "globe.asia.australia", color: ClashPalette.cyan, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ACTIVE ROUTE").font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(ClashPalette.blue)
                    Text(leaf).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink).lineLimit(1).help(active?.displayPath ?? leaf)
                }
                Spacer(minLength: 0)
                if testing {
                    ProgressView().controlSize(.small)
                } else if let delay {
                    Text(delay < 0 ? "超时" : "\(delay) ms").font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(delay < 0 ? .red : delayColor(delay))
                }
                Button { if canPing { state.ping(leaf, failoverOnTimeout: true) } } label: { Label("测速", systemImage: "speedometer") }
                    .buttonStyle(ActionButtonStyle(filled: false)).disabled(!canPing)
            }
            Divider()
            HStack(spacing: 15) {
                Toggle("自动换节点", isOn: Binding(get: { state.autoFailoverEnabled }, set: { state.autoFailoverEnabled = $0 }))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help("按间隔检查当前节点，超过阈值时寻找更快的节点")
                Toggle("固定当前节点", isOn: Binding(get: { state.pinnedNode }, set: { state.setPinnedNode($0) }))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help("只在当前节点超时时自动切换")
                Spacer(minLength: 0)
                Menu {
                    ForEach(AppState.failoverIntervals, id: \.self) { seconds in
                        Button(AppState.failoverIntervalTitle(seconds)) { state.autoFailoverInterval = seconds }
                    }
                } label: { Text("每 \(AppState.failoverIntervalTitle(state.autoFailoverInterval))检测") }
                    .disabled(!state.autoFailoverEnabled).controlSize(.small)
                Button { showFailoverHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("切换历史").buttonStyle(ActionButtonStyle(filled: false))
                    .sheet(isPresented: $showFailoverHistory) { FailoverHistorySheet() }
            }.font(.caption)
        }
        .padding(20).panelSurface()
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
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(st.isLive ? ClashPalette.green.opacity(0.07) : ClashPalette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }

    private var nodeBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("节点库").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                if let current {
                    Text("\(visibleNodes(in: current).count) / \(current.nodes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索节点名称", text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }.font(.callout).padding(9).frame(maxWidth: 235).background(ClashPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                Button {
                    if let current { state.pingGroup(visibleNodes(in: current).map(\.name)) }
                } label: { Label(state.pingingAll ? "测速中" : "批量测速", systemImage: "speedometer") }
                    .buttonStyle(ActionButtonStyle()).disabled(state.pingingAll || current.map { visibleNodes(in: $0).isEmpty } != false)
            }
            HStack(spacing: 7) {
                regionButton(nil, title: "全部地区")
                regionButton(.hongkong, title: "香港")
                regionButton(.singapore, title: "新加坡")
                regionButton(.other, title: "其它地区")
                Spacer()
                Toggle("按延迟排序", isOn: $sortByDelay).toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                Button { onOpenProfile() } label: { Label("筛选设置", systemImage: "line.3.horizontal.decrease") }
                    .buttonStyle(ActionButtonStyle(filled: false)).controlSize(.small)
            }
        }
        .padding(.top, 3)
    }

    private func regionButton(_ region: NodeRegion?, title: String) -> some View {
        Button { regionFilter = region } label: {
            Text(title).font(.system(size: 11, weight: regionFilter == region ? .semibold : .medium))
                .foregroundStyle(regionFilter == region ? ClashPalette.blue : ClashPalette.muted)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(regionFilter == region ? ClashPalette.blue.opacity(0.10) : ClashPalette.surface, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(regionFilter == region ? .isSelected : [])
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClashPalette.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
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
                                    columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 12)],
                                    spacing: 12
                                ) {
                                    ForEach(section.nodes) { node in
                                        NodeCard(
                                            node: node,
                                            selected: isSelected(node, in: current),
                                            delay: state.delay(for: node.name),
                                            testing: state.testingNodes.contains(node.name),
                                            enabled: current.selectable && state.isConnected && !state.isBusy,
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
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func visibleNodes(in board: DisplayGroup) -> [ProxyItem] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var nodes = board.nodes.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
            && (regionFilter == nil || NodeRegion.of($0.name) == regionFilter)
        }
        if sortByDelay {
            let delays = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, state.delay(for: $0.name) ?? -1) })
            nodes.sort { lhs, rhs in
                func rank(_ node: ProxyItem) -> Int {
                    guard let delay = delays[node.name], delay >= 0 else { return Int.max }
                    return delay
                }
                let l = rank(lhs), r = rank(rhs)
                return l == r ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : l < r
            }
        }
        return nodes
    }

    private func sections(for proxies: [ProxyItem]) -> [(id: String, title: String?, nodes: [ProxyItem])] {
        if sortByDelay { return [("sorted", nil, proxies)] }
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
    static func visibleNodeCount(from groups: [ProxyGroup], mode: RuleMode, profile: LocalProfile) -> Int {
        Set(build(from: groups, mode: mode, profile: profile).flatMap { $0.nodes.map(\.name) }).count
    }

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
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(regionCode)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(selected ? ClashPalette.blue : ClashPalette.muted)
                            .frame(width: 35, height: 35)
                            .background(selected ? ClashPalette.blue.opacity(0.1) : ClashPalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
                        Text(node.name)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(blocked ? ClashPalette.muted : ClashPalette.ink)
                            .strikethrough(blocked, color: .secondary).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                        Color.clear.frame(width: 17, height: 17)
                    }
                    HStack(spacing: 7) {
                        signalBars
                        delayLabel
                        Spacer(minLength: 0)
                        if selected {
                            Label("当前", systemImage: "checkmark.circle.fill").foregroundStyle(ClashPalette.blue)
                        } else if blocked {
                            Label("已拉黑", systemImage: "hand.raised.fill").foregroundStyle(ClashPalette.amber)
                        } else {
                            Text(node.typeLabel).foregroundStyle(.tertiary)
                        }
                    }.font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                }
                .padding(15).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .background(selected ? ClashPalette.blue.opacity(0.065) : ClashPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? ClashPalette.blue.opacity(0.65) : (hovering ? ClashPalette.blue.opacity(0.3) : ClashPalette.border), lineWidth: selected ? 1.5 : 1))
                .shadow(color: .black.opacity(hovering ? 0.05 : 0.02), radius: hovering ? 10 : 4, x: 0, y: 3)
                .opacity(blocked ? 0.65 : 1)
            }
            .buttonStyle(.plain).disabled(!enabled).help(helpText)
            .accessibilityLabel("\(node.name)，\(blocked ? "已拉黑" : selected ? "当前节点" : "选择节点")")
            Menu { menuItems } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 19).padding(13)
        }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var regionCode: String {
        let name = node.name.lowercased()
        if NodeRegion.of(node.name) == .hongkong { return "HK" }
        if NodeRegion.of(node.name) == .singapore { return "SG" }
        if name.contains("日本") || name.contains("🇯🇵") || name.contains("japan") { return "JP" }
        if name.contains("美国") || name.contains("🇺🇸") || name.contains("united states") { return "US" }
        if name.contains("台湾") || name.contains("🇹🇼") || name.contains("taiwan") { return "TW" }
        if name.contains("韩国") || name.contains("🇰🇷") || name.contains("korea") { return "KR" }
        if name.contains("英国") || name.contains("🇬🇧") { return "UK" }
        return "GL"
    }

    private var signalBars: some View {
        let strength = delay.map { $0 < 0 ? 0 : ($0 < 400 ? 4 : ($0 < 1500 ? 3 : 1)) } ?? 0
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1).fill(index < strength ? delayColor(delay ?? 0) : ClashPalette.border)
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }.accessibilityHidden(true)
    }

    private var helpText: String {
        if !enabled { return "当前组不可手动选择" }
        if blocked { return "已在黑名单：自动换节点不会选它，仍可手动使用" }
        return "点击切换到这个节点；右上角菜单可管理黑名单"
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
        VStack(alignment: .leading, spacing: 17) {
            WorkspaceBanner(symbol: "clock.arrow.circlepath", title: "节点切换历史", detail: "查看本机和设备守护的自动切换记录。", color: ClashPalette.cyan)
            ScrollView {
                if state.displayedFailoverHistory.isEmpty {
                    WorkspaceEmptyState(symbol: "clock", title: "还没有切换记录", detail: "自动切换节点后，来源和耗时会记录在这里。")
                } else {
                    LazyVStack(spacing: 11) {
                        ForEach(state.displayedFailoverHistory) { event in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(event.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(event.source).font(.caption2.weight(.semibold)).foregroundStyle(ClashPalette.blue)
                                }
                                HStack(spacing: 10) {
                                    Text(event.from).lineLimit(1)
                                    Image(systemName: "arrow.right").foregroundStyle(ClashPalette.cyan)
                                    Text(event.to).lineLimit(1)
                                }.font(.callout.weight(.medium)).textSelection(.enabled)
                                Text("\(event.delay) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).panelSurface(radius: 13)
                        }
                    }
                }
            }
            HStack {
                Button("清空本机记录") { state.clearFailoverHistory() }.disabled(state.failoverHistory.isEmpty)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ActionButtonStyle())
            }
        }
        .padding(24).frame(width: 580, height: 560)
        .background(ClashPalette.canvas).foregroundStyle(ClashPalette.ink)
        .buttonStyle(ActionButtonStyle(filled: false)).tint(ClashPalette.blue)
        .task { await state.refreshDeviceFailoverHistory() }
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
            WorkspaceBanner(symbol: "hand.raised", title: "管理节点黑名单", detail: node.name, color: ClashPalette.amber)

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
                    .buttonStyle(ActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryDisabled)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(ClashPalette.canvas).foregroundStyle(ClashPalette.ink)
        .buttonStyle(ActionButtonStyle(filled: false)).tint(ClashPalette.blue)
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
