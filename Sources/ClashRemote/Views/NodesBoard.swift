import SwiftUI

private struct DisplayGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var nodes: [ProxyItem]
}

struct NodesBoard: View {
    @Environment(AppState.self) private var state
    @State private var selectedGroup = "GLOBAL"

    var body: some View {
        VStack(spacing: 0) {
            if state.snapshot.groups.isEmpty {
                ContentUnavailableView(
                    state.isConnected ? "没有节点" : "还没连上路由器",
                    systemImage: "point.3.filled.connected.trianglepath.dotted",
                    description: Text(state.isConnected ? "核心没开，或者 Clash API 连不上。" : "先在左侧选一台路由器。")
                )
            } else {
                groupBar
                Divider()
                nodeGrid
            }
        }
        .onAppear { ensureGroup() }
        .onChange(of: state.snapshot.groups.map(\.name)) { _, _ in
            ensureGroup()
        }
    }

    private var displayGroups: [DisplayGroup] {
        NodeBoardLayout.build(from: state.snapshot.groups)
    }

    private var current: DisplayGroup? {
        displayGroups.first { $0.id == selectedGroup } ?? displayGroups.first
    }

    private var groupBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(displayGroups) { group in
                        GroupTab(
                            title: group.title,
                            subtitle: group.title,
                            selected: group.id == current?.id
                        ) {
                            selectedGroup = group.id
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button {
                if let current {
                    state.pingGroup(current.nodes.map(\.name))
                }
            } label: {
                Label(state.pingingAll ? "测试中" : "延迟测试", systemImage: "speedometer")
            }
            .disabled(state.pingingAll || current == nil)
            .controlSize(.large)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
    }

    private var nodeGrid: some View {
        ScrollView {
            if let current {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections(for: current), id: \.id) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if let title = section.title {
                                Text(title)
                                    .font(.headline)
                                    .padding(.horizontal, 4)
                            }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(section.nodes) { node in
                                    NodeCard(
                                        node: node,
                                        selected: isSelected(node, in: current),
                                        delay: state.delay(for: node.name),
                                        testing: state.testingNodes.contains(node.name)
                                    ) {
                                        state.selectLeafNode(
                                            node,
                                            viewingGlobal: current.id == "GLOBAL" || current.id.hasPrefix("region:")
                                        )
                                        state.ping(node.name)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func sections(for board: DisplayGroup) -> [(id: String, title: String?, nodes: [ProxyItem])] {
        guard board.id == "GLOBAL" else {
            return [(board.id, nil, board.nodes)]
        }
        var basics: [ProxyItem] = []
        var hk: [ProxyItem] = []
        var sg: [ProxyItem] = []
        var rest: [ProxyItem] = []
        for node in board.nodes {
            let fromOther = NodeBoardLayout.isOtherRegion(node.ownerGroup)
            if fromOther {
                switch NodeRegion.of(node.name) {
                case .hongkong: hk.append(node)
                case .singapore: sg.append(node)
                case .other: rest.append(node)
                }
            } else {
                basics.append(node)
            }
        }
        return [
            ("base", nil, basics),
            ("hk", "香港", hk),
            ("sg", "新加坡", sg),
            ("rest", "其它地区", rest)
        ].filter { !$0.nodes.isEmpty }
    }

    private func isSelected(_ node: ProxyItem, in board: DisplayGroup) -> Bool {
        let owner = node.ownerGroup.isEmpty ? "GLOBAL" : node.ownerGroup
        let ownerNow = state.snapshot.groups.first { $0.name == owner }?.now
        if board.id == "GLOBAL" {
            let globalNow = state.snapshot.groups.first { $0.name == "GLOBAL" }?.now
            if owner == "GLOBAL" {
                return globalNow == node.name
            }
            return ownerNow == node.name && globalNow == owner
        }
        return ownerNow == node.name
    }

    private func ensureGroup() {
        let ids = displayGroups.map(\.id)
        if !ids.contains(selectedGroup) {
            selectedGroup = ids.contains("GLOBAL") ? "GLOBAL" : (ids.first ?? "GLOBAL")
        }
    }
}

private enum NodeBoardLayout {
    static func build(from groups: [ProxyGroup]) -> [DisplayGroup] {
        let other = groups.first { isOtherRegion($0.name) }
        let hk = other?.nodes.filter { NodeRegion.of($0.name) == .hongkong } ?? []
        let sg = other?.nodes.filter { NodeRegion.of($0.name) == .singapore } ?? []
        let rest = other?.nodes.filter { NodeRegion.of($0.name) == .other } ?? []

        var tabs: [DisplayGroup] = []
        if let global = groups.first(where: { $0.name == "GLOBAL" }) {
            tabs.append(DisplayGroup(id: "GLOBAL", title: "GLOBAL", nodes: flattenGlobal(global, groups: groups, other: other)))
        }
        if !hk.isEmpty {
            tabs.append(DisplayGroup(id: "region:香港", title: "香港", nodes: hk))
        }
        if !sg.isEmpty {
            tabs.append(DisplayGroup(id: "region:新加坡", title: "新加坡", nodes: sg))
        }

        for group in groups where group.name != "GLOBAL" {
            if isOtherRegion(group.name) {
                if !rest.isEmpty {
                    tabs.append(DisplayGroup(id: group.name, title: "其它地区", nodes: rest))
                }
                continue
            }
            tabs.append(DisplayGroup(id: group.name, title: group.name, nodes: group.nodes))
        }
        return tabs
    }

    static func flattenGlobal(_ global: ProxyGroup, groups: [ProxyGroup], other: ProxyGroup?) -> [ProxyItem] {
        var nodes: [ProxyItem] = []
        for item in global.nodes {
            if isOtherRegion(item.name), let other {
                nodes.append(contentsOf: sortedRegions(other.nodes))
            } else {
                nodes.append(item)
            }
        }
        if !global.nodes.contains(where: { isOtherRegion($0.name) }), let other {
            nodes.append(contentsOf: sortedRegions(other.nodes))
        }
        return nodes
    }

    static func sortedRegions(_ nodes: [ProxyItem]) -> [ProxyItem] {
        nodes.sorted { a, b in
            let ra = NodeRegion.of(a.name)
            let rb = NodeRegion.of(b.name)
            let order: [NodeRegion] = [.hongkong, .singapore, .other]
            let ia = order.firstIndex(of: ra) ?? 9
            let ib = order.firstIndex(of: rb) ?? 9
            if ia != ib { return ia < ib }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isOtherRegion(_ name: String) -> Bool {
        name.contains("其它地区") || name.contains("其他地区") || name.lowercased() == "other"
    }
}

private struct GroupTab: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Capsule()
                    .fill(selected ? Color.primary : Color.clear)
                    .frame(width: selected ? 28 : 12, height: 2)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(subtitle)
    }
}

private struct NodeCard: View {
    let node: ProxyItem
    let selected: Bool
    let delay: Int?
    let testing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(node.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 36, alignment: .top)
                Text(node.typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                delayLabel
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("点击切换到这个节点")
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
