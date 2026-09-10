import SwiftUI

struct DiagnosticsView: View {
    @Bindable var model: DiagnosticsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissionSection
                Divider()
                targetSection
                Divider()
                windowSection
                Divider()
                integrationSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // enabled on the whole tree so every result line can be selected and copied by hand
            .textSelection(.enabled)
        }
        .frame(minWidth: 640, minHeight: 520)
        .task {
            model.refreshPermissions()
            await model.refreshAutomationStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Anchor diagnostics").font(.title3).bold()
            Spacer()
            if model.copiedAt != nil {
                Text("Copied").font(.caption).foregroundStyle(.secondary)
            }
            Button("Copy Diagnostics") { model.copyReport() }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions").font(.headline)
            HStack(spacing: 10) {
                Label(model.accessibilityGranted ? "Accessibility granted" : "Accessibility not granted",
                      systemImage: model.accessibilityGranted ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.accessibilityGranted ? .green : .orange)
                if !model.accessibilityGranted {
                    Button("Request") { Permissions.requestAccessibility() }
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                }
                Button("Recheck") { model.refreshPermissions() }
            }
            Label(model.screenRecordingGranted
                    ? "Screen Recording granted, the window server supplies window names"
                    : "Screen Recording not granted, window names come from Accessibility instead",
                  systemImage: "text.viewfinder")
                .foregroundStyle(.secondary)
            if !model.accessibilityGranted {
                Text("Anchor still lists windows and displays without Accessibility. Window titles, fullscreen state and later window moves need it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target display").font(.headline)
                Spacer()
                Button(model.scanning ? "Inspecting…" : "Inspect Current Screen") { model.inspect() }
                    .disabled(model.scanning)
            }
            if let scan = model.scan {
                let target = scan.target
                LabeledContent("Display", value: "\(target.name)\(target.isPrimary ? " (primary)" : "")")
                LabeledContent("Chosen because", value: target.originDescription)
                if let decidedBy = target.decidedBy {
                    LabeledContent("Decided by", value: decidedBy)
                }
                LabeledContent("Frame", value: ScreenGeometry.describe(target.frame))
                LabeledContent("Usable frame", value: ScreenGeometry.describe(target.visibleFrame))
                LabeledContent("Backing scale", value: String(format: "%.1fx", target.backingScale))
                LabeledContent("Displays attached", value: "\(NSScreen.screens.count)")
                LabeledContent("Scanned at", value: ProbeEvidence.stamp(scan.capturedAt))
                if scan.lostPinnedDisplay {
                    Text("The display selected earlier is no longer attached, so the destination was resolved again.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("No inspection has been run yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows").font(.headline)
            if let scan = model.scan {
                Text("\(scan.inScope.count) in scope, \(scan.outOfScope.count) excluded. Inspection is read only, nothing was moved or closed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(scan.inScope) { window in
                    windowRow(window, included: true)
                }
                if !scan.outOfScope.isEmpty {
                    DisclosureGroup("Excluded windows") {
                        ForEach(scan.outOfScope) { window in
                            windowRow(window, included: false)
                        }
                    }
                }
            } else {
                Text("No inspection has been run yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func windowRow(_ window: InspectedWindow, included: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: included ? "macwindow" : "macwindow.badge.minus")
                    .foregroundStyle(included ? .primary : .secondary)
                Text(window.ownerName).bold()
                Text(window.title ?? "no title available")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("id \(window.id) · title via \(window.titleSource.rawValue) · \(ScreenGeometry.describe(window.appKitFrame)) · \(window.screenName ?? "unknown display")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let path = window.documentPath {
                Text("accessibility document \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(window.availability.label) · \(window.fullScreen.rawValue) · \(window.scopeReason)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var integrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Integrations").font(.headline)
                Spacer()
                Button("Open Automation Settings") { Permissions.openAutomationSettings() }
            }
            Text("Each probe asks for Automation access for that one app and never launches an app that is not already running.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(model.apps, id: \.kind) { app in
                integrationRow(app)
            }
        }
    }

    private func integrationRow(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(app.kind.displayName).bold()
                Text(status(app)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.busy.contains(app.kind) ? "Probing…" : "Probe") {
                    Task { await model.probe(app.kind) }
                }
                .disabled(!app.isInstalled || !app.isRunning || model.busy.contains(app.kind))
            }
            if let result = model.probes[app.kind] {
                Text(result.succeeded ? result.summary : "failed: \(result.summary)")
                    .font(.callout)
                    .foregroundStyle(result.succeeded ? Color.primary : Color.orange)
                if let evidence = result.evidence {
                    ForEach(Array(evidence.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(result.rows) { row in
                    Text("\(row.label): \(row.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                    Text("note: \(note)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ app: InstalledApp) -> String {
        guard app.isInstalled else { return "not installed, untested" }
        var parts = ["version \(app.version ?? "unknown")", app.isRunning ? "running" : "not running"]
        if app.kind.usesAppleEvents {
            parts.append("automation \(model.automation[app.kind]?.label ?? "unknown")")
        } else {
            parts.append("no scripting dictionary, accessibility only")
        }
        return parts.joined(separator: " · ")
    }
}
