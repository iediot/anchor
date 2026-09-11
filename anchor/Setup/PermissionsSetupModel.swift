import AppKit
import SwiftUI

// the one place permissions are explained and asked for
// it opens itself once, on a first launch, and after that only when someone asks for it
// from settings, permissions, so a machine where something was revoked can come back
@MainActor
@Observable
final class PermissionsSetupModel {
    private(set) var accessibilityGranted = Permissions.accessibilityGranted
    private(set) var screenRecordingGranted = Permissions.screenRecordingGranted
    private(set) var apps: [InstalledApp] = []
    private(set) var automation: [IntegrationKind: AutomationAccess] = [:]
    private(set) var asking: Set<IntegrationKind> = []

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let setupShown = "anchor.setupShown"
    }

    // a dismissal is remembered, so onboarding is shown once and never comes back by itself
    var hasBeenShown: Bool { defaults.bool(forKey: Keys.setupShown) }

    func markShown() {
        defaults.set(true, forKey: Keys.setupShown)
    }

    // the applications the system asks about one at a time
    var scriptedApps: [InstalledApp] { apps.filter { $0.kind.usesAppleEvents } }

    // cheap, and these are the two that change behind anchor's back while it is open
    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        screenRecordingGranted = Permissions.screenRecordingGranted
    }

    // the survey reads bundles from disk, so it is done when the window opens and when
    // someone asks for it again, not on a timer
    func refresh() async {
        refreshPermissions()
        apps = AppCatalog.survey()
        for app in apps where app.isInstalled && app.kind.usesAppleEvents {
            // stored consent, read without raising a prompt
            automation[app.kind] = await ScriptRunner.shared
                .determineAutomationAccess(bundleID: app.kind.bundleID, askUser: false)
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
    }

    // the system asks once per machine, anyone it has already asked is sent to settings
    func requestScreenRecording() async {
        let granted = await Permissions.requestScreenRecording()
        screenRecordingGranted = granted
        guard !granted else { return }
        Permissions.openScreenRecordingSettings()
    }

    // consent is per application, and the system only asks about one that is running
    // anchor never opens an application to raise a prompt
    func canAsk(_ app: InstalledApp) -> Bool {
        app.kind.usesAppleEvents && app.isInstalled && app.isRunning && !asking.contains(app.kind)
    }

    func requestAutomation(for kind: IntegrationKind) async {
        guard !asking.contains(kind) else { return }
        asking.insert(kind)
        defer { asking.remove(kind) }
        automation[kind] = await ScriptRunner.shared
            .determineAutomationAccess(bundleID: kind.bundleID, askUser: true)
    }

    func status(_ app: InstalledApp) -> String {
        guard app.isInstalled else { return "not installed on this Mac" }
        guard let access = automation[app.kind] else { return "not read yet" }
        guard app.isRunning else { return "\(access.label), open it to be asked" }
        return access.label
    }

    func isGranted(_ app: InstalledApp) -> Bool {
        automation[app.kind] == .granted
    }
}
