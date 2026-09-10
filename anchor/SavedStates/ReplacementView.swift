import AppKit
import SwiftUI

// what replacing would close, read from the screen at preview time
struct OutgoingScopeView: View {
    @Bindable var model: SavedStatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What would close").font(.callout).bold()
            if let preflight = model.replacement.preflight {
                ForEach(preflight.notes) { note in
                    Text(note.text).font(.caption).foregroundStyle(color(note.severity))
                }
                if preflight.entries.isEmpty {
                    Text("nothing is open on this display, so replacing would only reopen the saved state")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(preflight.entries) { entry in
                    row(entry)
                }
            } else {
                Text("anchor has not read the current screen yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ entry: OutgoingEntry) -> some View {
        let excluded = model.replacement.excludedOutgoing.contains(entry.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: excluded ? "macwindow" : "macwindow.badge.minus")
                    .foregroundStyle(excluded ? Color.secondary : Color.orange)
                Text(entry.window.appName).bold()
                Text(entry.window.title ?? "no title").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("Keep open", isOn: Binding(get: { excluded },
                                                  set: { model.replacement.exclude(outgoing: entry.id, $0) }))
                    .toggleStyle(.checkbox)
                    .disabled(model.busy)
            }
            .font(.caption)
            Text(entry.support.label)
                .font(.caption2)
                .foregroundStyle(entry.support.isSupported ? Color.secondary : Color.orange)
        }
        .padding(.leading, 6)
    }

    private func color(_ severity: PlanNoteSeverity) -> Color {
        switch severity {
        case .note: return .secondary
        case .limitation: return .orange
        case .blocker: return .red
        }
    }
}

// the confirmation, and the only place a replacement starts
struct ReplacementConfirmView: View {
    @Bindable var model: SavedStatesModel
    let plan: RestorePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let blocker {
                Text(blocker).font(.caption2).foregroundStyle(.orange)
            }
            Button("Save Current State, Then Replace") {
                model.requestReplacement(.saveThenReplace)
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)
            .disabled(!ready)
            Button("Replace Without Saving") {
                model.requestReplacement(.replaceWithoutSaving)
            }
            .frame(maxWidth: .infinity)
            .disabled(!ready)
            Button("Cancel") { model.show(.detail(plan.snapshotID)) }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
            #if DEBUG
            Button("Development: reopen without closing anything") { model.requestExecute() }
                .buttonStyle(.link)
                .font(.caption2)
                .frame(maxWidth: .infinity)
                .disabled(model.busy || plan.actionableWindowCount == 0)
            #endif
        }
        .padding(14)
    }

    // what this operation would actually reopen, after anything the user left out
    private var incomingCount: Int {
        plan.excluding(windowIDs: model.replacement.excludedIncoming).actionableWindowCount
    }

    private var ready: Bool {
        !model.busy && model.replacement.canConfirm && incomingCount > 0
    }

    private var blocker: String? {
        guard let preflight = model.replacement.preflight else { return nil }
        if !preflight.accessibilityGranted {
            return "grant accessibility before replacing, anchor cannot close a window without it"
        }
        let stuck = preflight.blocking(excluding: model.replacement.excludedOutgoing)
        if !stuck.isEmpty {
            return "keep \(stuck.count) windows open, or anchor cannot call this a replacement. it never quits an application to close a window"
        }
        if incomingCount == 0 {
            return "there is nothing to reopen from this saved state, so anchor will not close anything. this is what a state saved on an ide welcome screen looks like"
        }
        return nil
    }
}

func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// one replacement while it runs and after it finishes
// it stays here until the next one, so closing this panel loses nothing
struct ReplacementProgressView: View {
    @Bindable var model: SavedStatesModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelScroll(maxHeight: PanelMetrics.viewport(reserving: 200)) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(title).font(.headline)
                            Spacer()
                            Button("Copy Report") { copy(model.replacement.report) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        Text(model.replacement.summary).font(.caption).foregroundStyle(.secondary)
                        Text("operation \(model.replacement.log.id) · \(model.replacement.log.counts), reopen launches \(model.restore.launchRequests)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = model.replacement.stopReason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let saved = model.replacement.outgoingSaveSummary {
                        Text("saved on the way out: \(saved)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let notice = model.replacement.snapshotNotice {
                        Text(notice).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let partial = model.replacement.partialCapture {
                        decision(partial)
                    }
                    closes
                    if !model.restore.reports.isEmpty {
                        Divider()
                        Text("Reopening").font(.callout).bold()
                        RestoreReportList(restore: model.restore)
                    }
                }
                .padding(14)
                .textSelection(.enabled)
            }
            Divider()
            footer
        }
    }

    private var closes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Closing").font(.callout).bold()
            Toggle("Show what happened to each window", isOn: $showDetails)
                .toggleStyle(.checkbox)
                .font(.caption2)
            ForEach(model.replacement.closeReports) { report in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: icon(report.state)).foregroundStyle(tint(report.state))
                        Text(report.appName).font(.callout)
                        Text(report.title ?? "no title").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(report.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    if showDetails {
                        Text(report.detail).font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
                    }
                }
            }
        }
    }

    // a save that came back with less than the screen held needs a decision of its own
    private func decision(_ partial: ReplacementCoordinator.PartialCapture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The save did not capture everything").font(.callout).bold()
            Text(SavedStatesFormat.completeness(partial.completeness))
                .font(.caption)
                .foregroundStyle(.orange)
            Text(partial.summary).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(partial.omissions.enumerated()), id: \.offset) { _, text in
                Text(text).font(.caption2).foregroundStyle(.orange)
            }
            Text("This is a record of where things were. It is not a copy of unsaved documents or of anything a terminal is running.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Close Those Windows Anyway") { model.requestPartialCaptureDecision() }
                .frame(maxWidth: .infinity)
            Button("Stop, Close Nothing") { model.replacement.cancel() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            if model.replacement.isRunning {
                Button("Cancel") { model.replacement.cancel() }
                Text("windows already closed stay closed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Saved States") { model.backToHome() }
                Spacer()
                Text("anchor never reopens what it closed as a rollback")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var title: String {
        switch model.replacement.stage {
        case .idle, .preflight: return "Nothing has run yet"
        case .saving: return "Saving the current state"
        case .awaitingCaptureDecision: return "Waiting for your decision"
        case .closing: return "Closing windows"
        case .reopening: return "Reopening the saved state"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        }
    }

    private func icon(_ state: ReplacementCoordinator.CloseReport.State) -> String {
        switch state {
        case .pending: return "clock"
        case .requested: return "arrow.triangle.2.circlepath"
        case .closed: return "checkmark.circle"
        case .alreadyGone: return "minus.circle"
        case .remaining, .refused: return "exclamationmark.circle"
        case .notReached: return "xmark.circle"
        }
    }

    private func tint(_ state: ReplacementCoordinator.CloseReport.State) -> Color {
        switch state {
        case .closed: return .green
        case .remaining, .refused: return .orange
        default: return .secondary
        }
    }
}
