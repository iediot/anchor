import CoreGraphics
import Foundation

// one transform from a saved display relative rect to a rect on the destination
// everything here is in points, the backing scale is recorded and never multiplied in
enum LayoutMapping {
    // a window smaller than this is unusable, apps refuse most of it anyway
    static let minimumSize = CGSize(width: 240, height: 160)

    static func map(window: WindowRecord,
                    source: DisplayRecord,
                    destination: DestinationDisplay) -> LayoutPlan {
        let saved = window.displayRelativeFrame.cgRect
        guard finite(saved), saved.width > 0, saved.height > 0 else {
            return .unavailable("the saved rectangle \(window.displayRelativeFrame.summary) is not a usable size")
        }
        let sourceFrame = source.frame.cgRect
        let sourceUsable = source.visibleFrame.cgRect
        guard finite(sourceFrame), finite(sourceUsable), sourceUsable.width > 0, sourceUsable.height > 0 else {
            return .unavailable("the saved display record has no usable area to map from")
        }
        let destUsable = destination.visibleFrame
        guard finite(destUsable), destUsable.width >= minimumSize.width, destUsable.height >= minimumSize.height else {
            return .unavailable("the destination display reports no usable area to map onto")
        }

        var notes: [String] = []
        // the saved rect is relative to the display frame, the usable area is not the frame
        let usableOrigin = CGPoint(x: sourceUsable.minX - sourceFrame.minX, y: sourceUsable.minY - sourceFrame.minY)
        let relative = CGPoint(x: saved.minX - usableOrigin.x, y: saved.minY - usableOrigin.y)

        // one axis wise transform, positions and sizes share the same factors so the
        // relative arrangement survives a differently sized destination
        let scaleX = destUsable.width / sourceUsable.width
        let scaleY = destUsable.height / sourceUsable.height
        let scaled = abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001
        if scaled {
            notes.append("the destination usable area is a different size, so the arrangement was scaled by \(String(format: "%.2f", scaleX)) across and \(String(format: "%.2f", scaleY)) down")
        }

        var width = min(saved.width * scaleX, destUsable.width)
        var height = min(saved.height * scaleY, destUsable.height)
        if width < minimumSize.width {
            width = min(minimumSize.width, destUsable.width)
            notes.append("width raised to anchor's minimum of \(Int(minimumSize.width)) points")
        }
        if height < minimumSize.height {
            height = min(minimumSize.height, destUsable.height)
            notes.append("height raised to anchor's minimum of \(Int(minimumSize.height)) points")
        }

        let x = relative.x * scaleX
        let y = relative.y * scaleY
        let clampedX = min(max(x, 0), max(destUsable.width - width, 0))
        let clampedY = min(max(y, 0), max(destUsable.height - height, 0))
        let clamped = abs(clampedX - x) > 0.5 || abs(clampedY - y) > 0.5
        if clamped {
            notes.append("moved back inside the usable area of the destination")
        }

        if abs(source.backingScale - destination.backingScale) > 0.01 {
            notes.append("the two displays have different backing scales, anchor places windows in points and never in pixels")
        }

        let frame = CGRect(x: (destUsable.minX + clampedX).rounded(),
                           y: (destUsable.minY + clampedY).rounded(),
                           width: width.rounded(),
                           height: height.rounded())
        guard finite(frame) else {
            return .unavailable("the mapped rectangle came out unusable")
        }
        return .mapped(MappedFrame(appKitFrame: frame,
                                   scale: min(scaleX, scaleY),
                                   wasScaled: scaled,
                                   wasClamped: clamped,
                                   notes: notes))
    }

    static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy { $0.isFinite }
            && rect.size.width >= 0 && rect.size.height >= 0
    }

    // how far the applied rectangle ended up from the requested one
    static func describeAdjustment(requested: CGRect, actual: CGRect) -> String? {
        let dx = abs(actual.minX - requested.minX)
        let dy = abs(actual.minY - requested.minY)
        let dw = abs(actual.width - requested.width)
        let dh = abs(actual.height - requested.height)
        guard dx > 2 || dy > 2 || dw > 2 || dh > 2 else { return nil }
        return "the application placed the window at \(ScreenGeometry.describe(actual)) rather than \(ScreenGeometry.describe(requested))"
    }
}
