import AppKit

// no scripting dictionary, so the project comes from the live window title matched
// against the ide's own recent projects file, and the open files come from the
// project's persisted workspace file which the ide writes when it saves state
enum JetBrainsCapture {
    static func capture(_ kind: IntegrationKind, scan: WindowScan) async -> AdapterOutput {
        let scoped = scan.windows(ofBundleID: kind.bundleID).filter(\.inScope)
        var output = AdapterOutput()
        output.windowsAttempted = scoped.count
        output.matchingBasis = "window title matched against the ide's recent projects file, this app has no scripting dictionary and no window id to check"

        guard let stateFile = JetBrainsProbe.newestStateFile(prefix: kind == .pycharm ? "PyCharm" : "CLion") else {
            let detail = "no recentProjects.xml was found under the jetbrains configuration folder, so no project could be identified"
            output.resources = Dictionary(uniqueKeysWithValues: scoped.map {
                ($0.id, WindowResources.empty(.jetBrains, .adapterUnavailable, detail))
            })
            output.outcome = detail
            output.issues.append(CaptureIssue(severity: .omission, scope: kind.displayName, message: detail))
            return output
        }

        let entries = JetBrainsProbe.parse(stateFile)
        for window in scoped {
            guard let title = window.title else {
                let denied = !scan.accessibilityGranted
                let detail = denied
                    ? "the window title needs accessibility, which is not granted, so no project could be identified"
                    : "this window reported no title, so no project could be matched"
                output.resources[window.id] = .empty(.jetBrains,
                                                     denied ? .accessibilityNotGranted : .resourceNotIdentified,
                                                     detail)
                output.issues.append(CaptureIssue(severity: .omission, scope: kind.displayName, message: detail))
                continue
            }

            let hits = JetBrainsProbe.candidates(title: title, among: entries)
            let fileHint = trailingSegment(title)
            if hits.count != 1 {
                let detail = hits.isEmpty
                    ? "no recent project matched the leading segment of this window title"
                    : "\(hits.count) recent projects share this name, so none was chosen"
                let resource = JetBrainsResource(projectPath: nil,
                                                 matchProvenance: "leading title segment matched against \(stateFile)",
                                                 ambiguousCandidates: hits.map(\.path),
                                                 titleFileHint: fileHint,
                                                 workspaceFile: nil,
                                                 editorFiles: [],
                                                 editorFileState: "not read, no single project was identified")
                output.resources[window.id] = WindowResources(kind: .jetBrains,
                                                              status: .resourceNotIdentified,
                                                              detail: detail,
                                                              jetBrains: resource)
                output.issues.append(CaptureIssue(severity: .omission, scope: kind.displayName, message: detail))
                continue
            }

            let project = hits[0].path
            let editors = readPersistedEditors(projectPath: project)
            let resource = JetBrainsResource(projectPath: project,
                                             matchProvenance: "the leading segment of the live window title matched exactly one entry in \(stateFile)",
                                             ambiguousCandidates: [],
                                             titleFileHint: fileHint,
                                             workspaceFile: editors.file,
                                             editorFiles: editors.files,
                                             editorFileState: editors.state)
            output.resources[window.id] = WindowResources(kind: .jetBrains,
                                                          status: .captured,
                                                          detail: nil,
                                                          jetBrains: resource)
            output.windowsCaptured += 1
            if editors.files.isEmpty {
                output.issues.append(CaptureIssue(severity: .note,
                                                  scope: kind.displayName,
                                                  message: "the open editor files for \(project) are \(editors.state)"))
            }
        }

        output.outcome = "\(output.windowsCaptured) of \(scoped.count) scoped windows matched exactly one recent project"
        return output
    }

    // titles look like project then a dash then the open file, the trailing part is a
    // hint about one file and never the full list of open editors
    static func trailingSegment(_ title: String) -> String? {
        for separator in [" \u{2013} ", " \u{2014} ", " - "] where title.contains(separator) {
            let parts = title.components(separatedBy: separator)
            guard parts.count > 1 else { continue }
            let tail = parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? nil : tail
        }
        return nil
    }

    struct PersistedEditors {
        var file: String?
        var files: [String]
        var state: String
    }

    // read only, the ide owns this file and anchor never writes it back
    static func readPersistedEditors(projectPath: String) -> PersistedEditors {
        let workspace = (projectPath as NSString).appendingPathComponent(".idea/workspace.xml")
        guard FileManager.default.fileExists(atPath: workspace) else {
            return PersistedEditors(file: nil,
                                    files: [],
                                    state: "unavailable, this project has no .idea/workspace.xml")
        }
        guard let data = FileManager.default.contents(atPath: workspace) else {
            return PersistedEditors(file: workspace, files: [], state: "unavailable, the workspace file could not be read")
        }
        let reader = WorkspaceEditorReader(projectPath: projectPath)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            return PersistedEditors(file: workspace, files: [], state: "unavailable, the workspace file is not readable xml")
        }
        guard reader.sawEditorManager else {
            return PersistedEditors(file: workspace,
                                    files: [],
                                    state: "unsupported, this workspace file has no FileEditorManager section in a layout anchor understands")
        }
        return PersistedEditors(file: workspace,
                                files: reader.files,
                                state: reader.files.isEmpty
                                    ? "persisted and empty, the ide recorded no open editor file"
                                    : "persisted by the ide when it last saved state, so it may be stale relative to the live editor")
    }
}

private final class WorkspaceEditorReader: NSObject, XMLParserDelegate {
    private let projectPath: String
    private var inEditorManager = false
    private(set) var sawEditorManager = false
    private(set) var files: [String] = []

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == "component", attributes["name"] == "FileEditorManager" {
            inEditorManager = true
            sawEditorManager = true
            return
        }
        // the open file lives on an entry inside a file element, older layouts put a url on the file itself
        guard inEditorManager, elementName == "entry" || elementName == "file",
              let raw = attributes["file"] ?? attributes["url"] else { return }
        guard let path = localPath(raw), !files.contains(path) else { return }
        files.append(path)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "component" { inEditorManager = false }
    }

    // only a local file url is turned into a path, a jar or another scheme is left out
    private func localPath(_ raw: String) -> String? {
        let expanded = raw.replacingOccurrences(of: "$PROJECT_DIR$", with: projectPath)
        guard expanded.hasPrefix("file://") else { return nil }
        let path = String(expanded.dropFirst("file://".count))
        return path.hasPrefix("/") ? path : nil
    }
}
