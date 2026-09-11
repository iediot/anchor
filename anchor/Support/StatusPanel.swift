import AppKit
import SwiftUI

// a menu bar extra window is placed by appkit, centred under its own icon, and offers no
// alignment of its own, so the presentation is a status item and a panel we place
// ourselves: the panel hangs to the left of the icon with its reserved strip under it
// the views, the models and the routes are the same ones the menu bar extra carried
@MainActor
final class StatusPanelPresenter: NSObject, NSApplicationDelegate {
    let savedStates = SavedStatesModel()
    let diagnostics = DiagnosticsModel()

    private var statusItem: NSStatusItem?
    private var panel: AnchorPanel?
    private var diagnosticsWindow: NSWindow?
    private var outsideClick: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // the supplied anchor silhouette, marked as a template so the menu bar draws it
        // black in light appearance and white in dark appearance
        if let image = NSImage(named: "MenuBarAnchor") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        } else {
            item.button?.title = "Anchor"
        }
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Anchor")
        statusItem = item

        // an open panel belongs to this application, so a click anywhere else closes it
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationResigned),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
    }

    @objc private func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    @objc private func applicationResigned() {
        close()
    }

    func open() {
        // opening the panel while something is running must not re-read the screen
        // underneath that operation
        if !savedStates.busy {
            savedStates.reload()
            savedStates.resolveDestination()
            diagnostics.refreshPermissions()
        }
        // a fresh opening of the grid starts at its newest end, anything else the panel
        // was left in keeps the place it was left at
        if savedStates.route == .home {
            savedStates.revealNewest = true
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // again now that the panel is on screen at its real size
        place(panel)
        watchForOutsideClicks()
    }

    func close() {
        panel?.orderOut(nil)
        if let outsideClick {
            NSEvent.removeMonitor(outsideClick)
            self.outsideClick = nil
        }
    }

    private func makePanel() -> AnchorPanel {
        let panel = AnchorPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered,
                                defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = AnchorPanelView(model: savedStates, diagnostics: diagnostics)
            .environment(\.openDiagnostics) { [weak self] in self?.showDiagnostics() }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        let controller = NSHostingController(rootView: root)
        // the content decides the size, the placement keeps the top edge under the icon
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = .clear
        panel.onResize = { [weak self, weak panel] in
            guard let panel else { return }
            self?.place(panel)
        }
        return panel
    }

    private func place(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        // across, the status item slot is symmetric around the icon and the button bounds
        // are not, down, the button bounds are the ones that sit right under the menu bar
        let bounds = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let slot = buttonWindow.frame
        let anchor = CGRect(x: slot.minX, y: bounds.minY, width: slot.width, height: bounds.height)
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let usable = screen?.visibleFrame else { return }
        // moving it to where it already is would start another layout pass for nothing
        let target = PanelPlacement.origin(anchor: anchor, size: panel.frame.size, usable: usable)
        guard panel.frame.origin != target else { return }
        panel.setFrameOrigin(target)
    }

    private func watchForOutsideClicks() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    // the diagnostics window is a plain window of this application, the panel only asks
    // for it, and it closes the panel the way any other click outside would
    func showDiagnostics() {
        close()
        if diagnosticsWindow == nil {
            let controller = NSHostingController(rootView: ContentView(model: diagnostics, savedStates: savedStates))
            let window = NSWindow(contentViewController: controller)
            window.title = "Anchor Diagnostics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 620))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName(DiagnosticsWindow.id)
            window.center()
            diagnosticsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
}

// the reserved strip on the right ends up under the icon, with the icon roughly at its
// middle, the rest of the panel hangs to the left and the whole of it stays on screen
enum PanelPlacement {
    static func origin(anchor: CGRect, size: CGSize, usable: CGRect) -> CGPoint {
        let minX = usable.minX + PanelMetrics.screenInset
        let maxX = max(minX, usable.maxX - PanelMetrics.screenInset - size.width)
        let centred = anchor.midX + PanelMetrics.decorationStrip / 2 + PanelMetrics.rightNudge - size.width
        let x = min(max(centred, minX), maxX)
        let minY = usable.minY + PanelMetrics.screenInset
        let y = max(anchor.minY - PanelMetrics.menuBarGap - size.height, minY)
        return CGPoint(x: x, y: y)
    }

    // what the panel occupies on screen, the edge a reader cares about is the right one
    static func frame(anchor: CGRect, size: CGSize, usable: CGRect) -> CGRect {
        CGRect(origin: origin(anchor: anchor, size: size, usable: usable), size: size)
    }
}

// a borderless panel takes key focus only if it says so, and the rename field needs it
final class AnchorPanel: NSPanel {
    var onResize: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var lastSize: NSSize = .zero
    private var repositioning = false

    // the content decides the height, and the panel hangs from a fixed top edge, so a
    // new size has to be placed again rather than growing downwards
    // the placement waits for the next turn of the run loop, never runs inside this call,
    // because setting the frame lays the content out again and a placement from in there
    // sets the frame again, down and down until the stack is gone
    override func setFrame(_ frameRect: NSRect, display: Bool) {
        super.setFrame(frameRect, display: display)
        guard frameRect.size != lastSize else { return }
        lastSize = frameRect.size
        guard !repositioning else { return }
        repositioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.repositioning = false
            self.onResize?()
        }
    }
}

enum DiagnosticsWindow {
    static let id = "diagnostics"
}
