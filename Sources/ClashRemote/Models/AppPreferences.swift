import Foundation
import Observation

enum AppTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "较小"
        case .standard: "标准"
        case .large: "较大"
        case .extraLarge: "特大"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }
}

enum InterfaceDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable

    var id: String { rawValue }
    var title: String { self == .compact ? "紧凑" : "舒适" }
}

enum StartupPage: String, CaseIterable, Identifiable, Sendable {
    case overview
    case nodes
    case lastUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "总览"
        case .nodes: "节点"
        case .lastUsed: "上次使用的页面"
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case fast = 2
    case standard = 3
    case relaxed = 5
    case economy = 10

    var id: Int { rawValue }
    var seconds: Int { rawValue }
    var title: String { "每 \(seconds) 秒" }
}

/// Preferences shared by the main window and the settings window.
/// Device credentials, profiles and the selected theme are stored separately.
@Observable
@MainActor
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var textSize: AppTextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) }
    }

    var density: InterfaceDensity {
        didSet { defaults.set(density.rawValue, forKey: Key.density) }
    }

    var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }

    var startupPage: StartupPage {
        didSet { defaults.set(startupPage.rawValue, forKey: Key.startupPage) }
    }

    var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval) }
    }

    var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) }
    }

    var rememberWindowFrame: Bool {
        didSet { defaults.set(rememberWindowFrame, forKey: Key.rememberWindowFrame) }
    }

    var showDeviceAddress: Bool {
        didSet { defaults.set(showDeviceAddress, forKey: Key.showDeviceAddress) }
    }

    var showNodeProtocol: Bool {
        didSet { defaults.set(showNodeProtocol, forKey: Key.showNodeProtocol) }
    }

    var lastSection: String {
        didSet { defaults.set(lastSection, forKey: Key.lastSection) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textSize = defaults.string(forKey: Key.textSize).flatMap(AppTextSize.init(rawValue:)) ?? .standard
        density = defaults.string(forKey: Key.density).flatMap(InterfaceDensity.init(rawValue:)) ?? .compact
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        startupPage = defaults.string(forKey: Key.startupPage).flatMap(StartupPage.init(rawValue:)) ?? .overview
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: Key.refreshInterval)) ?? .standard
        alwaysOnTop = defaults.object(forKey: Key.alwaysOnTop) as? Bool ?? false
        rememberWindowFrame = defaults.object(forKey: Key.rememberWindowFrame) as? Bool ?? true
        showDeviceAddress = defaults.object(forKey: Key.showDeviceAddress) as? Bool ?? true
        showNodeProtocol = defaults.object(forKey: Key.showNodeProtocol) as? Bool ?? true
        lastSection = defaults.string(forKey: Key.lastSection) ?? "总览"
    }

    /// Restores general and display preferences while keeping navigation history.
    func reset() {
        textSize = .standard
        density = .compact
        autoConnect = true
        startupPage = .overview
        refreshInterval = .standard
        alwaysOnTop = false
        rememberWindowFrame = true
        showDeviceAddress = true
        showNodeProtocol = true
    }

    private enum Key {
        static let textSize = "general.textSize"
        static let density = "general.interfaceDensity"
        static let autoConnect = "general.autoConnect"
        static let startupPage = "general.startupPage"
        static let refreshInterval = "general.refreshInterval"
        static let alwaysOnTop = "general.alwaysOnTop"
        static let rememberWindowFrame = "general.rememberWindowFrame"
        static let showDeviceAddress = "general.showDeviceAddress"
        static let showNodeProtocol = "general.showNodeProtocol"
        static let lastSection = "general.lastSection"
    }
}
