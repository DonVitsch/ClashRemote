import AppKit
import SwiftUI

/// Applies preferences to this app's own window, once it has joined the view hierarchy.
struct WindowPreferences: NSViewRepresentable {
    let alwaysOnTop: Bool
    var rememberFrame: Bool? = nil

    func makeNSView(context: Context) -> WindowPreferenceHost {
        let view = WindowPreferenceHost()
        view.alwaysOnTop = alwaysOnTop
        view.rememberFrame = rememberFrame
        return view
    }

    func updateNSView(_ view: WindowPreferenceHost, context: Context) {
        view.alwaysOnTop = alwaysOnTop
        view.rememberFrame = rememberFrame
        view.applyPreferences()
    }
}

final class WindowPreferenceHost: NSView {
    var alwaysOnTop = false
    var rememberFrame: Bool?
    private weak var configuredWindow: NSWindow?
    private var frameSavingEnabled = false
    private static let frameName = "ClashRemote.MainWindow"

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPreferences()
    }

    func applyPreferences() {
        guard let window else { return }
        let isNewWindow = configuredWindow !== window
        if isNewWindow {
            configuredWindow = window
            frameSavingEnabled = false
        }
        window.level = alwaysOnTop ? .floating : .normal
        guard let rememberFrame else { return }
        window.isRestorable = rememberFrame
        if rememberFrame, !frameSavingEnabled {
            // Only restore on initial presentation; turning this on should not move a window.
            if !isNewWindow { window.saveFrame(usingName: Self.frameName) }
            frameSavingEnabled = window.setFrameAutosaveName(Self.frameName)
            if isNewWindow, frameSavingEnabled {
                _ = window.setFrameUsingName(Self.frameName)
            }
        } else if !rememberFrame, frameSavingEnabled || isNewWindow {
            _ = window.setFrameAutosaveName("")
            frameSavingEnabled = false
        }
    }
}
