import AppKit
import Combine
import SwiftUI

struct PermissionsSetupView: View {
    @Bindable var model: PermissionsSetupModel
    @Bindable var savedStates: SavedStatesModel
    @Bindable var shortcut: PanelShortcut
    var onContinue: () -> Void = {}

    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    HStack {
                        Toggle("Keyboard shortcut", isOn: $shortcut.enabled)
                        Spacer()
                        Button(shortcut.recording ? "Press shortcut…" : shortcut.label) {
                            if shortcut.recording {
                                shortcut.cancelRecording()
                            } else {
                                shortcut.beginRecording()
                            }
                        }
                        .disabled(!shortcut.enabled)
                        Button("Reset") { shortcut.reset() }
                            .disabled(shortcut.recording)
                    }
                    if let hint = shortcut.recordingHint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Opens or closes Anchor. Requires Accessibility. The shortcut also reaches the active app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Include browser tabs when saving", isOn: $savedStates.includeBrowserTabs)
                    Text("Full URLs and titles stay on this Mac. Private tabs may be included.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    permissionRow("Accessibility", granted: model.accessibilityGranted,
                                  detail: "Read, move and close windows. Enable the shortcut.") {
                        if model.accessibilityGranted {
                            Permissions.openAccessibilitySettings()
                        } else {
                            model.requestAccessibility()
                        }
                    }
                    permissionRow("Screen Recording", granted: model.screenRecordingGranted,
                                  detail: "Blurred layout previews. Sharp images are never stored.") {
                        if model.screenRecordingGranted {
                            Permissions.openScreenRecordingSettings()
                        } else {
                            Task { await model.requestScreenRecording() }
                        }
                    }
                    if !model.screenRecordingGranted {
                        Text("Optional. Without it, previews use window outlines. A restart may be needed after granting access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(model.scriptedApps.filter { $0.isInstalled }, id: \.kind) { app in
                        HStack(spacing: 10) {
                            Text(app.kind.displayName)
                            Spacer()
                            Text(model.isGranted(app) ? "Allowed" : model.status(app))
                                .font(.caption).foregroundStyle(.secondary)
                            if model.asking.contains(app.kind) {
                                ProgressView().controlSize(.small)
                            } else if !model.isGranted(app) {
                                Button("Allow") {
                                    Task { await model.requestAutomation(for: app.kind) }
                                }
                                .disabled(!model.canAsk(app))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Automation")
                        Spacer()
                        Button("Manage…") { Permissions.openAutomationSettings() }
                            .buttonStyle(.link)
                    }
                } footer: {
                    Text("Tabs, folders and projects. macOS asks per app; open an app to allow it.")
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)
            HStack {
                Button("Refresh") { Task { await refresh() } }
                    .disabled(refreshing)
                if refreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { onContinue() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 440, minHeight: 460)
        .task { await refresh() }
        .onChange(of: shortcut.enabled) { _, _ in shortcut.cancelRecording() }
        .onDisappear { shortcut.cancelRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "Allowed" : "Not allowed")
                .font(.caption).foregroundStyle(.secondary)
            Button(granted ? "Manage…" : "Allow", action: action)
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await model.refresh()
        refreshing = false
    }
}
