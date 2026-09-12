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

// a miniature of one saved arrangement
// behind it, when the save took one, sits the blurred picture of the display that was
// saved, with the app icons over it at the window positions the record holds
// a layout with no picture keeps the schematic, its window rectangles drawn on a plain
// ground, which is what every older saved layout has
struct LayoutThumbnail: View {
    let snapshot: Snapshot
    // the miniature is fitted inside this box, its own shape decides the rest
    let fit: CGSize
    // the blurred picture of the display, already downscaled, never a sharp frame
    var backdrop: NSImage?

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
            ground
            // the window rectangles are the drawing only when there is no picture behind
            if backdrop == nil {
                ForEach(placements) { placement in
                    window(placement)
                }
            }
            // the icons are drawn on their own, because separating them moves them off
            // the centres of the rectangles they belong to
            ForEach(icons) { icon in
                marker(icon)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.previewRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelStyle.previewRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityLabel(label)
    }

    private var label: String {
        let windows = "\(snapshot.windows.count) windows"
        return backdrop == nil
            ? "miniature of the saved layout, \(windows)"
            : "blurred picture of the saved screen, \(windows)"
    }

    @ViewBuilder
    private var ground: some View {
        if let backdrop {
            Image(nsImage: backdrop)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
        } else {
            RoundedRectangle(cornerRadius: PanelStyle.previewRadius).fill(Color.primary.opacity(0.045))
        }
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

    // the saved rectangle, drawn exactly where it was recorded
    private func window(_ placement: Placement) -> some View {
        let width = max(placement.rect.width, 4)
        let height = max(placement.rect.height, 4)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .frame(width: width, height: height)
            .offset(x: placement.rect.minX, y: placement.rect.minY)
    }

    private struct IconPlacement: Identifiable {
        let id: String
        let bundleID: String?
        let length: CGFloat
        var centre: CGPoint
    }

    // an icon starts at the centre of its own window and is only moved to get clear of
    // another icon, so a stack of windows reads as several applications rather than one
    // nothing here touches the saved geometry, only the icon drawn over it
    private var icons: [IconPlacement] {
        var items = placements.compactMap { placement -> IconPlacement? in
            let side = min(max(placement.rect.width, 4), max(placement.rect.height, 4))
            // below this the rectangle is the only thing still readable
            guard side >= 8 else { return nil }
            return IconPlacement(id: placement.id,
                                 bundleID: placement.bundleID,
                                 length: min(max(side * 0.55, 6), 26),
                                 centre: CGPoint(x: placement.rect.midX, y: placement.rect.midY))
        }
        guard items.count > 1 else { return items.map(held) }
        // a fixed number of passes over the pairs in a fixed order, and every push is
        // decided by the positions alone, so the same layout lays out the same way every
        // time it is drawn
        for _ in 0..<6 {
            var moved = false
            for i in items.indices {
                for j in items.indices where j > i {
                    var first = items[i]
                    var second = items[j]
                    guard separate(&first, &second) else { continue }
                    items[i] = first
                    items[j] = second
                    moved = true
                }
            }
            items = items.map(held)
            if !moved { break }
        }
        return items
    }

    // two icons that sit on top of each other step apart along whichever axis needs the
    // shorter move, each going half the distance in the opposite direction
    private func separate(_ first: inout IconPlacement, _ second: inout IconPlacement) -> Bool {
        let gap: CGFloat = 2
        let clearance = (first.length + second.length) / 2 + gap
        let dx = second.centre.x - first.centre.x
        let dy = second.centre.y - first.centre.y
        let overlapX = clearance - abs(dx)
        let overlapY = clearance - abs(dy)
        guard overlapX > 0, overlapY > 0 else { return false }
        if overlapX <= overlapY {
            // two icons at the very same point part along x, the earlier one leftwards
            let direction: CGFloat = dx < 0 ? -1 : 1
            first.centre.x -= overlapX / 2 * direction
            second.centre.x += overlapX / 2 * direction
        } else {
            let direction: CGFloat = dy < 0 ? -1 : 1
            first.centre.y -= overlapY / 2 * direction
            second.centre.y += overlapY / 2 * direction
        }
        return true
    }

    // an icon pushed aside still belongs inside the miniature
    private func held(_ placement: IconPlacement) -> IconPlacement {
        var held = placement
        let half = placement.length / 2
        held.centre.x = size.width >= placement.length
            ? min(max(placement.centre.x, half), size.width - half)
            : size.width / 2
        held.centre.y = size.height >= placement.length
            ? min(max(placement.centre.y, half), size.height - half)
            : size.height / 2
        return held
    }

    private func marker(_ placement: IconPlacement) -> some View {
        let length = placement.length
        return Group {
            if let image = AppIconCache.icon(for: placement.bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: length * 0.75))
                    .foregroundStyle(backdrop == nil ? Color.secondary : Color.white.opacity(0.9))
            }
        }
        .frame(width: length, height: length)
        // over a blurred picture an icon needs its own edge
        .shadow(color: .black.opacity(backdrop == nil ? 0 : 0.35), radius: 1.5, y: 0.5)
        .offset(x: placement.centre.x - length / 2, y: placement.centre.y - length / 2)
    }
}
