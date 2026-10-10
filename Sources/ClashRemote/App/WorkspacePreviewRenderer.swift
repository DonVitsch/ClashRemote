#if DEBUG
import AppKit
import SwiftUI

/// Development-only snapshots: sample data, no router connection or saved-profile mutation.
@MainActor
enum WorkspacePreviewRenderer {
    private static let previewDefaultsName = "ClashRemote.Previews.\(UUID().uuidString)"
    private static let previewPreferences = AppPreferences(defaults: UserDefaults(suiteName: previewDefaultsName)!)

    static func render(to directory: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { UserDefaults.standard.removePersistentDomain(forName: previewDefaultsName) }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let state = sampleState()
            let pages: [(WorkspaceSection, String)] = [
                (.nodes, "nodes"), (.subscriptions, "subscriptions"), (.rules, "rules"),
                (.device, "device-control"), (.profile, "preferences"), (.settings, "settings-general")
            ]
            for (section, name) in pages {
                snapshot(RootView(initialSection: section, previewTheme: .mintCat).environment(state), name: name, directory: directory)
            }
            for theme in AppTheme.allCases {
                snapshot(RootView(previewTheme: theme).environment(state), name: "overview-\(theme.rawValue)", directory: directory, dark: theme.isDark)
            }
            for theme in [AppTheme.aqua, .mintCat, .graphite] {
                snapshot(RootView(previewTheme: theme).environment(state), name: "overview-\(theme.rawValue)-compact", directory: directory, size: NSSize(width: 980, height: 640), dark: theme.isDark)
            }
            snapshot(RootView(initialSection: .settings, previewTheme: .mintCat, previewSettingsCategory: .themes).environment(state), name: "themes", directory: directory)
            snapshot(RootView(initialSection: .settings, previewTheme: .graphite, previewSettingsCategory: .themes).environment(state), name: "themes-dark", directory: directory, dark: true)
            snapshot(RootView(initialSection: .settings, previewTheme: .mintCat, previewSettingsCategory: .display).environment(state), name: "settings-display", directory: directory)
            snapshot(RootView(initialSection: .settings, previewTheme: .mintCat).environment(state), name: "settings-compact", directory: directory, size: NSSize(width: 980, height: 640))
            snapshot(RootView(initialSection: .nodes, previewTheme: .graphite).environment(state), name: "nodes-dark", directory: directory, dark: true)
            snapshot(RootView(initialSection: .nodes, previewTheme: .mintCat).environment(state), name: "nodes-compact", directory: directory, size: NSSize(width: 980, height: 640))
            state.notice = .success("已连接家庭主路由")
            state.deviceFailover.running = false
            snapshot(RootView(initialSection: .nodes, previewTheme: .mintCat).environment(state), name: "nodes-user-size", directory: directory, size: NSSize(width: 1100, height: 872))
            state.notice = nil
            state.deviceFailover.running = true
            snapshot(DeviceEditor(device: nil).environment(state), name: "device-editor", directory: directory, size: NSSize(width: 540, height: 640))
            snapshot(SubscriptionEditor(subscription: nil).environment(state), name: "subscription-editor", directory: directory, size: NSSize(width: 600, height: 540))
            previewPreferences.textSize = .extraLarge
            previewPreferences.density = .comfortable
            snapshot(RootView(initialSection: .settings, previewTheme: .mintCat, previewSettingsCategory: .display).environment(state), name: "settings-display-large", directory: directory, size: NSSize(width: 980, height: 740))
            snapshot(RootView(initialSection: .settings, previewTheme: .graphite).environment(state), name: "settings-general-large", directory: directory, size: NSSize(width: 980, height: 740), dark: true)
            snapshot(RootView(initialSection: .nodes, previewTheme: .mintCat).environment(state), name: "nodes-large", directory: directory, size: NSSize(width: 980, height: 740))
            snapshot(RootView(previewTheme: .mintCat).environment(state), name: "overview-large", directory: directory, size: NSSize(width: 980, height: 740))
            previewPreferences.showDeviceAddress = false
            previewPreferences.showNodeProtocol = false
            snapshot(RootView(initialSection: .nodes, previewTheme: .graphite).environment(state), name: "nodes-details-hidden", directory: directory, size: NSSize(width: 1100, height: 840), dark: true)
            snapshot(AppearanceSettingsWindow(), name: "settings-window-large", directory: directory, size: NSSize(width: 870, height: 720))
            previewPreferences.reset()
            state.snapshot.status.ruleMode = .direct
            snapshot(RootView(previewTheme: .graphite).environment(state), name: "overview-direct", directory: directory, dark: true)
            state.snapshot.status.running = false
            state.trafficHistory = []
            snapshot(RootView(previewTheme: .mintCat).environment(state), name: "overview-stopped", directory: directory)
            state.snapshot = DashboardSnapshot()
            state.trafficHistory = []
            state.notice = nil
            state.connectedDeviceID = nil
            state.lastError = nil
            snapshot(RootView(previewTheme: .aqua).environment(state), name: "overview-offline", directory: directory)
            snapshot(DashboardView(section: .constant(.subscriptions), onAddDevice: {}).environment(state), name: "subscriptions-empty", directory: directory, size: NSSize(width: 900, height: 700))
            print("Rendered workspace previews to \(directory)")
        } catch {
            print("Preview rendering failed: \(error)")
        }
    }

    private static func snapshot<V: View>(_ view: V, name: String, directory: String, size: NSSize = NSSize(width: 1240, height: 840), dark: Bool = false) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(previewPreferences)
            .environment(\.appTextScale, previewPreferences.textSize.scale)
            .environment(\.colorScheme, dark ? .dark : .light)
            .font(.system(size: 13 * previewPreferences.textSize.scale)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.appearance = window.appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        window.contentView = nil
    }

    private static func sampleState() -> AppState {
        let state = AppState(preferences: previewPreferences)
        let device = RouterDevice(name: "Rax3000M", host: "192.168.1.1", password: "", plugin: .openclash)
        state.devices = [device, RouterDevice(name: "随身 Wi-Fi", host: "192.168.8.1", port: 2333, password: "", plugin: .maomao)]
        state.selectedID = device.id
        state.connectedDeviceID = device.id
        state.notice = nil
        state.lastError = nil
        state.profile = .default
        state.profile.regionExclusions = []
        state.profile.blockedNodes = ["日本 · Tokyo 02", "美国 · Los Angeles 02"]
        state.snapshot.status.running = true
        state.snapshot.status.model = "OpenWrt Router"
        state.snapshot.status.coreType = "Mihomo"
        state.snapshot.status.configPath = "/etc/openclash/config/home.yaml"
        state.snapshot.status.chinaIPRoute = true
        state.snapshot.status.metaSniffer = true
        state.snapshot.traffic = TrafficSnapshot(up: "246 KB/S", down: "8.42 MB/S", upTotal: "2.14 GB", downTotal: "18.6 GB", connections: 128, cpu: "4%", mem: "64.2 MB")
        let now = Date()
        state.trafficHistory = (0..<100).map { index in
            let progress = Double(index)
            return TrafficSample(date: now.addingTimeInterval(Double(index - 99) * 3),
                                 download: (5.7 + 1.6 * sin(progress / 10) + 0.7 * sin(progress / 3)) * 1_000_000,
                                 upload: (0.24 + 0.09 * sin(progress / 8)) * 1_000_000)
        }
        let names = ["新加坡 · Singapore 01", "新加坡 · Singapore 02", "新加坡 · Singapore 03", "香港 · Hong Kong 01", "香港 · Hong Kong 02", "香港 · Hong Kong 03", "日本 · Tokyo 01", "日本 · Tokyo 02", "美国 · Los Angeles 01", "台湾 · Taipei 01", "韩国 · Seoul 01", "英国 · London 01",
                     "香港 · Hong Kong 04", "香港 · Hong Kong 05 · 专线高速", "香港 · Hong Kong 06", "香港 · Hong Kong 07", "香港 · Hong Kong 08", "香港 · Hong Kong 09", "香港 · Hong Kong 10",
                     "新加坡 · Singapore 04", "新加坡 · Singapore 05", "新加坡 · Singapore 06", "新加坡 · Singapore 07", "新加坡 · Singapore 08", "日本 · Tokyo 03", "美国 · Los Angeles 02", "台湾 · Taipei 02", "韩国 · Seoul 02", "英国 · London 02"]
        let delays = [42, 68, 96, 25, 31, 88, 75, -1, 186, 40, 108, 221, 35, 29, 43, 54, 37, 65, 51, 78, 86, 72, 91, -1, 79, -1, 46, 113, 227]
        let nodes = zip(names, delays).map { ProxyItem(name: $0.0, type: "Shadowsocks", lastDelay: $0.1, ownerGroup: "节点选择") }
        state.snapshot.groups = [
            ProxyGroup(name: "GLOBAL", type: "Selector", now: "节点选择", nodes: [ProxyItem(name: "节点选择", type: "Selector", lastDelay: nil)], selectable: true),
            ProxyGroup(name: "节点选择", type: "Selector", now: names[0], nodes: nodes, selectable: true)
        ]
        state.snapshot.subscriptions = [
            Subscription(section: "provider_a", name: "主力机场", address: "https://example.com/subscription/main", enabled: true, userAgent: "clash.meta"),
            Subscription(section: "provider_b", name: "备用线路", address: "https://example.com/subscription/backup", enabled: true, userAgent: "clash.meta")
        ]
        state.snapshot.configs = [ConfigFile(name: "home.yaml", path: "/etc/openclash/config/home.yaml", size: 16432, current: true), ConfigFile(name: "backup.yaml", path: "/etc/openclash/config/backup.yaml", size: 14204, current: false)]
        state.snapshot.rules = [
            ClashRule(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
            ClashRule(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "节点选择"),
            ClashRule(type: "DOMAIN-KEYWORD", payload: "ads", proxy: "REJECT"),
            ClashRule(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
            ClashRule(type: "MATCH", payload: "", proxy: "节点选择")
        ]
        state.deviceFailover = DeviceFailoverStatus(installed: true, hooked: true, running: true, enabled: true, interval: 15, detail: "ok 新加坡 · Singapore 01 42ms", log: "", updatedAt: Date())
        return state
    }
}
#endif
