import SwiftUI

// the attached surface under the menu bar icon
// one instance of the models, one place for save, history, detail, preview and outcome
struct AnchorPanelView: View {
    @Bindable var model: SavedStatesModel
    @Bindable var diagnostics: DiagnosticsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if case .home = model.route {
                Text("Anchor").font(.headline)
            } else {
                Button {
                    model.backToHome()
                } label: {
                    Label("Saved states", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
            }
            Spacer()
            if model.restore.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                    SnapshotDetailView(snapshot: snapshot, model: model).padding(14)
                }
            } else {
                missing
            }
        case .preview:
            RestorePreviewView(model: model)
        case .operation:
            RestoreProgressView(model: model)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.requestSave()
                } label: {
                    Label(model.saving ? "Saving…" : "Save Current State", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .controlSize(.large)
                .disabled(model.busy)
                Toggle("Include browser tabs", isOn: $model.includeBrowserTabs)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                if let outcome = model.lastOutcome {
                    outcomeBanner(outcome)
                }
                if !model.restore.reports.isEmpty {
                    Button {
                        model.show(.operation)
                    } label: {
                        Label(model.restore.isRunning ? "Reopening in progress…" : "Last reopen result",
                              systemImage: "arrow.uturn.up")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
                if let error = model.storeError {
                    Text("Snapshots cannot be stored: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14)

            Divider()
            Text("Saved states")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            if model.snapshots.isEmpty && model.failures.isEmpty {
                Text("Nothing saved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                // a plain stack, because a lazy one has no reliable height to measure
                PanelScroll(maxHeight: PanelMetrics.viewport(reserving: 340),
                            initialHeight: PanelMetrics.rowHeight * CGFloat(model.snapshots.count + model.failures.count) + 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.snapshots) { snapshot in
                            SnapshotRowButton(snapshot: snapshot) { model.show(.detail(snapshot.id)) }
                        }
                        ForEach(model.failures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.header.map { SavedStatesFormat.date($0.createdAt) } ?? failure.fileName)
                                    .font(.callout)
                                Text(failure.reason).font(.caption).foregroundStyle(.orange)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 4)
    }

    private var missing: some View {
        Text("That saved state is no longer in the list.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
    }

    private func outcomeBanner(_ outcome: CaptureCoordinator.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = outcome.storeError {
                Label("Nothing was saved: \(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label(outcome.summary, systemImage: "checkmark.circle")
            }
            Text("Saving reads only. No window was moved, closed or opened.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = model.destination {
                Text("Target display: \(target.name) · \(target.originDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Text(diagnostics.accessibilityGranted ? "Accessibility: granted" : "Accessibility: not granted")
                    .font(.caption)
                    .foregroundStyle(diagnostics.accessibilityGranted ? Color.secondary : Color.orange)
                if !diagnostics.accessibilityGranted {
                    Button("Grant…") { Permissions.requestAccessibility() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
            }
            HStack {
                Button("Diagnostics…") {
                    openWindow(id: DiagnosticsWindow.id)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
                Spacer()
                Button("Quit Anchor") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .padding(14)
    }
}

private struct SnapshotRowButton: View {
    let snapshot: Snapshot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name ?? SavedStatesFormat.date(snapshot.createdAt))
                        .font(.callout)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(snapshot.completeness == .complete ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let stamp = snapshot.name == nil ? "" : "\(SavedStatesFormat.date(snapshot.createdAt)) · "
        return "\(stamp)\(snapshot.windows.count) windows · \(SavedStatesFormat.completeness(snapshot.completeness))"
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
}
