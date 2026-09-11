import AppKit
import Combine
import SwiftUI

// the first launch window, and the one settings, permissions opens later
// every permission is explained in its own words, asked for through the flow macos
// supports for it, and none of them is required to use anchor
struct PermissionsSetupView: View {
    @Bindable var model: PermissionsSetupModel
    @Bindable var savedStates: SavedStatesModel
    var onContinue: () -> Void = {}

    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    accessibility
                    Divider()
                    automation
                    Divider()
                    screenRecording
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 520)
        .task { await refresh() }
        // coming back from system settings makes anchor active again, which is the moment
        // a granted permission becomes visible here
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private func refresh() async {
        refreshing = true
        await model.refresh()
        refreshing = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anchor Setup").font(.title2).bold()
            Text("""
                 Anchor saves the windows on one display and opens them again later. \
                 These permissions decide how much of that it can do.
                 """)
            Text("Nothing here is required. Anchor runs with whatever you allow, and you can come back to this window from the panel's Settings menu, under Permissions.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Accessibility", granted: model.accessibilityGranted)
            Text("""
                 Anchor reads window titles and positions with it, and it is what moves windows \
                 back into place when you open a saved layout. Without it a layout still saves, \
                 but with no titles and nothing to place windows with.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Grant Accessibility") { model.requestAccessibility() }
                    .disabled(model.accessibilityGranted)
                Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    .buttonStyle(.link)
            }
            Text("macOS asks once, and the switch itself is turned on in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var automation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Automation").font(.headline)
                Spacer(minLength: 0)
                // the only way back for one that was allowed and is now to be withdrawn
                Button("Open Settings") { Permissions.openAutomationSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text("""
                 Anchor asks Safari, Chrome, Terminal, iTerm2 and Xcode about their own open \
                 windows, so a saved layout can carry tabs and working directories rather than \
                 rectangles alone. macOS grants this one application at a time.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Anchor only asks about an application that is already open, and never opens one to raise a prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(model.scriptedApps, id: \.kind) { app in
                    automationRow(app)
                }
            }
            .padding(.top, 2)
        }
    }

    private func automationRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.isGranted(app) ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(model.isGranted(app) ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.kind.displayName).font(.callout)
                Text(model.status(app)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.asking.contains(app.kind) {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask") {
                    Task { await model.requestAutomation(for: app.kind) }
                }
                .disabled(!model.canAsk(app))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var screenRecording: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Screen Recording", granted: model.screenRecordingGranted)
            Text("""
                 When you save a layout, Anchor takes one picture of that display, shrinks and \
                 blurs it in memory, and keeps only the blurred version beside the layout. The \
                 sharp picture is never written down, and Anchor's own windows are left out of it.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Without it, saving works exactly the same and a layout's preview is drawn from its window rectangles instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Grant Screen Recording") {
                    Task { await model.requestScreenRecording() }
                }
                .disabled(model.screenRecordingGranted)
                Button("Open Settings") { Permissions.openScreenRecordingSettings() }
                    .buttonStyle(.link)
            }
            Text("macOS may need Anchor to be quit and opened again after this one is allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let issue = savedStates.thumbnailIssue, !issue.needsPermission {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func heading(_ title: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Label(granted ? "granted" : "not granted",
                  systemImage: granted ? "checkmark.circle" : "exclamationmark.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Check Again") { Task { await refresh() } }
                .disabled(refreshing)
            if refreshing {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Continue") { onContinue() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
