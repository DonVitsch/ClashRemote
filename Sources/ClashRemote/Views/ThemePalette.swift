import SwiftUI

/// A complete set of semantic colors for a selected application theme.
struct ThemeColors {
    let canvas: Color
    let sidebar: Color
    let surface: Color
    let surfaceMuted: Color
    let ink: Color
    let border: Color
    let blue: Color
    let cyan: Color
    let green: Color
    let amber: Color
    let muted: Color
    let onAccent: Color
    let isDark: Bool

    init(theme: AppTheme) {
        let values: (canvas: UInt32, sidebar: UInt32, surface: UInt32, surfaceMuted: UInt32,
                     ink: UInt32, border: UInt32, accent: UInt32, cyan: UInt32,
                     green: UInt32, amber: UInt32, muted: UInt32)
        switch theme {
        case .aqua:
            values = (0xF2F6FA, 0xE8EFF7, 0xFFFFFF, 0xF4F8FC,
                      0x172D48, 0xDCE6F0, 0x286BCB, 0x23AAB6,
                      0x238A69, 0xB67A26, 0x788BA1)
        case .mintCat:
            values = (0xF1F6F1, 0xE7F0E9, 0xFFFEFA, 0xF4F7F0,
                      0x1B3A34, 0xDCE8DD, 0x267F68, 0x30A08A,
                      0x288561, 0xAD762A, 0x7B9086)
        case .graphite:
            values = (0x101820, 0x151F2A, 0x1C2935, 0x24333F,
                      0xEAF3F5, 0x31434D, 0x39C9BF, 0x4ADDD0,
                      0x53CDA7, 0xE6B46D, 0x94A8B5)
        case .lavender:
            values = (0xF4F2F9, 0xECE8F4, 0xFFFDFF, 0xF6F3FB,
                      0x342C47, 0xE1DAED, 0x7B5BAD, 0x8582C3,
                      0x418975, 0xAA782E, 0x8E859F)
        case .sand:
            values = (0xF7F3EB, 0xEEE7DA, 0xFFFDFA, 0xF6F0E7,
                      0x4B392A, 0xE8DCCB, 0x95662E, 0xAE8350,
                      0x4C876A, 0xAE762A, 0x978776)
        }
        canvas = Self.color(values.canvas)
        sidebar = Self.color(values.sidebar)
        surface = Self.color(values.surface)
        surfaceMuted = Self.color(values.surfaceMuted)
        ink = Self.color(values.ink)
        border = Self.color(values.border)
        blue = Self.color(values.accent)
        cyan = Self.color(values.cyan)
        green = Self.color(values.green)
        amber = Self.color(values.amber)
        muted = Self.color(values.muted)
        isDark = theme == .graphite
        onAccent = isDark ? Self.color(0x102A2C) : .white
    }

    private static func color(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
}

@propertyWrapper
struct ThemePalette: DynamicProperty {
    @Environment(\.appTheme) private var theme

    var wrappedValue: ThemeColors { ThemeColors(theme: theme) }
}
