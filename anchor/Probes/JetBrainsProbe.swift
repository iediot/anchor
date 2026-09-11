import AppKit

struct RecentProjectEntry {
    let path: String
    let projectName: String?
    let frameTitle: String?
    let openedAt: Date?
}

// jetbrains ides ship no scripting dictionary so windows are matched by title
// the recent projects file is read only and is a candidate list, never proof a project is open
// capture and restore both read it through here
enum JetBrainsProbe {
    private static let configRoot = ("~/Library/Application Support/JetBrains" as NSString).expandingTildeInPath

    static func newestStateFile(prefix: String) -> String? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: configRoot) else { return nil }
        let candidates = names
            .filter { $0.hasPrefix(prefix) }
            .map { "\(configRoot)/\($0)/options/recentProjects.xml" }
            .filter { manager.fileExists(atPath: $0) }
        return candidates.sorted().last
    }

    static func parse(_ path: String) -> [RecentProjectEntry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let reader = RecentProjectsReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries.sorted { ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast) }
    }

    // every candidate is returned so two projects with the same name stay ambiguous
    // rather than silently resolving to whichever was listed first
    static func candidates(title: String, among entries: [RecentProjectEntry]) -> [RecentProjectEntry] {
        let head = leadingSegment(title)
        guard !head.isEmpty else { return [] }
        return entries.filter { entry in
            if let name = entry.projectName, name.caseInsensitiveCompare(head) == .orderedSame { return true }
            if let frame = entry.frameTitle, leadingSegment(frame).caseInsensitiveCompare(head) == .orderedSame { return true }
            return (entry.path as NSString).lastPathComponent.caseInsensitiveCompare(head) == .orderedSame
        }
    }

    // titles look like project then a dash then the open file
    static func leadingSegment(_ title: String) -> String {
        for separator in [" \u{2013} ", " \u{2014} ", " - "] where title.contains(separator) {
            return String(title.components(separatedBy: separator)[0]).trimmingCharacters(in: .whitespaces)
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

private final class RecentProjectsReader: NSObject, XMLParserDelegate {
    var entries: [RecentProjectEntry] = []

    private var currentKey: String?
    private var currentFrameTitle: String?
    private var currentName: String?
    private var currentOpened: Date?

    private var home: String { NSHomeDirectory() }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "entry":
            currentKey = attributes["key"]
            currentFrameTitle = nil
            currentName = nil
            currentOpened = nil
        case "RecentProjectMetaInfo":
            currentFrameTitle = attributes["frameTitle"]
        case "option":
            guard let name = attributes["name"], let value = attributes["value"] else { return }
            if name == "customProjectName" { currentName = value }
            if name == "projectOpenTimestamp", let millis = Double(value) {
                currentOpened = Date(timeIntervalSince1970: millis / 1000)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        guard elementName == "entry", let key = currentKey else { return }
        let path = key.replacingOccurrences(of: "$USER_HOME$", with: home)
        // light edit and other pseudo entries are not real project directories
        if !path.hasPrefix("/") {
            currentKey = nil
            return
        }
        entries.append(RecentProjectEntry(path: path,
                                          projectName: currentName,
                                          frameTitle: currentFrameTitle,
                                          openedAt: currentOpened))
        currentKey = nil
    }
}
