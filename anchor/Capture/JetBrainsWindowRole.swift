import Foundation

// a jetbrains window is either a project window or the ide's own welcome window
// the difference matters because the welcome window carries no project, and treating it
// as one makes anchor open a project nobody asked for and resize a window it does not own
enum JetBrainsWindowRole: Equatable {
    case welcome(String)
    case projectCandidate

    var welcomeReason: String? {
        if case .welcome(let reason) = self { return reason }
        return nil
    }

    var isWelcome: Bool { welcomeReason != nil }
}

enum JetBrainsWindowTitle {
    // the ide writes its own name in the place a project window carries its open file
    // matching that whole phrase, and only there, keeps a project actually called
    // welcomescreen or welcome a project
    static func marker(_ kind: IntegrationKind) -> String { "Welcome to \(kind.displayName)" }

    static func role(title: String?, kind: IntegrationKind) -> JetBrainsWindowRole {
        guard kind == .pycharm || kind == .clion else { return .projectCandidate }
        guard let title else { return .projectCandidate }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .projectCandidate }
        let marker = marker(kind)
        if trimmed.caseInsensitiveCompare(marker) == .orderedSame {
            return .welcome("this window's whole title is \(marker), which is the ide's welcome window and not a project")
        }
        if let tail = JetBrainsCapture.trailingSegment(trimmed),
           tail.caseInsensitiveCompare(marker) == .orderedSame {
            return .welcome("this window's title ends in \(marker), where a project window carries its open file, so it is the ide's welcome window")
        }
        return .projectCandidate
    }

    static func role(record: WindowRecord) -> JetBrainsWindowRole {
        guard let kind = IntegrationKind.matching(bundleID: record.bundleID) else { return .projectCandidate }
        return role(title: record.title, kind: kind)
    }
}
