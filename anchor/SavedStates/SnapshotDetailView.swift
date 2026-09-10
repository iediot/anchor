import SwiftUI

// one saved state inside the panel
// reopening is never started from here, it goes through the preview first
struct SnapshotDetailView: View {
    let snapshot: Snapshot
    @Bindable var model: SavedStatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            Button {
                model.requestPreview(for: snapshot.id)
            } label: {
                Label(model.planning ? "Reading…" : "Preview Reopening", systemImage: "eye")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(model.busy)
            Text("The preview reads saved records and local paths only. Nothing is opened until you confirm it there.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            display
            if !snapshot.issues.isEmpty {
                DisclosureGroup("Capture notes (\(snapshot.issues.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snapshot.issues) { issue in
                            Text("\(issue.scope): \(issue.message)")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .note ? Color.secondary : Color.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            Divider()
            windows
            if !snapshot.adapters.isEmpty {
                DisclosureGroup("Adapters (\(snapshot.adapters.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snapshot.adapters) { run in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(run.app): \(run.outcome), \(String(format: "%.2fs", run.duration))")
                                Text("matching basis: \(run.matchingBasis ?? "not recorded")")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
        .textSelection(.enabled)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SavedStatesFormat.date(snapshot.createdAt)).font(.headline)
            HStack(spacing: 6) {
                TextField("Optional name", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { model.renameSelected() }
            }
            if let error = model.renameError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Label(snapshot.completeness.label,
                  systemImage: snapshot.completeness == .complete ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(snapshot.completeness == .complete ? .green : .orange)
            Text("\(snapshot.windows.count) windows, \(snapshot.capturedResourceCount) with captured resources, \(snapshot.omittedResourceCount) with omissions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Saved on \(snapshot.display.name)\(snapshot.display.isPrimary ? " (primary)" : "")").font(.callout)
            Text("chosen because: \(snapshot.display.selectionSource)")
            Text("frame \(snapshot.display.frame.summary) · usable \(snapshot.display.visibleFrame.summary)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var windows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows").font(.callout).bold()
            ForEach(snapshot.windows) { window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: window.resources.status.isOmission ? "macwindow.badge.minus" : "macwindow")
                        Text(window.appName).bold()
                        Text(window.title ?? "no title").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout)
                    Text("\(window.resources.kind.label) · \(window.resources.status.label)")
                        .font(.caption)
                        .foregroundStyle(window.resources.status.isOmission ? Color.orange : Color.secondary)
                    Text("frame \(window.appKitFrame.summary) · \(window.fullScreenSignal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    resourceSummary(window.resources)
                    ForEach(Array(window.limitations.enumerated()), id: \.offset) { _, note in
                        Text("limitation: \(note)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resourceSummary(_ resources: WindowResources) -> some View {
        if let browser = resources.browser {
            DisclosureGroup("\(browser.tabs.count) tabs") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(browser.tabs.enumerated()), id: \.offset) { _, tab in
                        Text("\(tab.index)\(tab.index == browser.selectedTabIndex ? " (selected)" : ""): \(tab.title ?? "no title") — \(tab.url ?? tab.issue ?? "no address")")
                            .font(.caption2)
                            .foregroundStyle(tab.issue == nil ? Color.secondary : Color.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        if let terminal = resources.terminal {
            ForEach(Array(terminal.tabs.enumerated()), id: \.offset) { _, tab in
                Text("session \(tab.index): \(tab.directory ?? tab.issue ?? "no directory")")
                    .font(.caption2)
                    .foregroundStyle(tab.directory == nil ? Color.orange : Color.secondary)
            }
        }
        if let ide = resources.jetBrains {
            Text("project: \(ide.projectPath ?? "not identified")").font(.caption2).foregroundStyle(.secondary)
            if !ide.editorFiles.isEmpty {
                Text("persisted editor files: \(ide.editorFiles.count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let xcode = resources.xcode {
            Text("project: \(xcode.workingDocumentPath ?? xcode.workingDocumentIssue ?? "not identified")")
                .font(.caption2).foregroundStyle(.secondary)
            if let file = xcode.accessibilityActiveFile {
                Text("active file: \(file)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
