import SwiftUI

enum ThemeLayout: Equatable, Sendable {
    case dashboard
    case cat
    case console
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case aqua
    case mintCat
    case graphite
    case lavender
    case sand

    static let storageKey = "appearance.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aqua: "清透蓝"
        case .mintCat: "薄荷猫"
        case .graphite: "石墨控制台"
        case .lavender: "雾紫"
        case .sand: "暖杏"
        }
    }

    var detail: String {
        switch self {
        case .aqua: "清晰的浅色仪表盘，蓝色点亮关键操作。"
        case .mintCat: "薄荷绿与猫图案，让设备总览更有温度。"
        case .graphite: "深色监控视图，以青色呈现连接和流量。"
        case .lavender: "柔和的雾紫配色，搭配简洁的仪表盘。"
        case .sand: "暖杏色与猫图案，营造轻松的桌面氛围。"
        }
    }

    var colors: ThemeColors { ThemeColors(theme: self) }

    var layout: ThemeLayout {
        switch self {
        case .aqua, .lavender: .dashboard
        case .mintCat, .sand: .cat
        case .graphite: .console
        }
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var isDark: Bool { self == .graphite }
    var usesCatArtwork: Bool { layout == .cat }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppTheme = .mintCat
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}
