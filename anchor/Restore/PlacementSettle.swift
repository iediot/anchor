import CoreGraphics
import Foundation

// an application can accept a rectangle and then move the window itself while it is
// still starting, so the result is read again once and corrected at most once
// a normal reopen and the launch diagnostic share this, there is no second version of it
enum PlacementSettle {
    static var delay: TimeInterval = 1.2

    static func verify(windowID: CGWindowID,
                       bundleID: String,
                       requested: CGRect,
                       executor: RestoreExecutor) async -> (text: String, state: ItemOutcome.State) {
        let asked = RectRecord(requested).summary
        await pause()
        guard let first = frame(of: windowID, bundleID: bundleID, executor: executor) else {
            return ("requested \(asked), the application accepted it, and anchor could not read the window back to confirm where it ended up", .opened)
        }
        guard let drift = LayoutMapping.describeAdjustment(requested: requested, actual: first) else {
            return ("requested \(asked) and the application kept it", .opened)
        }
        let again = await executor.place(windowID: windowID, appKitFrame: requested)
        guard case .applied = again else {
            return ("requested \(asked), \(drift), and a second attempt was refused: \(again.label)", .failed)
        }
        await pause()
        guard let second = frame(of: windowID, bundleID: bundleID, executor: executor) else {
            return ("requested \(asked), \(drift), and the window stopped being listed before anchor could confirm the correction", .opened)
        }
        guard let stillDrifting = LayoutMapping.describeAdjustment(requested: requested, actual: second) else {
            return ("requested \(asked), the application moved it once while it was starting and anchor put it back", .opened)
        }
        return ("requested \(asked), \(stillDrifting), and anchor left it there rather than fighting the application", .failed)
    }

    private static func pause() async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
    }

    private static func frame(of windowID: CGWindowID, bundleID: String, executor: RestoreExecutor) -> CGRect? {
        executor.liveWindows(bundleID: bundleID).first { $0.id == windowID }?.appKitFrame
    }
}
