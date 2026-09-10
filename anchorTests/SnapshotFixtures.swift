import CoreGraphics
import Foundation
@testable import anchor

// small builders so each test states only what it is actually about
enum SnapshotFixtures {
    static func display(name: String = "Test Display") -> DisplayRecord {
        DisplayRecord(displayID: 1,
                      name: name,
                      frame: RectRecord(CGRect(x: 0, y: 0, width: 1512, height: 982)),
                      visibleFrame: RectRecord(CGRect(x: 0, y: 0, width: 1512, height: 944)),
                      backingScale: 2,
                      isPrimary: true,
                      attachedDisplays: 1,
                      selectionSource: "test",
                      selectionDetail: nil)
    }

    static func browserWindow(tabs: [BrowserTabRecord], selected: Int? = 1) -> WindowRecord {
        window(resources: WindowResources(kind: .browser,
                                          status: .captured,
                                          detail: nil,
                                          browser: BrowserResource(scriptWindowID: 7,
                                                                   selectedTabIndex: selected,
                                                                   tabs: tabs,
                                                                   privateWindowDetection: BrowserCapture.privateDetectionNote)))
    }

    static func window(title: String? = "window",
                       resources: WindowResources = .empty(.unsupported, .appNotSupported, "no adapter")) -> WindowRecord {
        WindowRecord(id: UUID().uuidString,
                     runtimeWindowID: 42,
                     appName: "Test App",
                     bundleID: "test.app",
                     appVersion: "1.0",
                     title: title,
                     titleSource: "accessibility",
                     appKitFrame: RectRecord(CGRect(x: 10, y: 20, width: 700, height: 800)),
                     displayRelativeFrame: RectRecord(CGRect(x: 10, y: 20, width: 700, height: 800)),
                     windowServerFrame: RectRecord(CGRect(x: 10, y: 162, width: 700, height: 800)),
                     fullScreenSignal: "ordinary window",
                     accessibilityDocument: nil,
                     resources: resources,
                     limitations: [])
    }

    static func snapshot(id: String = SnapshotStore.newIdentifier(),
                         name: String? = nil,
                         createdAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
                         completeness: SnapshotCompleteness = .complete,
                         windows: [WindowRecord] = []) -> Snapshot {
        Snapshot(schemaVersion: SnapshotSchema.current,
                 id: id,
                 createdAt: createdAt,
                 name: name,
                 completeness: completeness,
                 host: HostRecord(operatingSystem: "test os", anchorVersion: "1.0 (1)"),
                 display: display(),
                 windows: windows,
                 adapters: [],
                 issues: [])
    }

    // strings a delimiter based format would have destroyed
    static let awkwardStrings = [
        "https://example.com/path?q=a<|>b&x=%E2%9C%93#fragment",
        "https://example.com/\u{1F600}/\u{202E}reversed/\u{0301}combining",
        "title with a\nnewline and a\ttab and a ; and a , and a <|>",
        "\"quoted\" and \\backslash\\ and /slash/ and 'apostrophe'",
        String(repeating: "é", count: 400),
        "",
        "  leading and trailing  "
    ]
}
