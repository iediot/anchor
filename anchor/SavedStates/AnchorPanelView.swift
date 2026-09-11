import AppKit
import SwiftUI

// opening the diagnostics window is the presenter's job, the panel only asks
extension EnvironmentValues {
    @Entry var openDiagnostics: () -> Void = {}
}

// the attached surface under the menu bar icon
// one instance of the models, one place for save, the grid of saved layouts, the
// selected layout and the outcome of a run
struct AnchorPanelView: View {
    @Bindable var model: SavedStatesModel
    @Bindable var diagnostics: DiagnosticsModel
    @Environment(\.openDiagnostics) private var openDiagnostics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // the plus turns into a tick for a moment when a save lands, and turns back
    @State private var justSaved = false
    // one copy of the preview travels between the card and the layout screen, drawn
    // above both scrolling regions so neither clips it
    @State private var travelling: Snapshot?
    @State private var travelRect: CGRect = .zero
    @State private var tileRect: CGRect = .zero
    @State private var detailRect: CGRect = .zero
    @State private var transitionComplete = true

    var body: some View {
        HStack(spacing: 0) {
            column
                .frame(width: PanelMetrics.contentWidth)
            // kept clear for the anchor decoration that lands here later
            Color.clear
                .frame(width: PanelMetrics.decorationStrip)
        }
        .frame(width: PanelMetrics.width)
        .coordinateSpace(.named(PanelSpace.panel))
        .overlay(alignment: .topLeading) { travellingPreview }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // a travel that never gets its landing rectangle must not hold the buttons back
        .task(id: transitionComplete) {
            guard !transitionComplete else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !transitionComplete else { return }
            travelling = nil
            transitionComplete = true
        }
    }

    // the copy in flight, outside both scroll views so nothing clips it
    @ViewBuilder
    private var travellingPreview: some View {
        if let snapshot = travelling, travelRect.width > 1, travelRect.height > 1 {
            LayoutThumbnail(snapshot: snapshot,
                            fit: CGSize(width: travelRect.width, height: travelRect.height))
                .frame(width: travelRect.width, height: travelRect.height)
                .offset(x: travelRect.minX, y: travelRect.minY)
                .allowsHitTesting(false)
        }
    }

    // opening a layout: the card's own preview hands over to the travelling copy, which
    // flies to where the layout screen will draw its own
    private func openLayout(_ snapshot: Snapshot, from frame: CGRect) {
        guard !model.busy else { return }
        tileRect = frame
        detailRect = .zero
        transitionComplete = reduceMotion
        if !reduceMotion, frame.width > 1 {
            travelling = snapshot
            travelRect = frame
        }
        withAnimation(PanelMotion.crossfade(reduceMotion)) {
            model.requestPreview(for: snapshot.id)
        }
    }

    // the layout screen has told us where its preview sits, so the copy can fly to it
    private func travelToDetail(_ frame: CGRect) {
        detailRect = frame
        guard travelling != nil, !transitionComplete, frame.width > 1 else { return }
        withAnimation(PanelMotion.navigation(reduceMotion)) {
            travelRect = frame
        } completion: {
            travelling = nil
            transitionComplete = true
        }
    }

    private func backToGrid() {
        let target = tileRect
        transitionComplete = reduceMotion
        if !reduceMotion, detailRect.width > 1, target.width > 1 {
            travelling = model.selected
            travelRect = detailRect
        }
        withAnimation(PanelMotion.crossfade(reduceMotion)) {
            model.backToHome()
        }
        guard travelling != nil else { return }
        withAnimation(PanelMotion.navigation(reduceMotion)) {
            travelRect = target
        } completion: {
            travelling = nil
            transitionComplete = true
        }
    }

