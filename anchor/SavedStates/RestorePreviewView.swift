import SwiftUI

// the layout screen of one saved state, inside the same box the grid fills
// it reads a plan that has already been built and never starts anything by itself
struct RestorePreviewView: View {
    @Bindable var model: SavedStatesModel
    // the travelling copy stands in for this one while it is on its way here
    var previewHidden = false
    var transitionComplete = true
    var onPreviewFrame: (CGRect) -> Void = { _ in }
    var onBack: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionsVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            middle
            actions
        }
        .padding(12)
        .frame(width: PanelMetrics.contentWidth, height: PanelMetrics.panelHeight, alignment: .top)
    }

    private var snapshot: Snapshot? { model.selected }

    private var heading: some View {
        HStack(spacing: 6) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Saved layouts")
            Text(snapshot.map { SavedStatesFormat.displayName($0) } ?? "Saved layout")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.planning {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 20)
    }

    private var middle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot {
                    LayoutThumbnail(snapshot: snapshot,
                                    fit: CGSize(width: PanelMetrics.contentWidth - 24,
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
                warnings
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: PanelMetrics.detailMiddleHeight)
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
        ForEach(actionableNotes) { item in
            note(item.text, severity: item.severity)
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
                ReplacementConfirmView(model: model, plan: plan)
            } else {
                Color.clear
            }
        }
        .frame(height: 22)
        .opacity(actionsVisible ? 1 : 0)
        .allowsHitTesting(actionsVisible)
        .onChange(of: actionsReady) { _, ready in
            withAnimation(.easeIn(duration: reduceMotion ? 0 : 0.18)) { actionsVisible = ready }
        }
        .onAppear {
            guard actionsReady else { return }
            withAnimation(.easeIn(duration: reduceMotion ? 0 : 0.18)) { actionsVisible = true }
        }
        .onDisappear { actionsVisible = false }
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
}

// one coordinate space for the panel, so a card and the layout screen can be measured
// against the same origin
enum PanelSpace {
    static let panel = "anchor.panel"
}

// what the run is doing and what it did, kept until the next run replaces it
struct RestoreProgressView: View {
    @Bindable var model: SavedStatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScroll(maxHeight: PanelMetrics.viewport(reserving: 200)) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(title).font(.headline)
                            Spacer()
                            Button("Copy Report") { copy(model.restore.report) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        Text(model.restore.summary).font(.caption).foregroundStyle(.secondary)
                        Text("operation \(model.restore.log.id) · launch requests \(model.restore.launchRequests)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    RestoreReportList(restore: model.restore)
                }
                .padding(14)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                if model.restore.isRunning {
                    Button("Cancel") { model.restore.cancel() }
                    Text("already opened windows stay open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Saved States") { model.backToHome() }
                    Spacer()
                    Text("nothing was closed or replaced")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private var title: String {
        switch model.restore.phase {
        case .idle: return "Nothing has run yet"
        case .running: return "Reopening \(model.restore.snapshotName ?? "the saved state")"
        case .finished: return "Finished"
        case .cancelled: return "Cancelled"
        }
    }

}

// one line per window of a run, shared by the development reopen and by a replacement
struct RestoreReportList: View {
    let restore: RestoreCoordinator

    var body: some View {
        ForEach(restore.reports) { report in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: icon(report.state))
                        .foregroundStyle(tint(report.state))
                    Text(report.title ?? report.appName).font(.callout).lineLimit(1)
                    Text(report.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                Text(report.summary).font(.caption2).foregroundStyle(.secondary)
                if let evidence = report.evidence {
                    Text(evidence).font(.caption2).foregroundStyle(.secondary)
                }
                if let placement = report.placement {
                    Text("layout: \(placement)").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(report.items) { item in
                    Text("\(item.kind.label): \(item.title) — \(item.state.rawValue)\(item.detail.map { ", \($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(item.state == .failed ? Color.orange : Color.secondary)
                        .padding(.leading, 8)
                }
            }
        }
    }

    private func icon(_ state: RestoreCoordinator.WindowState) -> String {
        switch state {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .opened: return "checkmark.circle"
        case .reused: return "arrow.uturn.left.circle"
        case .skipped: return "minus.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func tint(_ state: RestoreCoordinator.WindowState) -> Color {
        switch state {
        case .opened, .reused: return .green
        case .failed: return .orange
        case .skipped, .cancelled: return .secondary
        default: return .secondary
        }
    }
}
