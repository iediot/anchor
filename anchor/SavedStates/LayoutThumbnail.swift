import AppKit
import SwiftUI

// app icons come from the launch services record for a bundle id
// an app that is gone, or a window with no bundle id, simply has no icon
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let hit = cache[bundleID] { return hit }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

// a miniature of one saved arrangement, drawn from the recorded display and window
// rectangles only, never from a screenshot
struct LayoutThumbnail: View {
    let snapshot: Snapshot
    // the miniature is fitted inside this box, its own shape decides the rest
    let fit: CGSize

    private var display: CGRect { snapshot.display.frame.cgRect }

    // a display record with no usable size still has to draw something of a sane shape
    private var aspect: CGFloat {
        guard display.width.isFinite, display.height.isFinite,
              display.width > 0, display.height > 0
        else { return 16.0 / 10.0 }
        return display.width / display.height
    }

    private var size: CGSize {
        let width = min(fit.width, fit.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            ForEach(placements) { placement in
                window(placement)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
        .accessibilityLabel("miniature of the saved layout, \(snapshot.windows.count) windows")
    }

    private struct Placement: Identifiable {
        let id: String
        let rect: CGRect
        let bundleID: String?
    }

    private var placements: [Placement] {
        guard display.width > 0, display.height > 0, display.width.isFinite, display.height.isFinite else { return [] }
        let scaleX = size.width / display.width
        let scaleY = size.height / display.height
        // the record is front to back, so it is drawn in reverse and the front window
        // ends up on top where the arrangement overlaps
        return snapshot.windows.reversed().compactMap { record in
            let saved = record.displayRelativeFrame.cgRect
            guard saved.width.isFinite, saved.height.isFinite,
                  saved.minX.isFinite, saved.minY.isFinite,
                  saved.width > 0, saved.height > 0
            else { return nil }
            // appkit measures up from the bottom of the display, this draws downward
            let rect = CGRect(x: saved.minX * scaleX,
                              y: (display.height - saved.minY - saved.height) * scaleY,
                              width: saved.width * scaleX,
                              height: saved.height * scaleY)
            return Placement(id: record.id, rect: rect, bundleID: record.bundleID)
        }
    }

    private func window(_ placement: Placement) -> some View {
        let width = max(placement.rect.width, 4)
        let height = max(placement.rect.height, 4)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .overlay(icon(placement, side: min(width, height)))
            .frame(width: width, height: height)
            .offset(x: placement.rect.minX, y: placement.rect.minY)
    }

    @ViewBuilder
    private func icon(_ placement: Placement, side: CGFloat) -> some View {
        // below this the rectangle is the only thing still readable
        if side >= 8 {
            let length = min(max(side * 0.55, 6), 26)
            if let image = AppIconCache.icon(for: placement.bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: length, height: length)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: length * 0.75))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
