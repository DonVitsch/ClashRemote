import AppKit
import SwiftUI

enum ClashPalette {
    static let canvas = adaptive(0xF0F4F8, 0x111922)
    static let sidebar = adaptive(0xE8EEF5, 0x16212D)
    static let surface = adaptive(0xFFFFFF, 0x1C2937)
    static let surfaceMuted = adaptive(0xF5F8FB, 0x223140)
    static let ink = adaptive(0x172B43, 0xE3EDF7)
    static let border = adaptive(0xDCE5EE, 0x314354)
    static let blue = adaptive(0x286BCB, 0x75AEF7)
    static let cyan = Color(red: 0.15, green: 0.73, blue: 0.78)
    static let green = adaptive(0x239875, 0x54CDA5)
    static let amber = adaptive(0xBC781D, 0xE7B05F)
    static let muted = adaptive(0x788BA0, 0x8BA0B5)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct PanelSurface: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(ClashPalette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(ClashPalette.border.opacity(0.75), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 5)
    }
}

extension View {
    func panelSurface(radius: CGFloat = 18) -> some View { modifier(PanelSurface(radius: radius)) }
}

struct GlyphBadge: View {
    let symbol: String
    var color: Color = ClashPalette.blue
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.41, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
    }
}

struct NetworkArtwork: View {
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
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.12)))
                        }
                    }
                    var route = Path()
                    route.move(to: CGPoint(x: w * 0.13, y: h * 0.66))
                    route.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.36), control1: CGPoint(x: w * 0.3, y: h * 0.66), control2: CGPoint(x: w * 0.3, y: h * 0.36))
                    route.addCurve(to: CGPoint(x: w * 0.87, y: h * 0.66), control1: CGPoint(x: w * 0.7, y: h * 0.36), control2: CGPoint(x: w * 0.7, y: h * 0.66))
                    context.stroke(route, with: .color(active ? ClashPalette.cyan : .white.opacity(0.25)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: active ? [] : [5, 5]))
                }
                Circle().stroke(ClashPalette.cyan.opacity(0.10), lineWidth: 1).frame(width: 100, height: 100).position(x: w * 0.5, y: h * 0.36)
                Circle().stroke(ClashPalette.cyan.opacity(0.17), lineWidth: 1).frame(width: 76, height: 76).position(x: w * 0.5, y: h * 0.36)
                endpoint("laptopcomputer", label: "MAC", primary: false).position(x: w * 0.13, y: h * 0.72)
                endpoint("wifi.router.fill", label: "ROUTER", primary: true).position(x: w * 0.5, y: h * 0.42)
                endpoint(usesProxy ? "globe.asia.australia.fill" : "arrow.right", label: usesProxy ? "NODE" : "DIRECT", primary: false).position(x: w * 0.87, y: h * 0.72)
            }
        }
        .accessibilityHidden(true)
    }

    private func endpoint(_ symbol: String, label: String, primary: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: primary ? 21 : 17, weight: .medium))
                .foregroundStyle(primary ? ClashPalette.cyan : .white.opacity(0.85))
                .frame(width: primary ? 56 : 40, height: primary ? 56 : 40)
                .background(Color(red: 0.11, green: 0.24, blue: 0.34), in: RoundedRectangle(cornerRadius: primary ? 17 : 12))
                .overlay(RoundedRectangle(cornerRadius: primary ? 17 : 12).stroke(.white.opacity(primary ? 0.28 : 0.13), lineWidth: 1))
            Text(label).font(.system(size: 7, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct WorkspaceBanner: View {
    let symbol: String
    let title: String
    let detail: String
    var color: Color = ClashPalette.blue
    var body: some View {
        HStack(spacing: 16) {
            GlyphBadge(symbol: symbol, color: color, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(ClashPalette.cyan.opacity(0.12), lineWidth: 1).frame(width: 132, height: 132)
                Circle().fill(ClashPalette.cyan.opacity(0.06)).frame(width: 104, height: 104)
                GlyphBadge(symbol: symbol, color: ClashPalette.blue, size: 66)
                Circle().fill(ClashPalette.cyan).frame(width: 8, height: 8).offset(x: 61, y: -22)
                Circle().fill(ClashPalette.amber.opacity(0.65)).frame(width: 5, height: 5).offset(x: -54, y: 38)
            }
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

struct ActionButtonStyle: ButtonStyle {
    var color: Color = Color(red: 0.15, green: 0.40, blue: 0.76)
    var filled = true
    var onDark = false
    var labelColor: Color?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: controlSize == .large ? 12 : 11, weight: .semibold))
            .foregroundStyle(labelColor ?? (filled ? .white : (onDark ? .white : ClashPalette.blue)))
            .padding(.horizontal, controlSize == .large ? 14 : 11)
            .padding(.vertical, controlSize == .large ? 10 : 7)
            .background(filled ? color : (onDark ? Color.white.opacity(0.13) : ClashPalette.blue.opacity(0.07)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(onDark ? Color.white.opacity(0.16) : (filled ? .clear : ClashPalette.blue.opacity(0.16)), lineWidth: 1))
            .brightness(configuration.isPressed ? -0.05 : 0)
            .opacity(enabled ? 1 : 0.4)
    }
}

struct EditorField<Content: View>: View {
    let title: String
    var symbol: String = "pencil"
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(ClashPalette.muted)
            content.textFieldStyle(.plain).font(.callout)
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(ClashPalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ClashPalette.border, lineWidth: 1))
        }
    }
}

struct ClashAppMark: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.72, blue: 0.77), Color(red: 0.16, green: 0.40, blue: 0.79)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Canvas { context, bounds in
                    let points = [
                        CGPoint(x: bounds.width * 0.29, y: bounds.height * 0.34),
                        CGPoint(x: bounds.width * 0.73, y: bounds.height * 0.34),
                        CGPoint(x: bounds.width * 0.50, y: bounds.height * 0.71)
                    ]
                    var route = Path()
                    route.move(to: points[0])
                    route.addLine(to: points[1])
                    route.addLine(to: points[2])
                    route.closeSubpath()
                    context.stroke(route, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: size * 0.025, lineCap: .round, dash: [size * 0.025, size * 0.075]))
                    for (index, point) in points.enumerated() {
                        let radius = size * (index == 1 ? 0.10 : 0.08)
                        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.white))
                        let innerRadius = radius * 0.45
                        context.fill(Path(ellipseIn: CGRect(x: point.x - innerRadius, y: point.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)), with: .color(Color(red: 0.15, green: 0.54, blue: 0.75)))
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let running: Bool
    let connecting: Bool
    var connected = true

    var body: some View {
        Text(connecting ? "连接中" : (!connected ? "未连接" : (running ? "运行中" : "未运行")))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(running ? ClashPalette.green : (connecting ? ClashPalette.amber : ClashPalette.muted))
            .background(
                (running ? ClashPalette.green : (connecting ? ClashPalette.amber : ClashPalette.muted)).opacity(0.14),
                in: Capsule()
            )
    }
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String = "square.grid.2x2"
    var color: Color = ClashPalette.blue
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                GlyphBadge(symbol: symbol, color: color, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(ClashPalette.ink)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).panelSurface()
    }
}

struct ToggleCard: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
        }
        .toggleStyle(.switch)
        .padding(12)
        .background(ClashPalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 11))
    }
}

