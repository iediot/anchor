import SwiftUI

// compact detail for one saved state
// there is no restore control here, restoration does not exist yet and must not be implied
struct SnapshotDetailView: View {
    let snapshot: Snapshot
    @Bindable var model: SavedStatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading
            Divider()
            displaySection
            if !snapshot.issues.isEmpty {
                Divider()
                issuesSection
            }
            Divider()
            windowsSection
            if !snapshot.adapters.isEmpty {
                Divider()
                adapterSection
            }
            Divider()
            Text("Anchor cannot reopen a saved state yet. This build captures and browses snapshots only, so nothing here can be restored, replaced or closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SavedStatesFormat.date(snapshot.createdAt)).font(.title3).bold()
            HStack {
                TextField("Optional name", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Save Name") { model.renameSelected() }
            }
            if let error = model.renameError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Label(snapshot.completeness.label,
                  systemImage: snapshot.completeness == .complete ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(snapshot.completeness == .complete ? .green : .orange)
            Text("\(snapshot.windows.count) windows, \(snapshot.capturedResourceCount) with captured resources, \(snapshot.omittedResourceCount) with omissions")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("schema version \(snapshot.schemaVersion) · \(snapshot.host.operatingSystem) · anchor \(snapshot.host.anchorVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display").font(.headline)
            LabeledContent("Display", value: "\(snapshot.display.name)\(snapshot.display.isPrimary ? " (primary)" : "")")
            LabeledContent("Chosen because", value: snapshot.display.selectionSource)
            if let detail = snapshot.display.selectionDetail {
                LabeledContent("Decided by", value: detail)
            }
            LabeledContent("Frame", value: snapshot.display.frame.summary)
            LabeledContent("Usable frame", value: snapshot.display.visibleFrame.summary)
            LabeledContent("Backing scale", value: String(format: "%.1fx", snapshot.display.backingScale))
            LabeledContent("Displays attached", value: "\(snapshot.display.attachedDisplays)")
        }
    }

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Capture notes").font(.headline)
            ForEach(snapshot.issues) { issue in
                Text("\(issue.scope): \(issue.message)")
                    .font(.callout)
                    .foregroundStyle(issue.severity == .note ? Color.secondary : Color.orange)
            }
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Windows").font(.headline)
            ForEach(snapshot.windows) { window in
                windowRow(window)
            }
        }
    }

    private func windowRow(_ window: WindowRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: window.resources.status.isOmission ? "macwindow.badge.minus" : "macwindow")
                Text(window.appName).bold()
                Text(window.title ?? "no title available").foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(window.resources.kind.label) · \(window.resources.status.label)")
                .font(.caption)
                .foregroundStyle(window.resources.status.isOmission ? Color.orange : Color.secondary)
            Text("frame \(window.appKitFrame.summary) · relative to display \(window.displayRelativeFrame.summary) · \(window.fullScreenSignal)")
                .font(.caption)
                .foregroundStyle(.secondary)
            resourceDetail(window.resources)
            ForEach(Array(window.limitations.enumerated()), id: \.offset) { _, note in
                Text("limitation: \(note)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func resourceDetail(_ resources: WindowResources) -> some View {
        if let browser = resources.browser {
            ForEach(Array(browser.tabs.enumerated()), id: \.offset) { _, tab in
                Text("tab \(tab.index)\(tab.index == browser.selectedTabIndex ? " (selected)" : ""): \(tab.title ?? "no title") — \(tab.url ?? tab.issue ?? "no address")")
                    .font(.caption)
                    .foregroundStyle(tab.issue == nil ? Color.secondary : Color.orange)
            }
        }
        if let terminal = resources.terminal {
            ForEach(Array(terminal.tabs.enumerated()), id: \.offset) { _, tab in
                Text("tab \(tab.index)\(tab.selected == true ? " (selected)" : ""): \(tab.directory ?? "no directory") via \(tab.directorySource ?? tab.issue ?? "unresolved")")
                    .font(.caption)
                    .foregroundStyle(tab.directory == nil ? Color.orange : Color.secondary)
            }
        }
        if let ide = resources.jetBrains {
            Text("project: \(ide.projectPath ?? "not identified") · \(ide.matchProvenance)")
                .font(.caption).foregroundStyle(.secondary)
            if !ide.ambiguousCandidates.isEmpty {
                Text("candidates: \(ide.ambiguousCandidates.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("editor files: \(ide.editorFiles.isEmpty ? ide.editorFileState : ide.editorFiles.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let xcode = resources.xcode {
            Text("project: \(xcode.workingDocumentPath ?? xcode.workingDocumentIssue ?? "not identified")")
                .font(.caption).foregroundStyle(.secondary)
            Text("active file from accessibility: \(xcode.accessibilityActiveFile ?? "none")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var adapterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Adapters").font(.headline)
            ForEach(snapshot.adapters) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(run.app): \(run.outcome) · \(run.windowsCaptured) of \(run.windowsAttempted) windows · \(String(format: "%.2fs", run.duration)) from \(SavedStatesFormat.date(run.startedAt))")
                    Text("matching basis: \(run.matchingBasis ?? "not recorded")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
