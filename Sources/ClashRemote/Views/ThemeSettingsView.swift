import SwiftUI

struct ThemeSettingsView: View {
    @Environment(\.appTheme) private var selectedTheme
    @ThemePalette private var palette
    @AppStorage(AppTheme.storageKey) private var storedTheme: AppTheme = .mintCat

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                GlyphBadge(symbol: "paintpalette.fill", color: palette.blue, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择你喜欢的主题").appFont(.system(size: 19, weight: .bold, design: .rounded))
                    Text("点击即可切换。配色、总览布局和路由器图案会一起更新。")
                        .appFont(.callout).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 370), spacing: 16)], spacing: 16) {
                ForEach(AppTheme.allCases) { theme in
                    ThemePreviewCard(theme: theme, selected: selectedTheme == theme) {
                        storedTheme = theme
                    }
                }
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("路由器在画面中央").appFont(.system(size: 14, weight: .semibold))
                    Text("每种主题都保留本机、路由器与节点的连接图，直观看到当前线路。")
                        .appFont(.callout).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("主题会自动保存，下次打开继续使用。")
                        .appFont(.caption).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                ThemeRouterPreview(color: palette.cyan, ink: palette.ink)
                    .frame(width: 230)
            }
            .padding(20).panelSurface()
        }
        .background(palette.canvas)
        .foregroundStyle(palette.ink)
    }
}

private struct ThemePreviewCard: View {
    @ThemePalette private var palette
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                ThemeThumbnail(theme: theme)
                    .frame(height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.colors.border, lineWidth: 1))
                HStack(spacing: 7) {
                    Text(theme.title).appFont(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    if selected {
                        Label("使用中", systemImage: "checkmark.circle.fill")
                            .appFont(.caption.weight(.medium)).foregroundStyle(palette.blue)
                    }
                }
                Text(theme.detail).appFont(.caption).foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .foregroundStyle(palette.ink)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(selected ? palette.blue : palette.border, lineWidth: selected ? 2 : 1))
            .shadow(color: palette.blue.opacity(selected ? 0.07 : 0), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title)，\(theme.detail)")
        .accessibilityValue(selected ? "当前主题" : "")
        .accessibilityHint("切换并保存主题")
    }
}

private struct ThemeThumbnail: View {
    let theme: AppTheme
    private var colors: ThemeColors { theme.colors }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                ClashAppMark().frame(width: 15, height: 15).padding(.bottom, 2)
                ForEach(0..<5) { index in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(index == 0 ? colors.blue : colors.muted.opacity(0.4)).frame(width: 4, height: 4)
                        Capsule().fill(index == 0 ? colors.ink.opacity(0.75) : colors.muted.opacity(0.35)).frame(width: 17, height: 3)
                    }
                    .padding(.vertical, 2)
                }
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 4).fill(colors.surface).frame(height: 15)
            }
            .padding(8).frame(width: 46).background(colors.sidebar)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Capsule().fill(colors.ink.opacity(0.8)).frame(width: 28, height: 5)
                    Capsule().fill(colors.green.opacity(0.25)).frame(width: 17, height: 5)
                    Spacer()
                }

                if theme.usesCatArtwork {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(colors.ink.opacity(0.65)).frame(width: 38, height: 5)
                            Capsule().fill(colors.muted.opacity(0.4)).frame(width: 48, height: 3)
                            Capsule().fill(colors.blue).frame(width: 27, height: 8)
                        }
                        Spacer(minLength: 1)
                        Image(systemName: "cat.fill").appFont(.system(size: 33)).foregroundStyle(colors.blue.opacity(0.48))
                    }
                    .padding(10).frame(maxWidth: .infinity, minHeight: 51)
                    .background(colors.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    miniatureRoute.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 51)
                        .background(colors.surface, in: RoundedRectangle(cornerRadius: 7))
                }

                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(colors.muted.opacity(0.3)).frame(width: 16, height: 2)
                            Capsule().fill((index == 0 ? colors.blue : colors.ink).opacity(0.6)).frame(width: 21, height: 4)
                        }
                        .padding(6).frame(maxWidth: .infinity)
                        .background(colors.surface, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 5).fill(colors.surface)
                        .overlay(Capsule().fill(colors.blue.opacity(0.6)).frame(width: 33, height: 4))
                    RoundedRectangle(cornerRadius: 5).fill(colors.surface)
                        .overlay(miniatureRoute.padding(.horizontal, 5))
                }
                .frame(height: 23)
            }
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.canvas)
        }
        .accessibilityHidden(true)
    }

    private var miniatureRoute: some View {
        HStack(spacing: 4) {
            Image(systemName: "laptopcomputer").appFont(.system(size: 10)).foregroundStyle(colors.muted)
            Rectangle().fill(colors.cyan.opacity(0.5)).frame(height: 1)
            Image(systemName: "wifi.router.fill").appFont(.system(size: 15)).foregroundStyle(colors.cyan)
            Rectangle().fill(colors.cyan.opacity(0.5)).frame(height: 1)
            Image(systemName: "globe").appFont(.system(size: 10)).foregroundStyle(colors.muted)
        }
    }
}

private struct ThemeRouterPreview: View {
    let color: Color
    let ink: Color

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            endpoint("laptopcomputer", title: "本机", primary: false)
            Rectangle().fill(color.opacity(0.45)).frame(height: 1).offset(y: -9)
            endpoint("wifi.router.fill", title: "路由器", primary: true)
            Rectangle().fill(color.opacity(0.45)).frame(height: 1).offset(y: -9)
            endpoint("globe", title: "节点", primary: false)
        }
        .accessibilityHidden(true)
    }

    private func endpoint(_ symbol: String, title: String, primary: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).appFont(.system(size: primary ? 22 : 18, weight: .medium))
                .foregroundStyle(primary ? color : ink.opacity(0.65))
                .frame(width: 45, height: 45)
                .background(color.opacity(primary ? 0.12 : 0.04), in: Circle())
                .overlay(Circle().stroke(color.opacity(primary ? 0.7 : 0.15), lineWidth: 1))
            Text(title).appFont(.system(size: 10, weight: primary ? .semibold : .regular)).foregroundStyle(ink.opacity(0.65))
        }
    }
}

struct AppearanceSettingsWindow: View {
    @Environment(AppPreferences.self) private var preferences
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .mintCat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ClashAppMark().frame(width: 37, height: 37)
                VStack(alignment: .leading, spacing: 4) {
                    Text("软件设置").appFont(.system(size: 21, weight: .bold, design: .rounded))
                    Text("Clash Remote").appFont(.caption).foregroundStyle(theme.colors.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 29).padding(.top, 24).padding(.bottom, 20)
            AppSettingsView()
        }
        .frame(minWidth: 740, idealWidth: 870, minHeight: 600, idealHeight: 760)
        .background(theme.colors.canvas)
        .foregroundStyle(theme.colors.ink)
        .tint(theme.colors.blue)
        .environment(\.appTheme, theme)
        .environment(\.appTextScale, preferences.textSize.scale)
        .preferredColorScheme(theme.colorScheme)
    }
}
