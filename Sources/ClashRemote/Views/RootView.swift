import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var addingDevice = false
    @State private var editingDevice: RouterDevice?

    var body: some View {
        NavigationSplitView {
            DeviceSidebar(
                addingDevice: $addingDevice,
                editingDevice: $editingDevice
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            DashboardView()
        }
        .onAppear {
            if state.connectedDeviceID == nil {
                Task { await state.connect() }
            }
        }
        .sheet(isPresented: $addingDevice) {
            DeviceEditor(device: nil)
        }
        .sheet(item: $editingDevice) { device in
            DeviceEditor(device: device)
        }
    }
}

struct DeviceSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var addingDevice: Bool
    @Binding var editingDevice: RouterDevice?

    var body: some View {
        List(selection: Binding(
            get: { state.selectedID },
            set: { if let id = $0 { state.select(id) } }
        )) {
            Section("路由器") {
                ForEach(state.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                        .contextMenu {
                            Button("编辑") { editingDevice = device }
                            Button("重新连接") { Task { await state.connect() } }
                            Divider()
                            Button("删除", role: .destructive) {
                                state.deleteDevice(device.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Clash Remote")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingDevice = true
                } label: {
                    Label("添加设备", systemImage: "plus")
                }
            }
        }
    }
}

struct DeviceRow: View {
    @Environment(AppState.self) private var state
    let device: RouterDevice

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                Text("\(device.plugin.title) · \(device.displayAddress)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        if state.connectedDeviceID == device.id && state.lastError == nil {
            return .green
        }
        if state.selectedID == device.id && state.isConnecting {
            return .orange
        }
        return .secondary.opacity(0.35)
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
        .font(.caption)
        .foregroundStyle(color)
        .padding(8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            Text(device == nil ? "添加路由器" : "编辑路由器")
                .font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                TextField("地址", text: $host)
                    .textContentType(.URL)
                TextField("端口", text: $port)
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
                Toggle("HTTPS", isOn: $useHTTPS)
                Picker("插件", selection: $plugin) {
                    ForEach(ClashPlugin.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .onChange(of: plugin) { _, newValue in
                    if device == nil {
                        port = String(newValue.defaultHTTPPort)
                        if newValue == .maomao, username == "root" {
                            username = "admin"
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
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
