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

// why a switch is refused, read by the buttons and by the screen that shows them
@MainActor
enum SwitchBlocker {
    // what this operation would actually reopen, after anything the user left out
    static func incomingCount(model: SavedStatesModel, plan: RestorePlan) -> Int {
        plan.excluding(windowIDs: model.replacement.excludedIncoming).actionableWindowCount
    }

    static func ready(model: SavedStatesModel, plan: RestorePlan) -> Bool {
        !model.busy && model.replacement.canConfirm && incomingCount(model: model, plan: plan) > 0
    }

    static func reason(model: SavedStatesModel, plan: RestorePlan) -> String? {
        guard let preflight = model.replacement.preflight else { return nil }
        if !preflight.accessibilityGranted {
            return "grant accessibility before switching, anchor cannot close a window without it"
        }
        let stuck = preflight.blocking(excluding: model.replacement.excludedOutgoing)
        if !stuck.isEmpty {
            return "keep \(stuck.count) windows open, or anchor cannot call this a switch. it never quits an application to close a window"
        }
        if incomingCount(model: model, plan: plan) == 0 {
            return "there is nothing to open from this saved state, so anchor will not close anything. this is what a state saved on an ide welcome screen looks like"
        }
        return nil
    }
}

// the three things that can be done with a saved state, and the only place a
// replacement starts
struct ReplacementConfirmView: View {
    @Bindable var model: SavedStatesModel
    let plan: RestorePlan
    var keyboardAction: Int?

    var body: some View {
        VStack(spacing: 6) {
            Button { model.requestExecute() } label: {
                Text("Open")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(PanelActionStyle(prominent: true))
                .overlay { selectionOutline(0) }
                .disabled(model.busy || plan.actionableWindowCount == 0)
                .help("Opens the saved layout and closes nothing")
            Button { model.requestReplacement(.saveThenReplace) } label: {
                Text("Save & Switch").frame(maxWidth: .infinity)
            }
                .buttonStyle(PanelActionStyle())
                .disabled(!ready)
                .help(SwitchBlocker.reason(model: model, plan: plan) ?? "Save the current layout, then switch")
                .overlay { selectionOutline(1) }
            Button { model.requestReplacement(.replaceWithoutSaving) } label: {
                Text("Switch").frame(maxWidth: .infinity)
            }
                .buttonStyle(PanelActionStyle())
                .disabled(!ready)
                .help(SwitchBlocker.reason(model: model, plan: plan) ?? "Closes the current layout without saving it, then opens this layout")
                .accessibilityLabel("Switch without saving")
                .overlay { selectionOutline(2) }
        }
        .font(.caption)
        .controlSize(.small)
    }

    private var ready: Bool { SwitchBlocker.ready(model: model, plan: plan) }

    @ViewBuilder
    private func selectionOutline(_ index: Int) -> some View {
        if keyboardAction == index {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

// the only switch screen that needs a decision rather than a report
struct ReplacementProgressView: View {
    @Bindable var model: SavedStatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Some details weren’t saved", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Review what’s missing before closing your current windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                if let partial = model.replacement.partialCapture {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(partial.summary)
                        ForEach(Array(partial.omissions.enumerated()), id: \.offset) { _, text in
                            Text(text)
                        }
                        Text("Unsaved documents and running terminal sessions are not backed up.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 8) {
                Button("Cancel Switch") {
                    model.replacement.cancel()
                    model.backToHome()
                }
                .buttonStyle(PanelActionStyle(prominent: true))
                Button("Close Anyway") { model.requestPartialCaptureDecision() }
                    .buttonStyle(PanelActionStyle())
            }
        }
        .padding(12)
        .frame(height: PanelMetrics.panelHeight - PanelMetrics.barHeight - 36)
    }
}
