import SwiftUI

struct ProfileTab: View {
    @Environment(AppState.self) private var state
    @State private var editingSubscription: LocalSubscription?
    @State private var addingSubscription = false
    @State private var keyword = ""
    @State private var provider = ""
    @State private var domain = ""
    @State private var ruleType = "DOMAIN-SUFFIX"
    @State private var ruleProxy = "DIRECT"

    private func change(_ edit: (inout LocalProfile) -> Void) {
        edit(&state.profile)
        state.persistProfile()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地配置").font(.title2.weight(.semibold))
                        Text("保存在这台 Mac 上，切换路由器也不会丢。订阅和规则可同步；设备守护设置需重新安装。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.syncAllToRouter()
                    } label: {
                        Label("同步订阅和规则", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.isConnected || state.isBusy)
                }

                Card(title: "订阅链接", subtitle: "先在这里保存，再同步到当前路由器；删掉本地条目不会删除路由器上的订阅。") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.profile.subscriptions) { sub in
                            HStack {
                                Toggle(sub.name, isOn: Binding(
                                    get: { state.profile.subscriptions.first(where: { $0.id == sub.id })?.enabled ?? false },
                                    set: { enabled in
                                        change { profile in
                                            if let index = profile.subscriptions.firstIndex(where: { $0.id == sub.id }) {
                                                profile.subscriptions[index].enabled = enabled
                                            }
                                        }
                                    }
                                ))
                                Text(sub.url).lineLimit(1).truncationMode(.middle)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("编辑") { editingSubscription = sub }
                                Button(role: .destructive) {
                                    change { $0.subscriptions.removeAll { $0.id == sub.id } }
                                } label: { Image(systemName: "trash") }
                                    .help("删除本地订阅")
                            }
                        }
                        if state.profile.subscriptions.isEmpty {
                            Text("尚未保存订阅").foregroundStyle(.secondary)
                        }
                        Button { addingSubscription = true } label: {
                            Label("添加订阅", systemImage: "plus")
                        }
                        Button("同步订阅") { state.syncSubscriptionsToRouter() }
                            .disabled(!state.isConnected || state.isBusy || !state.profile.subscriptions.contains(where: \.enabled))
                    }
                }

                Card(title: "节点筛选", subtitle: "筛选会立即影响节点列表和本机自动切换；重新安装设备守护后在路由器上生效。") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("排除名称含这些文字的节点").font(.callout.weight(.medium))
                        editableTokens(state.profile.filterKeywords, remove: { value in
                            change { $0.filterKeywords.removeAll { $0 == value } }
                        })
                        HStack {
                            TextField("例如 到期", text: $keyword)
                                .onSubmit(addKeyword)
                            Button { addKeyword() } label: { Image(systemName: "plus") }
                                .help("添加排除词")
                                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Divider()
                        Text("排除地区").font(.callout.weight(.medium))
                        ForEach(RegionExclusion.allCases) { region in
                            Toggle(region.note.isEmpty ? region.label : "\(region.label)（\(region.note)）",
                                   isOn: Binding(
                                    get: { state.profile.regionExclusions.contains(region) },
                                    set: { on in
                                        change {
                                            if on { $0.regionExclusions.insert(region) }
                                            else { $0.regionExclusions.remove(region) }
                                        }
                                    }
                                   ))
                        }
                        Divider()
                        Toggle("只保留指定机场", isOn: Binding(
                            get: { state.profile.providerWhitelistEnabled },
                            set: { on in change { $0.providerWhitelistEnabled = on } }
                        ))
                        editableTokens(state.profile.providerWhitelist, remove: { value in
                            change { $0.providerWhitelist.removeAll { $0 == value } }
                        })
                        HStack {
                            TextField("机场名称关键词，例如 乌拉", text: $provider)
                                .onSubmit(addProvider)
                            Button { addProvider() } label: { Image(systemName: "plus") }
                                .help("添加机场关键词")
                                .disabled(provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("乌拉 + 渔云") {
                                change {
                                    $0.providerWhitelist = ["乌拉", "渔云"]
                                    $0.providerWhitelistEnabled = true
                                }
                            }
                        }
                        if state.profile.providerWhitelistEnabled && state.profile.providerWhitelist.isEmpty {
                            Text("先添加至少一个机场关键词；空列表不会过滤节点。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button("同步关键词过滤") { state.syncFilterToRouter() }
                            .disabled(!state.isConnected || state.isBusy)
                    }
                }

                Card(title: "黑名单", subtitle: "拉黑的节点完全不参与自动换节点；在「节点」页点卡片右上角的按钮就能拉黑（可整批拉黑一个订阅或机场）。") {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.blockedCount == 0 {
                            Text("还没有拉黑任何节点。拉黑后节点会灰掉留在列表里，随时可以在这里解除。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            if !state.profile.blockedKeywords.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("按关键词拉黑（整个订阅 / 机场）")
                                        .font(.callout.weight(.medium))
                                    ForEach(state.profile.blockedKeywords, id: \.self) { word in
                                        HStack {
                                            Text(word).lineLimit(1)
                                            Text("匹配 \(state.nodesMatching(keyword: word).count) 个节点")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            Button { state.unblockKeyword(word) } label: {
                                                Label("解除", systemImage: "arrow.uturn.backward")
                                            }
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                            if !state.profile.blockedNodes.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("按节点名拉黑").font(.callout.weight(.medium))
                                    ForEach(state.profile.blockedNodes, id: \.self) { name in
                                        HStack {
                                            Text(name).lineLimit(1)
                                            Spacer()
                                            Button { state.unblockNode(name) } label: {
                                                Label("解除", systemImage: "arrow.uturn.backward")
                                            }
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                            HStack(spacing: 10) {
                                Button("全部解除", role: .destructive) { state.clearBlocklist() }
                                Button("同步过滤到路由器") { state.syncFilterToRouter() }
                                    .disabled(!state.isConnected || state.isBusy)
                                Spacer(minLength: 0)
                            }
                            Text("设备守护要重新安装一次才会用上新黑名单。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Card(title: "自动换节点", subtitle: "低于阈值时保持当前节点；超过阈值或超时才查找更快的节点。") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("固定当前节点（只有超时才换）", isOn: Binding(
                            get: { state.profile.pinnedNode },
                            set: { state.setPinnedNode($0) }
                        ))
                        .help("打开后当前节点延迟再高也不换；只有它真的超时才自动切到可用节点。")
                        if state.profile.pinnedNode {
                            Text("固定中：下面的阈值暂时不生效，关掉即恢复。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Stepper(value: Binding(
                            get: { state.profile.failoverThreshold },
                            set: { value in change { $0.failoverThreshold = value } }
                        ), in: 0...500, step: 10) {
                            Text(state.profile.failoverThreshold == 0
                                 ? "仅在超时时切换"
                                 : "延迟阈值：\(state.profile.failoverThreshold) ms")
                        }
                        .disabled(state.profile.pinnedNode)
                        Text("设备守护独立运行；修改筛选、阈值或固定开关后，需在“控制”中重新安装。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "域名分流", subtitle: "规则保存在本机；同步会新增或更新，不会删除路由器上的旧规则。") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.profile.domainRules) { rule in
                            HStack {
                                Text("\(rule.ruleType),\(rule.domain),\(rule.proxy)")
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    change { $0.domainRules.removeAll { $0.id == rule.id } }
                                } label: { Image(systemName: "trash") }
                                    .help("删除本地规则")
                            }
                        }
                        HStack {
                            TextField("例如 douyin.com", text: $domain)
                                .onSubmit(addRule)
                            Picker("匹配", selection: $ruleType) {
                                Text("域名后缀").tag("DOMAIN-SUFFIX")
                                Text("域名关键词").tag("DOMAIN-KEYWORD")
                            }
                            .frame(width: 140)
                            Picker("动作", selection: $ruleProxy) {
                                Text("直连").tag("DIRECT")
                                Text("拒绝").tag("REJECT")
                                Text("代理").tag("GLOBAL")
                            }
                            .frame(width: 100)
                            Button { addRule() } label: { Image(systemName: "plus") }
                                .help("添加域名规则")
                                .disabled(cleanDomain.isEmpty)
                        }
                        Button("同步到所有路由器") { state.syncDomainRulesToAllRouters() }
                            .disabled(state.isBusy || state.profile.domainRules.isEmpty || state.devices.isEmpty)
                    }
                }
            }
            .frame(maxWidth: 900)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $addingSubscription) {
            LocalSubscriptionEditor(subscription: nil, existingNames: Set(state.profile.subscriptions.map(\.name))) { sub in
                change { $0.subscriptions.append(sub) }
            }
        }
        .sheet(item: $editingSubscription) { original in
            LocalSubscriptionEditor(
                subscription: original,
                existingNames: Set(state.profile.subscriptions.filter { $0.id != original.id }.map(\.name))
            ) { sub in
                change {
                    if let index = $0.subscriptions.firstIndex(where: { $0.id == sub.id }) {
                        $0.subscriptions[index] = sub
                    }
                }
            }
        }
    }

    private func editableTokens(_ values: [String], remove: @escaping (String) -> Void) -> some View {
        FlowTokens(values: values, remove: remove)
    }

    private func addKeyword() {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        change { if !$0.filterKeywords.contains(value) { $0.filterKeywords.append(value) } }
        keyword = ""
    }

    private func addProvider() {
        let value = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        change { if !$0.providerWhitelist.contains(value) { $0.providerWhitelist.append(value) } }
        provider = ""
    }

    private var cleanDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addRule() {
        let value = cleanDomain
        guard !value.isEmpty, !value.contains(","), !value.contains(" ") else { return }
        change { $0.domainRules.append(LocalDomainRule(domain: value, ruleType: ruleType, proxy: ruleProxy)) }
        domain = ""
    }
}

private struct FlowTokens: View {
    let values: [String]
    let remove: (String) -> Void

    var body: some View {
        if values.isEmpty {
            Text("暂无").foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(values, id: \.self) { value in
                    HStack {
                        Text(value).lineLimit(1)
                        Spacer(minLength: 2)
                        Button { remove(value) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("删除 \(value)")
                    }
                    .padding(7)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

private struct LocalSubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: LocalSubscription?
    let existingNames: Set<String>
    let onSave: (LocalSubscription) -> Void
    @State private var name: String
    @State private var url: String
    @State private var userAgent: String
    @State private var enabled: Bool

    init(subscription: LocalSubscription?, existingNames: Set<String>, onSave: @escaping (LocalSubscription) -> Void) {
        self.subscription = subscription
        self.existingNames = existingNames
        self.onSave = onSave
        _name = State(initialValue: subscription?.name ?? "")
        _url = State(initialValue: subscription?.url ?? "")
        _userAgent = State(initialValue: subscription?.userAgent ?? "clash.meta")
        _enabled = State(initialValue: subscription?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(subscription == nil ? "添加本地订阅" : "编辑本地订阅")
                .font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                TextField("订阅链接", text: $url, axis: .vertical).lineLimit(2...4)
                TextField("User-Agent", text: $userAgent)
                Toggle("启用", isOn: $enabled)
            }
            .formStyle(.grouped)
            if existingNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Text("已存在同名订阅，请使用不同名称。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(LocalSubscription(
                        id: subscription?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        userAgent: userAgent.trimmingCharacters(in: .whitespacesAndNewlines),
                        enabled: enabled
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || existingNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
                          || URLComponents(string: url)?.scheme == nil
                          || URLComponents(string: url)?.host == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
