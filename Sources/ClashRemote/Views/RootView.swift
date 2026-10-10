import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case nodes = "节点"
    case subscriptions = "订阅"
    case rules = "规则"
    case device = "设备控制"
    case profile = "本地配置"
    case settings = "设置"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .subscriptions: "arrow.down.doc"
        case .rules: "arrow.triangle.branch"
        case .device: "wifi.router.fill"
        case .profile: "slider.horizontal.3"
        case .settings: "paintpalette"
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(AppPreferences.self) private var preferences
    @AppStorage(AppTheme.storageKey) private var storedTheme: AppTheme = .mintCat
    @State private var addingDevice = false
    @State private var editingDevice: RouterDevice?
    @State private var section: WorkspaceSection = .overview
    @State private var didApplyStartupPreferences = false
    private let previewTheme: AppTheme?
    private let previewSettingsCategory: SettingsCategory

    init(initialSection: WorkspaceSection = .overview, previewTheme: AppTheme? = nil, previewSettingsCategory: SettingsCategory = .general) {
        _section = State(initialValue: initialSection)
        self.previewTheme = previewTheme
        self.previewSettingsCategory = previewSettingsCategory
    }

    private var selectedTheme: AppTheme { previewTheme ?? storedTheme }

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(section: $section, addingDevice: $addingDevice, editingDevice: $editingDevice)
                .navigationSplitViewColumnWidth(min: 236, ideal: 264 * min(preferences.textSize.scale, 1.12), max: 320)
        } detail: {
            DashboardView(section: $section, onAddDevice: { addingDevice = true }, onEditDevice: { editingDevice = state.selectedDevice }, initialSettingsCategory: previewSettingsCategory)
                .background(selectedTheme.colors.canvas.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .tint(selectedTheme.colors.blue)
        .foregroundStyle(selectedTheme.colors.ink)
        .onAppear {
            guard previewTheme == nil, !didApplyStartupPreferences else { return }
            didApplyStartupPreferences = true
            switch preferences.startupPage {
            case .overview: section = .overview
            case .nodes: section = .nodes
            case .lastUsed: section = WorkspaceSection(rawValue: preferences.lastSection) ?? .overview
            }
            preferences.lastSection = section.rawValue
            if preferences.autoConnect && state.connectedDeviceID == nil && !state.isConnecting {
                Task { await state.connect() }
            }
        }
        .onChange(of: section) { _, value in
            guard previewTheme == nil else { return }
            preferences.lastSection = value.rawValue
        }
        .onChange(of: preferences.refreshInterval) { _, _ in
            guard previewTheme == nil else { return }
            state.updatePollingFrequency()
        }
        .sheet(isPresented: $addingDevice) {
            DeviceEditor(device: nil)
        }
        .sheet(item: $editingDevice) { device in
            DeviceEditor(device: device)
        }
        .environment(\.appTheme, selectedTheme)
        .environment(\.appTextScale, preferences.textSize.scale)
        .font(.system(size: 13 * preferences.textSize.scale))
        .preferredColorScheme(selectedTheme.colorScheme)
        .background {
            if previewTheme == nil {
                WindowPreferences(alwaysOnTop: preferences.alwaysOnTop, rememberFrame: preferences.rememberWindowFrame)
            }
        }
    }
}

