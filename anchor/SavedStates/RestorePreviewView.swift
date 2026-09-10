import SwiftUI

// the preview is the confirmation step
// it reads a plan that has already been built and never starts anything by itself
struct RestorePreviewView: View {
    @Bindable var model: SavedStatesModel
    @State private var showAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.planning && model.plan == nil {
                ProgressView("Reading the saved state")
                    .padding(20)
                    .frame(maxWidth: .infinity)
            } else if let plan = model.plan {
                PanelScroll(maxHeight: PanelMetrics.viewport(reserving: 260)) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(plan)
                        if let notice = model.planRebuiltNotice {
                            Label(notice, systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        destination(plan)
                        notes(plan)
                        Divider()
                        Toggle("Show full addresses and paths", isOn: $showAddresses)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        ForEach(plan.groups) { group in
                            groupView(group)
                        }
                        Divider()
                        OutgoingScopeView(model: model)
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                Divider()
                actions(plan)
            } else if let error = model.planError {
                Text(error).font(.callout).foregroundStyle(.orange).padding(14)
            }
        }
    }

    private func heading(_ plan: RestorePlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(plan.snapshotName ?? SavedStatesFormat.date(plan.snapshotCreatedAt))
                .font(.headline)
            Text(plan.headline).font(.caption).foregroundStyle(.secondary)
            Text("saved \(SavedStatesFormat.date(plan.snapshotCreatedAt)) · \(SavedStatesFormat.completeness(plan.completeness))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func destination(_ plan: RestorePlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Destination: \(plan.destination.name)").font(.callout)
            Text("chosen because: \(plan.destination.selectionSource)")
            if let detail = plan.destination.selectionDetail {
                Text("decided by: \(detail)").lineLimit(2)
            }
            Text("usable area \(RectRecord(plan.destination.visibleFrame).summary), saved on \(plan.source.name) with usable area \(plan.source.visibleFrame.summary)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func notes(_ plan: RestorePlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(plan.notes) { note in
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(color(note.severity))
            }
        }
    }

    private func color(_ severity: PlanNoteSeverity) -> Color {
        switch severity {
        case .note: return .secondary
        case .limitation: return .orange
        case .blocker: return .red
        }
    }

    private func groupView(_ group: RestoreGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.appName).font(.callout).bold()
                Text(group.appDetail).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(group.windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: window.isActionable ? "macwindow.badge.plus" : "macwindow.badge.minus")
                        Text(window.title ?? window.appName).lineLimit(1)
                        Spacer()
                        if window.isActionable {
                            Toggle("Leave out", isOn: leaveOut(window))
                                .toggleStyle(.checkbox)
                                .font(.caption2)
                                .disabled(model.busy)
                        }
                    }
                    .font(.caption)
                    Text(window.action.summary)
                        .font(.caption2)
                        .foregroundStyle(window.isActionable ? Color.secondary : Color.orange)
                    if window.isActionable {
                        Text(window.layout.summary).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(window.items) { item in
                        itemView(item)
                    }
                    ForEach(Array(window.limitations.enumerated()), id: \.offset) { _, note in
                        Text("limitation: \(note)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemView(_ item: RestorePlanItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: item.status.isActionable ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(item.status.isActionable ? Color.green : Color.orange)
                Text("\(item.kind.label): \(item.title)").lineLimit(1)
            }
            Text(item.status.label)
                .foregroundStyle(item.status.isActionable ? Color.secondary : Color.orange)
            if showAddresses, let detail = item.detail {
                Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.caption2)
        .padding(.leading, 6)
    }

    // leaving a window out changes this operation only, never the saved state
    private func leaveOut(_ window: RestorePlanWindow) -> Binding<Bool> {
        Binding(get: { model.replacement.excludedIncoming.contains(window.id) },
                set: { model.replacement.exclude(incoming: window.id, $0) })
    }

    private func actions(_ plan: RestorePlan) -> some View {
        ReplacementConfirmView(model: model, plan: plan)
    }
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
