#if DEBUG
import AppKit
import SwiftUI

/// Development-only snapshots: sample data, no router connection or saved-profile mutation.
@MainActor
enum WorkspacePreviewRenderer {
    static func renderIcon(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for dimension in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let side = CGFloat(dimension * scale)
                let renderer = ImageRenderer(content: ClashAppMark().padding(12).frame(width: 128, height: 128))
                renderer.scale = side / 128
                guard let cgImage = renderer.cgImage else { continue }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let suffix = scale == 2 ? "@2x" : ""
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("icon_\(dimension)x\(dimension)\(suffix).png"))
                }
            }
        }
    }

    static func render(to directory: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let state = sampleState()
            for section in WorkspaceSection.allCases {
                snapshot(RootView(initialSection: section).environment(state), name: section.eyebrow.lowercased().replacingOccurrences(of: " ", with: "-"), directory: directory)
            }
            snapshot(RootView().environment(state), name: "overview-dark", directory: directory, dark: true)
            snapshot(RootView(initialSection: .nodes).environment(state), name: "nodes-compact", directory: directory, size: NSSize(width: 980, height: 640))
            snapshot(RootView().environment(state), name: "overview-compact", directory: directory, size: NSSize(width: 980, height: 640))
            snapshot(DeviceEditor(device: nil).environment(state), name: "device-editor", directory: directory, size: NSSize(width: 540, height: 640))
            snapshot(SubscriptionEditor(subscription: nil).environment(state), name: "subscription-editor", directory: directory, size: NSSize(width: 600, height: 540))
            state.snapshot = DashboardSnapshot()
            state.notice = nil
            state.connectedDeviceID = nil
            state.lastError = "Preview: offline"
            snapshot(DashboardView(section: .constant(.subscriptions), onAddDevice: {}).environment(state), name: "subscriptions-empty", directory: directory, size: NSSize(width: 900, height: 700))
            print("Rendered workspace previews to \(directory)")
        } catch {
            print("Preview rendering failed: \(error)")
        }
    }

    private static func snapshot<V: View>(_ view: V, name: String, directory: String, size: NSSize = NSSize(width: 1240, height: 840), dark: Bool = false) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
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
        let state = AppState()
        let device = RouterDevice(name: "家庭主路由", host: "192.168.1.1", password: "", plugin: .openclash)
        state.devices = [device, RouterDevice(name: "随身 Wi-Fi", host: "192.168.8.1", port: 2333, password: "", plugin: .maomao)]
        state.selectedID = device.id
        state.connectedDeviceID = device.id
        state.notice = nil
        state.lastError = nil
        state.profile = .default
        state.profile.regionExclusions = []
        state.profile.blockedNodes = ["日本 · Tokyo 02"]
        state.snapshot.status.running = true
        state.snapshot.status.model = "OpenWrt Router"
        state.snapshot.status.coreType = "Mihomo"
        state.snapshot.status.configPath = "/etc/openclash/config/home.yaml"
        state.snapshot.status.chinaIPRoute = true
        state.snapshot.status.metaSniffer = true
        state.snapshot.traffic = TrafficSnapshot(up: "246 KB/S", down: "8.42 MB/S", upTotal: "2.14 GB", downTotal: "18.6 GB", connections: 128, cpu: "4%", mem: "64.2 MB")
        let names = ["新加坡 · Singapore 01", "新加坡 · Singapore 02", "新加坡 · Singapore 03", "香港 · Hong Kong 01", "香港 · Hong Kong 02", "香港 · Hong Kong 03", "日本 · Tokyo 01", "日本 · Tokyo 02", "美国 · Los Angeles 01", "台湾 · Taipei 01", "韩国 · Seoul 01", "英国 · London 01"]
        let delays = [42, 68, 96, 25, 31, 88, 75, -1, 186, 40, 108, 221]
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