    @ViewBuilder
    private var column: some View {
        if showsLayoutScreen {
            // the grid stays mounted underneath, so its scroll position survives the trip
            // and the preview has something to travel from and back to
            ZStack(alignment: .top) {
                gridColumn
                    .opacity(isHome ? 1 : 0)
                    .allowsHitTesting(isHome)
                if !isHome {
                    RestorePreviewView(model: model,
                                       previewHidden: travelling != nil,
                                       transitionComplete: transitionComplete,
                                       onPreviewFrame: travelToDetail,
                                       onBack: backToGrid)
                        .transition(.opacity)
                }
            }
            .frame(height: PanelMetrics.panelHeight)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                content.frame(maxWidth: .infinity, alignment: .leading)
                footer
            }
        }
    }

    private var gridColumn: some View {
        // the cards scroll under the footer and show through its blur
        // the box is the panel's height whether the grid fills it or not
        ZStack(alignment: .bottom) {
            home.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(height: PanelMetrics.panelHeight)
    }

    private var isHome: Bool {
        if case .home = model.route { return true }
        return false
    }

    // the grid and the layout screen share one box and one transition
    private var showsLayoutScreen: Bool {
        if model.browserDisclosurePending { return false }
        switch model.route {
        case .home, .preview: return true
        default: return false
        }
    }

    // the grid carries no title, the room goes to the cards
    // the way back is the only thing a header is needed for
    @ViewBuilder
    private var header: some View {
        if case .home = model.route {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Button {
                    model.backToHome()
                } label: {
                    Label("Saved layouts", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
                Spacer()
                if model.busy && !model.saving {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, PanelMetrics.gridPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.browserDisclosurePending {
            // shown in the panel rather than in a sheet, a status item popover is a poor
            // host for a modal and this is the gate in front of the first save
            disclosure
        } else {
            routed
        }
    }

    @ViewBuilder
    private var routed: some View {
        switch model.route {
        case .home:
            home
        case .detail(let id):
            if let snapshot = model.snapshots.first(where: { $0.id == id }) {
                PanelScroll(maxHeight: PanelMetrics.viewport(reserving: 200)) {
                    SnapshotDetailView(snapshot: snapshot, model: model).padding(PanelMetrics.gridPadding)
                }
            } else {
                missing
            }
        case .preview:
            RestorePreviewView(model: model)
        case .operation:
            RestoreProgressView(model: model)
        case .replacement:
            ReplacementProgressView(model: model)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            notices
            if let id = model.renaming {
                renameRow(id).padding(.bottom, 8)
            }
            grid
        }
    }

    // whatever sits above the grid comes out of the grid's own height, so the panel
    // stays the one size
    private var aboveGridReserve: CGFloat {
        var total: CGFloat = 0
        if showsNotices { total += 34 }
        if model.renaming != nil { total += 62 }
        return total
    }

    private var showsNotices: Bool {
        model.storeError != nil || model.deleteError != nil
            || model.replacement.isRunning || model.restore.isRunning
    }

    // everything that is not a saved layout, kept to one compact block above the grid
    // nothing is rendered, and no room taken, when there is nothing to say
    @ViewBuilder
    private var notices: some View {
        if showsNotices {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.deleteError {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if let error = model.storeError {
                    Text("Saved layouts cannot be stored: \(error)").font(.caption).foregroundStyle(.orange)
                }
                runningLink
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.horizontal, PanelMetrics.gridPadding)
            .padding(.bottom, 8)
        }
    }

    private var grid: some View {
        let rows = tileRows
        return PanelScroll(maxHeight: max(PanelMetrics.gridHeight(rows: 1),
                                          PanelMetrics.panelHeight - aboveGridReserve),
                           initialHeight: PanelMetrics.gridHeight(rows: min(max(rows.count, 1), PanelMetrics.visibleRows)),
                           revealBottom: $model.revealNewest) {
            // a plain stack, because a lazy one has no reliable height to measure
            VStack(alignment: .leading, spacing: PanelMetrics.tileSpacing) {
                if rows.isEmpty && model.failures.isEmpty {
                    Text("No anchor points yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: PanelMetrics.tileSpacing) {
                        ForEach(row) { snapshot in
                            SavedLayoutTile(snapshot: snapshot,
                                            model: model,
                                            previewHidden: travelling?.id == snapshot.id,
                                            onOpen: { frame in openLayout(snapshot, from: frame) })
                                .id(PanelScrollAnchor.tile(snapshot.id))
                        }
                        // a short row keeps its cards at column width
                        ForEach(0..<(PanelMetrics.columns - row.count), id: \.self) { _ in
                            Color.clear.frame(width: PanelMetrics.tileWidth, height: 1)
                        }
                    }
                }
                ForEach(model.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.header?.name ?? failure.fileName).font(.caption)
                        Text(failure.reason).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(PanelMetrics.gridPadding)
            .padding(.bottom, PanelMetrics.footerHeight / 2)
        }
    }

    // oldest first, and the full rows sit at the bottom, so the short row is the top one
    private var tileRows: [[Snapshot]] {
        let cards = model.oldestFirst
        guard !cards.isEmpty else { return [] }
        let columns = PanelMetrics.columns
        var rows: [[Snapshot]] = []
        var index = cards.count % columns
        if index > 0 { rows.append(Array(cards[0..<index])) }
        while index < cards.count {
            rows.append(Array(cards[index..<min(index + columns, cards.count)]))
            index += columns
        }
        return rows
    }

    private func renameRow(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Name this layout").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Name", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { model.commitRename() }
                Button("Cancel") { model.cancelRename() }
                    .buttonStyle(.link)
            }
            if let error = model.renameError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, PanelMetrics.gridPadding)
    }

    // the way back into an operation that is still going, including one waiting on a
    // decision, a finished one is not something the grid carries
    @ViewBuilder
    private var runningLink: some View {
        if model.replacement.isRunning {
            Button {
                model.show(.replacement)
            } label: {
                Label("Switching in progress…", systemImage: "arrow.triangle.swap")
                    .font(.caption)
            }
            .buttonStyle(.link)
        } else if model.restore.isRunning {
            Button {
                model.show(.operation)
            } label: {
                Label("Opening in progress…", systemImage: "arrow.uturn.up")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
    }

    private var missing: some View {
        Text("That saved layout is no longer in the list.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(PanelMetrics.gridPadding)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            secondaryControls
            Button {
                guard !model.busy else { return }
                model.requestSave()
            } label: {
                ZStack {
                    Label("New Anchor Point", systemImage: "plus")
                        .opacity(justSaved ? 0 : 1)
                    Label("Saved", systemImage: "checkmark")
                        .opacity(justSaved ? 1 : 0)
                }
                .font(.caption)
            }
            .controlSize(.small)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .allowsHitTesting(!model.busy)
            .accessibilityLabel(justSaved ? "Saved" : "New Anchor Point")
            .accessibilityValue(model.saving ? "Saving" : "")
            .overlay {
                if model.saving {
                    SavingOutline()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.2), value: model.saving)
            .onChange(of: model.saving) { _, saving in
                if saving { justSaved = false }
            }
            .onChange(of: model.lastOutcome?.snapshot?.id) { _, saved in
                guard saved != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { justSaved = true }
            }
            .task(id: justSaved) {
                guard justSaved else { return }
                do { try await Task.sleep(for: .seconds(1.1)) }
                catch { return }
                withAnimation(.easeInOut(duration: 0.2)) { justSaved = false }
            }
            Spacer()
            if !diagnostics.accessibilityGranted {
                Label("Accessibility", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Grant…") { Permissions.requestAccessibility() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, PanelMetrics.gridPadding)
        .frame(height: PanelMetrics.footerHeight)
        // the blur ramps in above the bar, so cards slide into it instead of hitting a line
        // the bar runs the full width of the panel, the reserved strip included
        .background(alignment: .bottomLeading) {
            WithinWindowBlur()
                .frame(width: PanelMetrics.width, height: PanelMetrics.footerHeight + 22)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black.opacity(0.6), location: 0.45),
                                             .init(color: .black, location: 0.8)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .allowsHitTesting(false)
        }
    }

    // everything that is not saving or switching lives behind this one control
    private var secondaryControls: some View {
        Menu {
            Toggle("Include browser tabs when saving", isOn: $model.includeBrowserTabs)
            Divider()
            Button("Diagnostics…") { openDiagnostics() }
            // the temporary pycharm launch test lives in that window
            Button("PyCharm Launch Test…") { openDiagnostics() }
            Divider()
            Button("Quit Anchor") { NSApplication.shared.terminate(nil) }
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saving browser tabs").font(.callout).bold()
            Text("""
                 Anchor stores the full address and title of every tab in the Safari and Chrome windows \
                 on the screen you are saving. Snapshots stay on this Mac, in your Application Support folder, \
                 and are never added to logs or to copied diagnostics.
                 """)
            Text(BrowserCapture.privateDetectionLimitation)
                .foregroundStyle(.orange)
            Text("Anchor asks this once. You can change it later in this panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Save With Browser Tabs") { model.answerDisclosure(includeBrowserTabs: true) }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
            Button("Save Without Browser Tabs") { model.answerDisclosure(includeBrowserTabs: false) }
                .frame(maxWidth: .infinity)
            Button("Cancel") { model.cancelDisclosure() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
        }
        .font(.caption)
        .padding(PanelMetrics.gridPadding)
    }
}

// a line running around the button while a save is in flight
struct SavingOutline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let length: CGFloat = 0.28
    private let period: Double = 1.2

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0 : CGFloat(seconds.truncatingRemainder(dividingBy: period) / period)
            let end = phase + length
            ZStack {
                segment(from: phase, to: min(end, 1))
                // the part that has run past the corner and come back around
                if end > 1 {
                    segment(from: 0, to: end - 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func segment(from: CGFloat, to: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .trim(from: from, to: to)
            .stroke(Color.primary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}

// one saved layout: its miniature, its name with the menu beside it, and what is in it
struct SavedLayoutTile: View {
    let snapshot: Snapshot
    @Bindable var model: SavedStatesModel
    // the travelling copy stands in for this one while it is on its way out or back
    var previewHidden = false
    var onOpen: (CGRect) -> Void = { _ in }

    @State private var previewFrame: CGRect = .zero

    var body: some View {
        // the menu is drawn above the tile, so a click on it never reaches the tile
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                // the miniature carries its own outlines, the tile itself has no box
                LayoutThumbnail(snapshot: snapshot,
                                fit: CGSize(width: PanelMetrics.tileWidth,
                                            height: PanelMetrics.tileThumbnailHeight))
                    .frame(width: PanelMetrics.tileWidth,
                           height: PanelMetrics.tileThumbnailHeight,
                           alignment: .leading)
                    .opacity(previewHidden ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(PanelSpace.panel))
                    } action: { frame in
                        previewFrame = frame
                    }
                HStack(spacing: 2) {
                    Text(SavedStatesFormat.displayName(snapshot))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if snapshot.completeness != .complete {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("some details were not saved")
                    }
                    Spacer(minLength: 18)
                }
            }
            .frame(width: PanelMetrics.tileWidth, height: PanelMetrics.tileHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(previewFrame) }
            .help(SavedStatesFormat.displayName(snapshot))

            menu
                .padding(.top, PanelMetrics.tileThumbnailHeight + 2)
        }
        .frame(width: PanelMetrics.tileWidth, height: PanelMetrics.tileHeight)
    }

    private var menu: some View {
        Menu {
            Button("Rename") { model.beginRename(snapshot.id) }
            Button("Delete") { model.confirmDelete(snapshot.id) }
                .disabled(!model.canDelete(snapshot.id))
            if let error = model.deleteError {
                Text(error)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.busy && !model.saving)
        .allowsHitTesting(!model.busy)
    }

}

enum SavedStatesFormat {
    static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }

    static func completeness(_ value: SnapshotCompleteness) -> String {
        switch value {
        case .complete: return "full capture"
        case .partial: return "partial capture"
        case .inconsistent: return "inconsistent capture"
        }
    }

    // the applications in the layout, in the order they were recorded, without repeats
    static func appNames(_ snapshot: Snapshot) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for window in snapshot.windows where seen.insert(window.appName).inserted {
            names.append(window.appName)
        }
        return names
    }

    static func apps(_ snapshot: Snapshot) -> String {
        let names = appNames(snapshot)
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }

    // a saved layout is known by its name, and an unnamed one by what is in it
    // nothing is written back to the file to give it this label
    static func displayName(_ snapshot: Snapshot) -> String {
        if let name = snapshot.name, !name.isEmpty { return name }
        let names = appNames(snapshot)
        guard !names.isEmpty else { return "Empty layout" }
        let shown = names.prefix(2).joined(separator: " + ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }
}
