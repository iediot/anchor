import Foundation

struct ProbeRow: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
}

// how fresh the window evidence was and what it could actually settle
struct ProbeEvidence {
    let scanCapturedAt: Date
    let scriptedWindows: Int
    let onScreenWindows: Int
    let inScopeWindows: Int
    let uniquePairs: Int
    let identifiedPairs: Int
    let identityConflicts: Int
    let ambiguousPairs: Int
    let contestedPairs: Int
    let excludedByReportedState: Int
    let unmatchedScriptedWindows: Int
    let matchingBasis: String
    let relationship: IDRelationship

    var lines: [String] {
        ["window evidence rescanned at \(Self.stamp(scanCapturedAt))",
         "\(scriptedWindows) windows reported by the app, \(onScreenWindows) of its windows on the current desktop, \(inScopeWindows) of those on the destination display",
         "matching basis: \(matchingBasis)",
         "pairing: \(identifiedPairs) resolved by reported id, \(uniquePairs) resolved by geometry alone, \(identityConflicts) refused because id and geometry disagreed, \(ambiguousPairs) ambiguous, \(contestedPairs) contested, \(excludedByReportedState) excluded by reported state, \(unmatchedScriptedWindows) unmatched",
         "only resolved pairings carry a scope association",
         "id relationship, judged only on windows paired by geometry alone: \(relationship.label)"]
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

struct ProbeResult: Identifiable {
    let id = UUID()
    let kind: IntegrationKind
    let ranAt: Date
    let summary: String
    let succeeded: Bool
    let rows: [ProbeRow]
    let notes: [String]
    let evidence: ProbeEvidence?

    init(kind: IntegrationKind,
         ranAt: Date,
         summary: String,
         succeeded: Bool,
         rows: [ProbeRow],
         notes: [String],
         evidence: ProbeEvidence? = nil) {
        self.kind = kind
        self.ranAt = ranAt
        self.summary = summary
        self.succeeded = succeeded
        self.rows = rows
        self.notes = notes
        self.evidence = evidence
    }

    static func skipped(_ kind: IntegrationKind, _ reason: String) -> ProbeResult {
        ProbeResult(kind: kind, ranAt: Date(), summary: reason, succeeded: false, rows: [], notes: [])
    }
}
