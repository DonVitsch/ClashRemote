import AppKit
import SwiftUI

private struct AppTextScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var appTextScale: CGFloat {
        get { self[AppTextScaleEnvironmentKey.self] }
        set { self[AppTextScaleEnvironmentKey.self] = newValue }
    }
}

/// A font description that resolves against the user's text size preference.
/// Changing the point size lets SwiftUI lay out the text at its actual size.
struct AppFont {
    private enum Size {
        case points(CGFloat)
        case textStyle(Font.TextStyle)
    }

    private let size: Size
    private var fontWeight: Font.Weight?
    private let design: Font.Design
    private var usesMonospacedDigits = false

    static func system(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> AppFont {
        AppFont(size: .points(size), fontWeight: weight, design: design)
    }

    static func system(
        _ style: Font.TextStyle,
        design: Font.Design = .default,
        weight: Font.Weight? = nil
    ) -> AppFont {
        AppFont(size: .textStyle(style), fontWeight: weight, design: design)
    }

    static var largeTitle: AppFont { .system(.largeTitle) }
    static var title: AppFont { .system(.title) }
    static var title2: AppFont { .system(.title2) }
    static var title3: AppFont { .system(.title3) }
    static var headline: AppFont { .system(.headline) }
    static var subheadline: AppFont { .system(.subheadline) }
    static var body: AppFont { .system(.body) }
    static var callout: AppFont { .system(.callout) }
    static var footnote: AppFont { .system(.footnote) }
    static var caption: AppFont { .system(.caption) }
    static var caption2: AppFont { .system(.caption2) }

    func weight(_ weight: Font.Weight) -> AppFont {
        var result = self
        result.fontWeight = weight
        return result
    }

    func monospacedDigit() -> AppFont {
        var result = self
        result.usesMonospacedDigits = true
        return result
    }

    @MainActor
    func resolved(scale: CGFloat) -> Font {
        let pointSize: CGFloat
        let defaultWeight: Font.Weight
        switch size {
        case .points(let value):
            pointSize = value
            defaultWeight = .regular
        case .textStyle(let style):
            pointSize = NSFont.preferredFont(forTextStyle: Self.nativeStyle(style), options: [:]).pointSize
            defaultWeight = style == .headline ? .semibold : .regular
        }

        let effectiveScale = scale.isFinite && scale > 0 ? scale : 1
        let font = Font.system(size: pointSize * effectiveScale, weight: fontWeight ?? defaultWeight, design: design)
        return usesMonospacedDigits ? font.monospacedDigit() : font
    }

    private static func nativeStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appTextScale) private var textScale
    let descriptor: AppFont

    func body(content: Content) -> some View {
        content.font(descriptor.resolved(scale: textScale))
    }
}

extension View {
    func appFont(_ descriptor: AppFont) -> some View {
        modifier(AppFontModifier(descriptor: descriptor))
    }
}
