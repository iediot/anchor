import Foundation

// a short name for one run, so a report and a user's message can point at the same thing
enum OperationID {
    static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
    }
}

struct OperationEvent: Identifiable, Equatable {
    let id: String
    let at: Date
    let stage: String
    let detail: String
}

// what a run did, in order, with the counts that answer whether anchor asked for
// something again or an application did it on its own
struct OperationLog: Equatable {
    private(set) var id = ""
    private(set) var trigger: String?
    private(set) var startedAt: Date?
    private(set) var events: [OperationEvent] = []
    private(set) var launchRequests = 0
    private(set) var closeRequests = 0

    mutating func begin(id: String, trigger: String?) {
        self.id = id
        self.trigger = trigger
        startedAt = Date()
        events = []
        launchRequests = 0
        closeRequests = 0
    }

    mutating func record(_ stage: String, _ detail: String) {
        events.append(OperationEvent(id: UUID().uuidString, at: Date(), stage: stage, detail: detail))
    }

    mutating func countLaunch() { launchRequests += 1 }
    mutating func countClose() { closeRequests += 1 }

    var counts: String { "launch requests \(launchRequests), close requests \(closeRequests)" }

    // no address, path content or environment is ever put in here, only what anchor did
    func lines() -> [String] {
        var out = ["anchor operation \(id)"]
        if let trigger { out.append("action: \(trigger)") }
        if let startedAt { out.append("started: \(ProbeEvidence.stamp(startedAt))") }
        for event in events {
            out.append("\(ProbeEvidence.stamp(event.at)) \(event.stage): \(event.detail)")
        }
        out.append("counts: \(counts)")
        return out
    }
}
