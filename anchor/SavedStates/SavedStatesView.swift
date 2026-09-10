import SwiftUI

struct SavedStatesView: View {
    @Bindable var model: SavedStatesModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.saving ? "Saving…" : "Save Current State") { model.requestSave() }
                    .disabled(model.saving)
            }
        }
        .sheet(isPresented: $model.browserDisclosurePending) { disclosure }
        .task { model.reload() }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.selected?.id },
                                set: { if let id = $0 { model.select(id) } })) {
            if model.snapshots.isEmpty {
                Text("No saved states yet.").foregroundStyle(.secondary)
            }
            ForEach(model.snapshots) { snapshot in
                SnapshotRow(snapshot: snapshot).tag(snapshot.id)
            }
            if !model.failures.isEmpty {
                Section("Unreadable files") {
                    ForEach(model.failures) { failure in
                        FailureRow(failure: failure)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.storeError {
                    Text("Snapshots cannot be stored: \(error)").foregroundStyle(.orange)
                }
                if let outcome = model.lastOutcome {
                    resultBanner(outcome)
                }
                if let snapshot = model.selected {
                    SnapshotDetailView(snapshot: snapshot, model: model)
                } else {
                    Text("Choose Save Current State to capture the supported context on the screen you were last using.")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text("Snapshots are stored at \(model.storeLocation). They are never included in copied diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private func resultBanner(_ outcome: CaptureCoordinator.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = outcome.storeError {
                Label("Nothing was saved: \(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label(outcome.summary, systemImage: "checkmark.circle")
            }
            Text("No window was moved, closed or opened. Capture is read only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saving browser tabs").font(.headline)
            Text("""
                 Anchor stores the full address and title of every tab in the Safari and Chrome windows \
                 on the screen you are saving. Snapshots stay on this Mac, in your Application Support folder, \
                 and are never added to logs or to copied diagnostics.
                 """)
            Text(BrowserCapture.privateDetectionLimitation)
                .foregroundStyle(.orange)
            Text("Anchor asks this once. You can change it later from the menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.cancelDisclosure() }
                Spacer()
                Button("Save Without Browser Tabs") { model.answerDisclosure(includeBrowserTabs: false) }
                Button("Save With Browser Tabs") { model.answerDisclosure(includeBrowserTabs: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct SnapshotRow: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).bold()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Text(SavedStatesFormat.completeness(snapshot.completeness))
                .font(.caption2)
                .foregroundStyle(snapshot.completeness == .complete ? Color.secondary : Color.orange)
        }
    }

    private var title: String {
        snapshot.name ?? SavedStatesFormat.date(snapshot.createdAt)
    }

    private var subtitle: String {
        let windows = "\(snapshot.windows.count) windows"
        guard snapshot.name != nil else { return windows }
        return "\(SavedStatesFormat.date(snapshot.createdAt)) · \(windows)"
    }
}

private struct FailureRow: View {
    let failure: SnapshotLoadFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(failure.header.map { SavedStatesFormat.date($0.createdAt) } ?? failure.fileName)
                .font(.callout)
            Text(failure.reason).font(.caption).foregroundStyle(.orange)
        }
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