private struct WorkspaceSidebar: View {
    @Environment(AppState.self) private var state
    @Environment(AppPreferences.self) private var preferences
    @ThemePalette private var palette
    @Binding var section: WorkspaceSection
    @Binding var addingDevice: Bool
    @Binding var editingDevice: RouterDevice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 11) {
                    ClashAppMark().frame(width: 38, height: 38)
                    Text("Clash Remote").foregroundStyle(palette.ink)
                        .appFont(.system(size: 14, weight: .bold, design: .rounded))
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WorkspaceSection.allCases) { item in
                        Button { section = item } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.rawValue)
                                Spacer()
                                if item == .nodes, state.isConnected {
                                    Text("\(NodeBoardLayout.visibleNodeCount(from: state.snapshot.groups, mode: state.snapshot.status.ruleMode, profile: state.profile))")
                                        .appFont(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .appFont(.system(size: 13, weight: section == item ? .semibold : .medium))
                            .foregroundStyle(section == item ? palette.ink : palette.muted)
                            .padding(.horizontal, 11).padding(.vertical, preferences.density == .comfortable ? 12 : 9)
                            .background(section == item ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .leading) {
                                if section == item { Capsule().fill(palette.cyan).frame(width: 3).padding(.vertical, 7) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        sidebarCaption("路由器")
                        Spacer()
                        Button { addingDevice = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).foregroundStyle(palette.blue).help("添加路由器")
                    }
                    if state.devices.isEmpty {
                        Button { addingDevice = true } label: {
                            Label("添加第一台设备", systemImage: "plus.circle")
                                .appFont(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    } else {
                        ForEach(state.devices) { device in
                            Button { state.select(device.id) } label: { routerCard(device) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("编辑设备") { editingDevice = device }
                                    Button("重新连接") { state.select(device.id) }
                                    Divider()
                                    Button("删除设备", role: .destructive) { state.deleteDevice(device.id) }
                                }
                        }
                    }
                }

                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Circle().fill(state.isConnecting ? palette.amber : (state.isConnected ? palette.green : palette.muted)).frame(width: 7, height: 7)
                    Text(state.isConnecting ? "正在连接设备" : (state.isConnected ? "设备已连接" : "等待设备连接"))
                        .appFont(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.bottom, 12)
            }
            .padding(.horizontal, 15)
        }
        .background(palette.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingDevice = true } label: { Label("添加设备", systemImage: "plus") }
            }
        }
    }

    private func sidebarCaption(_ text: String) -> some View {
        Text(text).appFont(.system(size: 10, weight: .semibold)).foregroundStyle(palette.muted).padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func routerCard(_ device: RouterDevice) -> some View {
        let selected = state.selectedID == device.id
        let online = state.connectedDeviceID == device.id && state.lastError == nil
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(selected ? palette.cyan.opacity(0.14) : palette.surface.opacity(0.72))
                Image(systemName: device.plugin == .maomao ? "antenna.radiowaves.left.and.right" : "wifi.router.fill")
                    .appFont(.system(size: 15, weight: .semibold)).foregroundStyle(selected ? palette.blue : palette.muted)
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).appFont(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                Text(preferences.showDeviceAddress ? "\(device.plugin.title) · \(device.displayAddress)" : device.plugin.title)
                    .appFont(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Circle().fill(online ? palette.green : (selected && state.isConnecting ? palette.amber : palette.muted.opacity(0.5))).frame(width: 7, height: 7)
        }
        .padding(9)
        .background(selected ? palette.surface : palette.surface.opacity(0.48), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? palette.cyan.opacity(0.22) : .clear, lineWidth: 1))
    }
}

struct NoticeBar: View {
    let notice: AppNotice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(notice.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .appFont(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var icon: String {
        switch notice {
        case .info: "ellipsis.circle"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice {
        case .info: .secondary
        case .success: .green
        case .error: .red
        }
    }
}

struct DeviceEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @ThemePalette private var palette

    let device: RouterDevice?

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var useHTTPS: Bool
    @State private var plugin: ClashPlugin

    init(device: RouterDevice?) {
        self.device = device
        _name = State(initialValue: device?.name ?? "")
        _host = State(initialValue: device?.host ?? "")
        _port = State(initialValue: String(device?.port ?? ClashPlugin.openclash.defaultHTTPPort))
        _username = State(initialValue: device?.username ?? "root")
        _password = State(initialValue: device?.password ?? "")
        _useHTTPS = State(initialValue: device?.useHTTPS ?? false)
        _plugin = State(initialValue: device?.plugin ?? .openclash)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceBanner(symbol: "wifi.router.fill", title: device == nil ? "连接一台路由器" : "编辑路由器", detail: "保存连接信息，随时切换和遥控设备。", color: palette.cyan)
            VStack(alignment: .leading, spacing: 17) {
                EditorField(title: "设备名称", symbol: "tag") { TextField("例如 家庭主路由", text: $name) }
                HStack(alignment: .top, spacing: 13) {
                    EditorField(title: "设备地址", symbol: "network") { TextField("192.168.1.1", text: $host).textContentType(.URL) }
                    EditorField(title: "端口", symbol: "number") { TextField("80", text: $port) }.frame(width: 100)
                }
                HStack(alignment: .top, spacing: 13) {
                    EditorField(title: "用户名", symbol: "person") { TextField("root", text: $username) }
                    EditorField(title: "密码", symbol: "key") { SecureField("设备登录密码", text: $password) }
                }
                Divider()
                HStack {
                    Picker("设备插件", selection: $plugin) {
                        ForEach(ClashPlugin.allCases) { item in Text(item.title).tag(item) }
                    }
                    .onChange(of: plugin) { _, newValue in
                        if device == nil {
                            port = String(newValue.defaultHTTPPort)
                            if newValue == .maomao, username == "root" { username = "admin" }
                        }
                    }
                    Spacer()
                    Toggle("HTTPS", isOn: $useHTTPS).toggleStyle(.switch).controlSize(.small)
                }.appFont(.callout)
            }
            .padding(20).panelSurface()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存设备") { save() }
                    .buttonStyle(ActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(palette.canvas)
        .tint(palette.blue)
        .foregroundStyle(palette.ink)
        .buttonStyle(ActionButtonStyle(filled: false))
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = RouterDevice(
            id: device?.id ?? UUID(),
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            host: trimmedHost,
            port: Int(port) ?? 80,
            useHTTPS: useHTTPS,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            plugin: plugin
        )
        if device == nil {
            state.addDevice(item)
        } else {
            state.updateDevice(item)
        }
        dismiss()
    }
}
