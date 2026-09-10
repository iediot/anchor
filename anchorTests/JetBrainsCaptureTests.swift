import XCTest
@testable import anchor

final class JetBrainsCaptureTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".idea"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func writeWorkspace(_ xml: String) throws {
        try Data(xml.utf8).write(to: project.appendingPathComponent(".idea/workspace.xml"))
    }

    func testPersistedEditorFilesAreReadAndMarkedStale() throws {
        try writeWorkspace("""
        <project version="4">
          <component name="FileEditorManager">
            <leaf>
              <file pinned="false" current-in-tab="true">
                <entry file="file://$PROJECT_DIR$/src/main.py" />
              </file>
              <file>
                <entry file="file://$PROJECT_DIR$/src/helpers.py" />
              </file>
              <file>
                <entry file="jar://$PROJECT_DIR$/lib/thing.jar!/x.class" />
              </file>
            </leaf>
          </component>
        </project>
        """)

        let editors = JetBrainsCapture.readPersistedEditors(projectPath: project.path)
        XCTAssertEqual(editors.files, ["\(project.path)/src/main.py", "\(project.path)/src/helpers.py"])
        XCTAssertTrue(editors.state.contains("persisted"))
        XCTAssertTrue(editors.state.contains("stale"))
    }

    func testWorkspaceWithoutAnEditorSectionIsReportedUnsupported() throws {
        try writeWorkspace("""
        <project version="4"><component name="SomethingElse" /></project>
        """)
        let editors = JetBrainsCapture.readPersistedEditors(projectPath: project.path)
        XCTAssertTrue(editors.state.hasPrefix("unsupported"))
        XCTAssertTrue(editors.files.isEmpty)
    }

    func testMissingWorkspaceFileIsReportedUnavailable() throws {
        try FileManager.default.removeItem(at: project.appendingPathComponent(".idea"))
        let editors = JetBrainsCapture.readPersistedEditors(projectPath: project.path)
        XCTAssertTrue(editors.state.hasPrefix("unavailable"))
        XCTAssertNil(editors.file)
    }

    func testUnparseableWorkspaceFileIsReportedUnavailable() throws {
        try writeWorkspace("<project><component name=\"FileEditorManager\">")
        let editors = JetBrainsCapture.readPersistedEditors(projectPath: project.path)
        XCTAssertTrue(editors.state.hasPrefix("unavailable"))
        XCTAssertTrue(editors.files.isEmpty)
    }

    // the title's trailing segment is one file, never the open file list
    func testTitleFileHintIsOnlyTheTrailingSegment() {
        XCTAssertEqual(JetBrainsCapture.trailingSegment("anchor \u{2013} main.py"), "main.py")
        XCTAssertEqual(JetBrainsCapture.trailingSegment("anchor - src/main.py"), "src/main.py")
        XCTAssertNil(JetBrainsCapture.trailingSegment("anchor"))
    }
}
