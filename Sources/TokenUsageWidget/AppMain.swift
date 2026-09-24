import AppKit
import SwiftUI

// A non-activating panel still has to be able to become key, or SwiftUI
// buttons inside it never receive their clicks.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Deliver the first click on an unfocused panel to the control under the
// cursor instead of spending it on focusing the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private let compactDefaultsKey = "TokenMeterCompactLayout"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!

    private var contentSize: NSSize {
        model.isCompact ? DashboardView.compactSize : DashboardView.expandedSize
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePanel()
        model.start()
        showPanel()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Token Meter")
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "Token Meter"
        }
    }

    private func configurePanel() {
        if let stored = UserDefaults.standard.object(forKey: compactDefaultsKey) as? Bool {
            model.isCompact = stored
        }
        panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // The card draws its own chrome, so the standard traffic lights would
        // just float above it in the title-bar strip.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Desktop-widget layer: just above the desktop icons, far below every
        // normal window. It must be ABOVE Finder's full-screen icon window,
        // which otherwise intercepts all clicks and makes the panel undraggable.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setFrameAutosaveName("TokenUsageWidgetPanel")

        let root = DashboardView(
            model: model,
            onClose: { [weak self] in self?.panel.orderOut(nil) },
            onQuit: { NSApp.terminate(nil) },
            onToggleSize: { [weak self] in self?.toggleSize() }
        )
        panel.contentView = FirstMouseHostingView(rootView: root)
        // After setFrameAutosaveName, so an autosaved frame from a previous
        // layout keeps its top-left corner but not its size.
        resizePanelKeepingTopLeft()
    }

    private func toggleSize() {
        model.isCompact.toggle()
        UserDefaults.standard.set(model.isCompact, forKey: compactDefaultsKey)
        resizePanelKeepingTopLeft()
    }

    // Grow and shrink from the top-left corner: the panel is parked near a
    // screen edge, and NSWindow would otherwise anchor the bottom-left.
    private func resizePanelKeepingTopLeft() {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        // Size the FRAME, not the content: .titled would otherwise add a
        // title-bar strip on top of the layout's own height, leaving a dead
        // band above the card. .fullSizeContentView gives the whole frame to
        // the content view, so frame size == layout size.
        panel.setFrame(
            NSRect(
                x: topLeft.x,
                y: topLeft.y - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            ),
            display: true
        )
    }

    @objc private func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : showPanel()
    }

    private func showPanel() {
        if UserDefaults.standard.string(forKey: "NSWindow Frame TokenUsageWidgetPanel") == nil {
            positionPanelAtTopRight()
        }
        panel.orderFrontRegardless()
        model.refresh()
    }

    private func positionPanelAtTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - 24,
            y: visible.maxY - panel.frame.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}

@main
struct TokenUsageWidgetMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}
