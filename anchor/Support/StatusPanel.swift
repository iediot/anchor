import AppKit
import SwiftUI

// a menu bar extra window is placed by appkit, centred under its own icon, and offers no
// alignment of its own, so the presentation is a status item and a panel we place
// ourselves: the panel hangs to the left of the icon with its reserved strip under it
// the views, the models and the routes are the same ones the menu bar extra carried
@MainActor
final class StatusPanelPresenter: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let savedStates = SavedStatesModel()
    let setup = PermissionsSetupModel()
    let shortcut = PanelShortcut()

    private var statusItem: NSStatusItem?
    private var panel: AnchorPanel?
    private var setupWindow: NSWindow?
    private var outsideClick: Any?
    private var renameClick: Any?
    // the two faces of the icon: the anchor while the panel is shut, and the ring it
    // leaves behind while the panel is open and the anchor is hanging in it
    private var restingIcon: NSImage?
    private var openIcon: NSImage?
    private var appearanceObservation: NSKeyValueObservation?
    private var chainBridge: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // the supplied anchor silhouette, marked as a template so the menu bar draws it
        // black in light appearance and white in dark appearance
        if let image = NSImage(named: "MenuBarAnchor") {
            image.isTemplate = true
            image.size = NSSize(width: AnchorArt.box, height: AnchorArt.box)
            restingIcon = image
            openIcon = Self.chainRingIcon()
            item.button?.image = image
        } else {
            item.button?.title = "Anchor"
        }
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Anchor")
        statusItem = item
        shortcut.start { [weak self] in self?.toggle() }
        savedStates.dismissForOperation = { [weak self] in self?.close() }
        refreshIcon()
        appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshIcon()
                if let panel = self?.panel, panel.isVisible { self?.place(panel) }
            }
        }

        // an open panel belongs to this application, so a click anywhere else closes it
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationResigned),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)

        // the permissions are explained once, on the first launch, and after that only
        // when the settings menu asks for them
        if !setup.hasBeenShown {
            showSetup()
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    @objc private func applicationResigned() {
        shortcut.cancelRecording()
        close()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut.stop()
    }

    func open() {
        savedStates.backToHome()
        // opening the panel while something is running must not re-read the screen
        // underneath that operation
        if !savedStates.busy {
            savedStates.reload()
            savedStates.resolveDestination()
            setup.refreshPermissions()
            // a finished run that went through cleanly is not what the panel opens on
            savedStates.settleFinishedOperation()
        }
        // a fresh opening of the grid starts at its newest end, anything else the panel
        // was left in keeps the place it was left at
        if savedStates.route == .home {
            savedStates.revealNewest = true
        }
        // the decoration in the strip plays for the opening itself
        savedStates.openings += 1
        // the anchor has dropped into the panel, so the icon becomes the point its chain
        // is made fast to, and stays that for as long as the panel is up
        if let openIcon { statusItem?.button?.image = openIcon }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        refreshIcon()
        // again now that the panel is on screen at its real size
        place(panel)
        watchForOutsideClicks()
    }

    func close() {
        if savedStates.renaming != nil { savedStates.cancelRename() }
        if let renameClick {
            NSEvent.removeMonitor(renameClick)
            self.renameClick = nil
        }
        chainBridge?.orderOut(nil)
        panel?.orderOut(nil)
        if let restingIcon { statusItem?.button?.image = restingIcon }
        refreshIcon()
        if let outsideClick {
            NSEvent.removeMonitor(outsideClick)
            self.outsideClick = nil
        }
    }

    // the setup window is a plain window of this application, the panel only asks for it
    // dismissing it, by continue or by its close button, is what marks onboarding done
    func showSetup() {
        close()
        if setupWindow == nil {
            let root = PermissionsSetupView(model: setup, savedStates: savedStates, shortcut: shortcut) { [weak self] in
                self?.dismissSetup()
            }
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 460, height: 560))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName(SetupWindow.id)
            window.delegate = self
            window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    private func dismissSetup() {
        setup.markShown()
        setupWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === setupWindow else { return }
        shortcut.cancelRecording()
        setup.markShown()
        // whatever was granted while it was open decides what the panel shows now
        setup.refreshPermissions()
    }

    // one report, read from state anchor already holds and put on the pasteboard
    // the automation answers are read again first, without prompting
    func copyTroubleshootingReport() {
        Task { [setup, savedStates] in
            await setup.refresh()
            TroubleshootingReport.copyToPasteboard(setup: setup, savedStates: savedStates)
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
        let root = AnchorPanelView(model: savedStates, setup: setup)
            .environment(\.openSetup) { [weak self] in self?.showSetup() }
            .environment(\.closePanel) { [weak self] in self?.close() }
            .environment(\.copyTroubleshooting) { [weak self] in self?.copyTroubleshootingReport() }
            .background { PanelSurface() }
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
        // the icon's slot is symmetric around it, and the artwork's ring is a shade right
        // of the middle of its box. the chain hangs under that, wherever the panel landed
        let column = anchor.midX + AnchorArt.ringOffset - target.x
        if abs(savedStates.chainColumn - column) > 0.5 {
            savedStates.chainColumn = column
        }
        if panel.frame.origin != target { panel.setFrameOrigin(target) }
        if panel.isVisible { placeChainBridge(panel, button: button, column: column) }
    }

    private func placeChainBridge(_ panel: NSPanel, button: NSStatusBarButton, column: CGFloat) {
        guard let window = button.window,
              let imageRect = button.cell?.imageRect(forBounds: button.bounds) else { return }
        let image = window.convertToScreen(button.convert(imageRect, to: nil))
        let outlet = image.maxY - image.height * (AnchorArt.box / 2 + 1) / AnchorArt.box
        let height = outlet - panel.frame.maxY
        guard height > 0 else { chainBridge?.orderOut(nil); return }
        let bridge: NSPanel
        if let existing = chainBridge {
            bridge = existing
        } else {
            bridge = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            bridge.isOpaque = false
            bridge.backgroundColor = .clear
            bridge.hasShadow = false
            bridge.ignoresMouseEvents = true
            bridge.hidesOnDeactivate = false
            bridge.isReleasedWhenClosed = false
            bridge.level = .statusBar
            bridge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            bridge.contentView = ChainBridgeView()
            panel.addChildWindow(bridge, ordered: .above)
            chainBridge = bridge
        }
        let width: CGFloat = 12
        let x = panel.frame.minX + column - AnchorArt.nudge + AnchorArt.chainTrue
        bridge.setFrame(CGRect(x: x - width / 2, y: panel.frame.maxY,
                               width: width, height: height), display: false)
        bridge.appearance = button.effectiveAppearance
        bridge.contentView?.needsDisplay = true
        bridge.orderFront(nil)
    }

    private func refreshIcon() {
        guard let button = statusItem?.button,
              let source = panel?.isVisible == true ? openIcon : restingIcon else { return }
        source.isTemplate = true
        button.image = source
    }

    // a small deck plate with an opening for the chain
    private static func chainRingIcon() -> NSImage {
        let side = AnchorArt.box
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1)
            let plate = CGRect(x: AnchorArt.ringX - 6, y: side / 2 - 3,
                               width: 12, height: 6)
            context.addPath(CGPath(roundedRect: plate, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.strokePath()
            context.setFillColor(NSColor.black.cgColor)
            let opening = CGRect(x: AnchorArt.ringX - 2.4, y: side / 2 - 1.5,
                                 width: 4.8, height: 3)
            context.addPath(CGPath(roundedRect: opening, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
            for x in [plate.minX + 1.5, plate.maxX - 1.5] {
                context.fillEllipse(in: CGRect(x: x - 0.45, y: side / 2 - 0.45, width: 0.9, height: 0.9))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func watchForOutsideClicks() {
        if renameClick == nil {
            renameClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.savedStates.renaming != nil else { return event }
                    if event.window === self.panel,
                       let editor = self.panel?.firstResponder as? NSTextView,
                       editor.isFieldEditor,
                       editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) {
                        return event
                    }
                    self.savedStates.cancelRename()
                    return event
                }
            }
        }
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

private final class ChainBridgeView: NSView {
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let period = (ChainMetrics.link.height - ChainMetrics.overlap) * 2
        let lead = (ChainMetrics.link.height / 2 - bounds.height)
            .truncatingRemainder(dividingBy: period)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.setStrokeColor((dark ? NSColor.white : NSColor.black).cgColor)
        context.setLineWidth(ChainMetrics.lineWidth)
        context.setLineCap(.round)
        context.addPath(ChainLinks(lead: lead < 0 ? lead + period : lead).path(in: bounds).cgPath)
        context.strokePath()
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

enum SetupWindow {
    static let id = "setup"
}
