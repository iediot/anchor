import Foundation

// one spelling of a time, wherever anchor writes one down
nonisolated enum Stamp {
    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
