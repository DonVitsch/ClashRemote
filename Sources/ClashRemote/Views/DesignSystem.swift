import AppKit
import SwiftUI

struct PanelSurface: ViewModifier {
    @ThemePalette private var palette
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(palette.border.opacity(0.75), lineWidth: 1))
            .shadow(color: .black.opacity(palette.isDark ? 0.12 : 0.025), radius: 12, x: 0, y: 5)
    }
}

extension View {
    func panelSurface(radius: CGFloat = 18) -> some View { modifier(PanelSurface(radius: radius)) }
}

struct GlyphBadge: View {
    @ThemePalette private var palette
    let symbol: String
    var color: Color? = nil
    var size: CGFloat = 38
    var body: some View {
        let color = color ?? palette.blue
        Image(systemName: symbol)
            .font(.system(size: size * 0.41, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
    }
}

struct NetworkArtwork: View {
    @ThemePalette private var palette
    let active: Bool
    var usesProxy = true
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Canvas { context, size in
                    for x in stride(from: CGFloat(8), to: size.width, by: 16) {
                        for y in stride(from: CGFloat(8), to: size.height, by: 16) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(palette.muted.opacity(0.12)))
                        }
                    }
                    var route = Path()
                    route.move(to: CGPoint(x: w * 0.13, y: h * 0.66))
                    route.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.36), control1: CGPoint(x: w * 0.3, y: h * 0.66), control2: CGPoint(x: w * 0.3, y: h * 0.36))
                    route.addCurve(to: CGPoint(x: w * 0.87, y: h * 0.66), control1: CGPoint(x: w * 0.7, y: h * 0.36), control2: CGPoint(x: w * 0.7, y: h * 0.66))
                    context.stroke(route, with: .color(active ? palette.cyan : palette.muted.opacity(0.25)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: active ? [] : [5, 5]))
                }
                Circle().stroke(palette.cyan.opacity(0.10), lineWidth: 1).frame(width: 100, height: 100).position(x: w * 0.5, y: h * 0.36)
                Circle().stroke(palette.cyan.opacity(0.17), lineWidth: 1).frame(width: 76, height: 76).position(x: w * 0.5, y: h * 0.36)
                endpoint("laptopcomputer", label: "本机", primary: false).position(x: w * 0.13, y: h * 0.72)
                endpoint("wifi.router.fill", label: "路由器", primary: true).position(x: w * 0.5, y: h * 0.42)
                endpoint(usesProxy ? "globe.asia.australia.fill" : "arrow.right", label: usesProxy ? "节点" : "直连", primary: false).position(x: w * 0.87, y: h * 0.72)
            }
        }
        .accessibilityHidden(true)
    }

    private func endpoint(_ symbol: String, label: String, primary: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: primary ? 21 : 17, weight: .medium))
                .foregroundStyle(primary ? palette.cyan : palette.ink.opacity(0.85))
                .frame(width: primary ? 56 : 40, height: primary ? 56 : 40)
                .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: primary ? 17 : 12))
                .overlay(RoundedRectangle(cornerRadius: primary ? 17 : 12).stroke(palette.border, lineWidth: 1))
            Text(label).appFont(.system(size: 9, weight: .medium)).foregroundStyle(palette.muted)
        }
    }
}

struct WorkspaceBanner: View {
    @ThemePalette private var palette
    let symbol: String
    let title: String
    let detail: String
    var color: Color? = nil
    var body: some View {
        let color = color ?? palette.blue
        HStack(spacing: 16) {
            GlyphBadge(symbol: symbol, color: color, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).appFont(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
                Text(detail).appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 52, weight: .ultraLight)).foregroundStyle(color.opacity(0.13))
                .accessibilityHidden(true)
        }
        .padding(21).panelSurface()
    }
}

struct WorkspaceEmptyState: View {
    @ThemePalette private var palette
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(palette.cyan.opacity(0.12), lineWidth: 1).frame(width: 132, height: 132)
                Circle().fill(palette.cyan.opacity(0.06)).frame(width: 104, height: 104)
                GlyphBadge(symbol: symbol, color: palette.blue, size: 66)
                Circle().fill(palette.cyan).frame(width: 8, height: 8).offset(x: 61, y: -22)
                Circle().fill(palette.amber.opacity(0.65)).frame(width: 5, height: 5).offset(x: -54, y: 38)
            }
            Text(title).appFont(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
            Text(detail).appFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

struct ActionButtonStyle: ButtonStyle {
    @ThemePalette private var palette
    var color: Color? = nil
    var filled = true
    var onDark = false
    var labelColor: Color?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let color = color ?? palette.blue
        let foreground = enabled
            ? (labelColor ?? (filled ? palette.onAccent : (onDark ? .white : color)))
            : palette.muted
        let background = enabled
            ? (filled ? color : (onDark ? Color.white.opacity(0.13) : color.opacity(0.07)))
            : palette.surfaceMuted
        return configuration.label
            .appFont(.system(size: controlSize == .large ? 12 : 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, controlSize == .large ? 14 : 11)
            .padding(.vertical, controlSize == .large ? 10 : 7)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(!enabled ? palette.border : (onDark ? Color.white.opacity(0.16) : (filled ? .clear : color.opacity(0.16))), lineWidth: 1))
            .brightness(configuration.isPressed ? -0.05 : 0)
    }
}

struct EditorField<Content: View>: View {
    @ThemePalette private var palette
    let title: String
    var symbol: String = "pencil"
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).appFont(.system(size: 11, weight: .semibold)).foregroundStyle(palette.muted)
            content.textFieldStyle(.plain).appFont(.callout).foregroundStyle(palette.ink)
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
        }
    }
}

struct ClashAppMark: View {
    var body: some View {
        let installedURL = Bundle.main.resourceURL?
            .appendingPathComponent("ClashRemote_ClashRemote.bundle/CatLogo.png")
        if let url = installedURL ?? Bundle.module.url(forResource: "CatLogo", withExtension: "png"),
           let logo = NSImage(contentsOf: url) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}

struct StatusPill: View {
    @ThemePalette private var palette
    let running: Bool
    let connecting: Bool
    var connected = true

    var body: some View {
        let color = connecting ? palette.amber : (!connected ? palette.muted : (running ? palette.green : palette.muted))
        Text(connecting ? "连接中" : (!connected ? "未连接" : (running ? "运行中" : "未运行")))
            .appFont(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct Card<Content: View>: View {
    @ThemePalette private var palette
    @Environment(AppPreferences.self) private var preferences
    let title: String
    var subtitle: String?
    var symbol: String = "square.grid.2x2"
    var color: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                GlyphBadge(symbol: symbol, color: color, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).appFont(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(palette.ink)
                    if let subtitle {
                        Text(subtitle).appFont(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(preferences.density == .comfortable ? 25 : 20).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(palette.ink).panelSurface()
    }
}

struct ToggleCard: View {
    @ThemePalette private var palette
    @Environment(AppPreferences.self) private var preferences
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
        }
        .toggleStyle(.switch)
        .foregroundStyle(palette.ink).tint(palette.blue)
        .padding(preferences.density == .comfortable ? 16 : 12)
        .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 11))
    }
}

