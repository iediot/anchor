import Foundation

// a saved snapshot is data, never an instruction
// an address anchor cannot name a supported handler for is reported, never opened
enum FileStatus: Equatable {
    case present(isDirectory: Bool)
    case missing
    case inaccessible(String)
    case invalid(String)
}

enum ResourceValidation {
    static let webSchemes: Set<String> = ["http", "https"]

    // addresses browsers use for an ordinary empty tab, they are reopened as a blank tab
    static let blankAddresses: Set<String> = ["about:blank",
                                              "about:newtab",
                                              "favorites://",
                                              "topsites://",
                                              "chrome://newtab/",
                                              "chrome://new-tab-page/"]

    enum TabDecision: Equatable {
        case blank
        case web(String)
        case localFile(String)
        case unsupported(String)
        case malformed(String)
        case missing(String)
        case inaccessible(String)
    }

    static func decideTab(url raw: String?, fileStatus: (String) -> FileStatus) -> TabDecision {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .blank }
        if blankAddresses.contains(trimmed.lowercased()) { return .blank }
        guard trimmed.count <= 8192 else {
            return .malformed("the saved address is longer than anchor will hand to an application")
        }
        guard !trimmed.contains(where: { $0.isNewline }) else {
            return .malformed("the saved address contains a line break")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .malformed("the saved address is not a readable url")
        }
        if webSchemes.contains(scheme) {
            guard url.host != nil else { return .malformed("the saved web address names no host") }
            return .web(trimmed)
        }
        if scheme == "file" {
            guard url.isFileURL else { return .malformed("the saved file address is not a file url") }
            let path = url.path
            guard !path.isEmpty else { return .malformed("the saved file address has no path") }
            switch fileStatus(path) {
            case .present: return .localFile(trimmed)
            case .missing: return .missing(path)
            case .inaccessible(let reason): return .inaccessible(reason)
            case .invalid(let reason): return .malformed(reason)
            }
        }
        return .unsupported("anchor reopens web addresses and readable local files only, this tab uses the \(scheme) scheme and anchor will not hand it to a system handler")
    }

    // a saved directory or project path, validated before it can become an argument
    enum PathDecision: Equatable {
        case ready(String)
        case missing(String)
        case inaccessible(String)
        case malformed(String)
    }

    static func decideDirectory(_ raw: String?, fileStatus: (String) -> FileStatus) -> PathDecision {
        switch normalize(raw) {
        case .invalid(let reason): return .malformed(reason)
        case .ok(let path):
            switch fileStatus(path) {
            case .present(let isDirectory):
                return isDirectory ? .ready(path) : .malformed("the saved path is not a directory")
            case .missing: return .missing("no directory exists at \(path) any more")
            case .inaccessible(let reason): return .inaccessible(reason)
            case .invalid(let reason): return .malformed(reason)
            }
        }
    }

    static func decideProject(_ raw: String?, fileStatus: (String) -> FileStatus) -> PathDecision {
        switch normalize(raw) {
        case .invalid(let reason): return .malformed(reason)
        case .ok(let path):
            switch fileStatus(path) {
            case .present: return .ready(path)
            case .missing: return .missing("nothing exists at \(path) any more")
            case .inaccessible(let reason): return .inaccessible(reason)
            case .invalid(let reason): return .malformed(reason)
            }
        }
    }

    enum NormalizedPath: Equatable {
        case ok(String)
        case invalid(String)
    }

    static func normalize(_ raw: String?) -> NormalizedPath {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .invalid("no path was recorded")
        }
        var path = raw
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        guard path.hasPrefix("/") else { return .invalid("the saved path is not absolute") }
        guard !path.contains("\0"), !path.contains(where: { $0.isNewline }) else {
            return .invalid("the saved path contains characters a path cannot hold")
        }
        guard path.count <= 4096 else { return .invalid("the saved path is longer than a usable path") }
        return .ok((path as NSString).standardizingPath)
    }

    // shell text is only unavoidable in terminal, so quoting lives in one place
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
