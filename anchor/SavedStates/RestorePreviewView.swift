import SwiftUI

// the layout screen of one saved state, inside the same box the grid fills
// it reads a plan that has already been built and never starts anything by itself
struct RestorePreviewView: View {
    @Bindable var model: SavedStatesModel
    // the travelling copy stands in for this one while it is on its way here
    var previewHidden = false
    var transitionComplete = true
    var keyboardAction: Int?
    var onPreviewFrame: (CGRect) -> Void = { _ in }
    var onBack: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingWarnings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            HStack(alignment: .center, spacing: 12) {
                middle
                    .frame(width: previewColumnWidth)
                actions
                    .frame(width: 132)
                    .offset(x: -(previewColumnWidth - previewWidth) / 2 + 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        // the back chevron lands on the same line the grid's cog does
        .padding(.top, PanelMetrics.headInset)
        .frame(width: PanelMetrics.contentWidth, height: PanelMetrics.panelHeight, alignment: .top)
    }

    private var snapshot: Snapshot? { model.selected }
    private var previewColumnWidth: CGFloat { PanelMetrics.contentWidth - 168 }

    private var previewWidth: CGFloat {
        let frame = snapshot?.display.frame.cgRect
        let aspect: CGFloat
        if let frame, frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 {
            aspect = frame.width / frame.height
        } else {
            aspect = 1.6
        }
        return min(previewColumnWidth, PanelMetrics.detailMiddleHeight * aspect)
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.065), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Saved layouts")
            Text(snapshot.map { SavedStatesFormat.displayName($0) } ?? "Saved layout")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hasWarnings {
                Button {
                    showingWarnings.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(switchReason ?? "Review restoration notes")
                .accessibilityLabel(switchReason ?? "Review restoration notes")
                .popover(isPresented: $showingWarnings) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            warnings
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: 320, height: 220)
                }
            }
            if model.planning {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: PanelMetrics.headControl)
    }

    private var middle: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot {
                    LayoutThumbnail(snapshot: snapshot,
                                    fit: CGSize(width: previewWidth,
                                                height: PanelMetrics.detailMiddleHeight),
                                    backdrop: model.thumbnailImage(for: snapshot.id))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(previewHidden ? 0 : 1)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(PanelSpace.panel))
                        } action: { frame in
                            onPreviewFrame(frame)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: PanelMetrics.detailMiddleHeight)
    }

    private var switchReason: String? {
        guard let plan = model.plan else { return nil }
        return SwitchBlocker.reason(model: model, plan: plan)
    }

    private var hasWarnings: Bool {
        model.planRebuiltNotice != nil || model.planError != nil
            || actionableNotes.contains { $0.severity == .blocker } || switchReason != nil
    }

    // routine detail belongs to the record screen, what stays here is what a person has
    // to act on before anything opens or closes
    @ViewBuilder
    private var warnings: some View {
        if let notice = model.planRebuiltNotice {
            note(notice, severity: .limitation)
        }
        if let error = model.planError {
            note(error, severity: .blocker)
        }
        ForEach(actionableNotes.filter { $0.severity == .blocker }) { item in
            note(item.text, severity: item.severity)
        }
        let limitations = actionableNotes.filter { $0.severity == .limitation }
        if !limitations.isEmpty {
            DisclosureGroup("\(limitations.count) restoration \(limitations.count == 1 ? "note" : "notes")") {
                ForEach(limitations) { item in note(item.text, severity: item.severity) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        // the reason a switch is refused, never left to a tooltip
        if let plan = model.plan, let reason = SwitchBlocker.reason(model: model, plan: plan) {
            note(reason, severity: .limitation)
        }
        // the only decision that cannot be skipped, shown when anchor cannot close
        // something the switch would have to close
        if requiresOutgoingChoice {
            OutgoingScopeView(model: model)
                .font(.caption2)
        }
    }

    private var actionableNotes: [PlanNote] {
        (model.plan?.notes ?? []).filter { $0.severity != .note }
    }

    private var requiresOutgoingChoice: Bool {
        guard let preflight = model.replacement.preflight else { return false }
        return !preflight.blocking(excluding: model.replacement.excludedOutgoing).isEmpty
    }

    private func note(_ text: String, severity: PlanNoteSeverity) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(severity == .blocker ? Color.red : Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // the buttons wait for the travel to land and for the screen to be read, and their
    // row holds its height the whole time so nothing moves when they arrive
    private var actions: some View {
        Group {
            if let plan = model.plan {
                ReplacementConfirmView(model: model, plan: plan, keyboardAction: keyboardAction)
            } else {
                Color.clear
            }
        }
        .frame(height: PanelMetrics.detailMiddleHeight)
        .opacity(actionsReady ? 1 : 0)
        .allowsHitTesting(actionsReady)
        .animation(.easeIn(duration: reduceMotion ? 0 : 0.18), value: actionsReady)
    }

    private var actionsReady: Bool {
        transitionComplete && !model.planning && model.plan != nil && model.replacement.preflight != nil
    }
}

// one short transition for opening a layout and coming back
enum PanelMotion {
    // the travelling preview
    static func navigation(_ reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.18 : 0.25)
    }

    // the two screens swapping underneath it
    static func crossfade(_ reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.18 : 0.25)
    }

    // the anchor dropping down its chain when the panel opens, settling with a small
    // bounce a little under half a second in
    static let anchorDrop = Animation.spring(response: 0.42, dampingFraction: 0.86)

    // the cards moving to where they belong after one is saved or deleted
    // with reduce motion they still move, they just do not spring
    static func grid(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.34, dampingFraction: 0.82)
    }
}

// one coordinate space for the panel, so a card and the layout screen can be measured
// against the same origin
enum PanelSpace {
    static let panel = "anchor.panel"
}
