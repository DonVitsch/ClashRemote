import SwiftUI

struct AppSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @ThemePalette private var palette
    @State private var category: SettingsCategory = .general
    @State private var didRestoreDefaults = false

    init(initialCategory: SettingsCategory = .general) {
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryPicker
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch category {
                    case .general: generalSettings
                    case .display: displaySettings
                    case .themes: ThemeSettingsView()
                    }

                    restoreDefaults
                }
                .frame(maxWidth: 1_040, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(palette.ink)
        .background(palette.canvas)
        .tint(palette.blue)
    }

    private var categoryPicker: some View {
        HStack(spacing: 6) {
            ForEach(SettingsCategory.allCases) { item in
                Button {
                    category = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .appFont(.system(size: 13, weight: category == item ? .semibold : .medium))
                        .foregroundStyle(category == item ? palette.blue : palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(category == item ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(category == item ? palette.border : .clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
        }
        .padding(5)
        .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
    }

    private var generalSettings: some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "启动与连接", symbol: "power") {
                SettingsRow(title: "启动时自动连接", detail: "打开软件后，连接上次使用的路由器。") {
                    Toggle("启动时自动连接", isOn: $preferences.autoConnect)
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: "启动页面", detail: "选择每次打开软件时显示的页面。") {
                    Picker("启动页面", selection: $preferences.startupPage) {
                        ForEach(StartupPage.allCases, id: \.self) { page in
                            Text(page.title).tag(page)
                        }
                    }
                    .labelsHidden().frame(width: 190)
                }
            }

            SettingsGroup(title: "数据刷新", symbol: "arrow.triangle.2.circlepath") {
                SettingsRow(title: "刷新间隔", detail: "更新流量、连接数和设备状态。") {
                    Picker("数据刷新间隔", selection: $preferences.refreshInterval) {
                        ForEach(RefreshInterval.allCases, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden().frame(width: 190)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").appFont(.system(size: 12))
                    Text("仅影响页面数据刷新；自动切换节点的检测间隔仍在节点页面设置。")
                        .appFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(palette.muted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 9))
            }

            SettingsGroup(title: "窗口", symbol: "macwindow") {
                SettingsRow(title: "窗口置顶", detail: "让软件保持在其他普通窗口上方。") {
                    Toggle("窗口置顶", isOn: $preferences.alwaysOnTop)
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: "记住窗口大小与位置", detail: "下次打开时恢复上次的窗口布局。") {
                    Toggle("记住窗口大小与位置", isOn: $preferences.rememberWindowFrame)
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var displaySettings: some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "文字大小", symbol: "textformat.size") {
                Text("调整整个软件的文字大小，选择后立即生效。")
                    .appFont(.callout).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ForEach(AppTextSize.allCases, id: \.self) { size in
                        textSizeChoice(size)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("文字预览").appFont(.caption).foregroundStyle(palette.muted)
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.router.fill")
                            .appFont(.system(size: 22, weight: .medium))
                            .foregroundStyle(palette.blue)
                        Text("路由器已连接")
                            .appFont(.system(size: 18, weight: .semibold, design: .rounded))
                    }
                    Text("查看当前线路、网络流量与设备状态。")
                        .appFont(.body).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Clash Remote · 192.168.10.1 · 128 ms")
                        .appFont(.caption).foregroundStyle(palette.muted)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }

            SettingsGroup(title: "界面密度", symbol: "rectangle.grid.1x2") {
                Text("调整列表和节点卡片的间距。")
                    .appFont(.callout).foregroundStyle(palette.muted)
                HStack(spacing: 10) {
                    ForEach(InterfaceDensity.allCases, id: \.self) { density in
                        densityChoice(density)
                    }
                }
            }

            SettingsGroup(title: "信息显示", symbol: "eye") {
                SettingsRow(title: "显示设备地址", detail: "在侧栏路由器名称下方显示连接地址。") {
                    Toggle("显示设备地址", isOn: $preferences.showDeviceAddress)
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: "显示节点协议", detail: "在节点卡片中显示 AnyTLS、Hysteria2 等协议名称。") {
                    Toggle("显示节点协议", isOn: $preferences.showNodeProtocol)
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private func textSizeChoice(_ size: AppTextSize) -> some View {
        let selected = preferences.textSize == size
        return Button {
            preferences.textSize = size
        } label: {
            VStack(spacing: 10) {
                Text("字").appFont(.system(size: 20, weight: .medium, design: .rounded))
                    .environment(\.appTextScale, size.scale)
                    .frame(height: 32)
                HStack(spacing: 4) {
                    Text(size.title).appFont(.system(size: 12, weight: .medium))
                    if selected {
                        Image(systemName: "checkmark.circle.fill").appFont(.system(size: 11))
                    }
                }
            }
            .foregroundStyle(selected ? palette.blue : palette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(selected ? palette.blue.opacity(0.08) : palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? palette.blue : palette.border.opacity(0.6), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(size.title)文字")
        .accessibilityValue(selected ? "已选择" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func densityChoice(_ density: InterfaceDensity) -> some View {
        let selected = preferences.density == density
        let compact = density == .compact
        return Button {
            preferences.density = density
        } label: {
            HStack(spacing: 14) {
                VStack(spacing: compact ? 3 : 6) {
                    ForEach(0..<3) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(selected ? palette.blue.opacity(0.65) : palette.muted.opacity(0.5))
                            .frame(width: 31, height: compact ? 5 : 7)
                    }
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(density.title).appFont(.system(size: 13, weight: .semibold))
                    Text(compact ? "一屏显示更多内容" : "增加留白，方便阅读")
                        .appFont(.caption).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .appFont(.system(size: 16)).foregroundStyle(selected ? palette.blue : palette.border)
            }
            .foregroundStyle(selected ? palette.blue : palette.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.blue.opacity(0.08) : palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? palette.blue : palette.border.opacity(0.6), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(density.title)密度")
        .accessibilityValue(selected ? "已选择" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var restoreDefaults: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if didRestoreDefaults {
                    Label("已恢复默认设置", systemImage: "checkmark.circle.fill")
                        .appFont(.system(size: 12, weight: .medium)).foregroundStyle(palette.green)
                } else {
                    Text("恢复常规设置").appFont(.system(size: 12, weight: .medium))
                }
                Text("恢复常规与显示选项，不改变主题或路由器配置。")
                    .appFont(.caption).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("恢复默认") {
                preferences.reset()
                didRestoreDefaults = true
            }
            .buttonStyle(ActionButtonStyle(filled: false))
        }
        .padding(.horizontal, 4)
        .padding(.top, 3)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, display, themes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "常规"
        case .display: return "显示"
        case .themes: return "主题"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .display: return "textformat.size"
        case .themes: return "paintpalette"
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    @ThemePalette private var palette
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .appFont(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.blue)
                    .frame(width: 30, height: 30)
                    .background(palette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                Text(title).appFont(.system(size: 15, weight: .semibold, design: .rounded))
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(radius: 16)
    }
}

private struct SettingsRow<Content: View>: View {
    @ThemePalette private var palette
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).appFont(.system(size: 13, weight: .medium))
                Text(detail).appFont(.caption).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content.appFont(.callout)
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsDivider: View {
    @ThemePalette private var palette
    var body: some View {
        Rectangle().fill(palette.border.opacity(0.7)).frame(height: 1)
    }
}
