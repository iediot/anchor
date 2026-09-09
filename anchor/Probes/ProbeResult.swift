import Foundation

struct ProbeRow: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
}

struct ProbeResult: Identifiable {
    let id = UUID()
    let kind: IntegrationKind
    let ranAt: Date
    let summary: String
    let succeeded: Bool
    let rows: [ProbeRow]
    let notes: [String]

    static func skipped(_ kind: IntegrationKind, _ reason: String) -> ProbeResult {
        ProbeResult(kind: kind, ranAt: Date(), summary: reason, succeeded: false, rows: [], notes: [])
    }
}
