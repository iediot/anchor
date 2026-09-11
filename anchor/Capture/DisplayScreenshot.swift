import Foundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit

// why a saved layout has no picture behind its miniature
nonisolated enum ThumbnailFailure: Error, Equatable, Sendable {
    case permissionMissing
    case displayUnavailable
    case captureFailed(String)
    case renderFailed
    case notStored(String)

    var needsPermission: Bool { self == .permissionMissing }

    var message: String {
        switch self {
        case .permissionMissing:
            return "Anchor needs Screen Recording permission to take the blurred picture behind a saved layout. The layout itself was saved. Anchor may need to be opened again after you allow it."
        case .displayUnavailable:
            return "the display this layout was saved from was not offered for capture, so its miniature is drawn from the window rectangles only"
        case .captureFailed(let detail):
            return "the screen could not be read for this layout's picture: \(detail)"
        case .renderFailed:
            return "the picture of the screen could not be blurred, so nothing was kept"
        case .notStored(let detail):
            return "the blurred picture could not be stored: \(detail)"
        }
    }
}

// one picture of the display a save was taken from
// the frame is downscaled by the window server and blurred here, so the only image
// that ever leaves this type is the blurred miniature and nothing sharp is written down
// anchor's own windows are excluded, so the panel is never in its own picture
nonisolated enum DisplayScreenshot {
    // wide enough for the layout screen at retina, small enough that the blur is cheap
    static let targetWidth = 640

    static func blurredThumbnail(displayID: CGDirectDisplayID?) async -> Result<Data, ThumbnailFailure> {
        // preflight never prompts, a save must not stop to ask
        guard CGPreflightScreenCaptureAccess() else { return .failure(.permissionMissing) }
        guard let displayID else { return .failure(.displayUnavailable) }
        // the picture is the least important part of a save, so it is given a deadline
        // rather than being allowed to hold one open
        return await withTaskGroup(of: Result<Data, ThumbnailFailure>?.self) { group -> Result<Data, ThumbnailFailure> in
            group.addTask { await take(displayID: displayID) }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.captureFailed("the screen did not answer in time"))
        }
    }

    private static func take(displayID: CGDirectDisplayID) async -> Result<Data, ThumbnailFailure> {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return .failure(.captureFailed(error.localizedDescription))
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return .failure(.displayUnavailable)
        }

        // anchor's own windows, the open panel included, are never in anchor's picture
        let myPID = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter {
            $0.processID == myPID || $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let size = scaled(width: display.width, height: display.height)
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.scalesToFit = true

        let frame: CGImage
        do {
            frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return .failure(.captureFailed(error.localizedDescription))
        }
        guard let data = blurred(frame) else { return .failure(.renderFailed) }
        return .success(data)
    }

    // the display's own shape, no taller or wider than the miniature ever needs
    static func scaled(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (targetWidth, targetWidth * 10 / 16) }
        guard width > targetWidth else { return (width, height) }
        let scale = Double(targetWidth) / Double(width)
        return (targetWidth, max(1, Int((Double(height) * scale).rounded())))
    }

    // clamped first, so the blur pulls the edge pixels outwards instead of fading into
    // transparency, and cropped back to the frame afterwards
    private static func blurred(_ image: CGImage) -> Data? {
        let source = CIImage(cgImage: image)
        let sigma = max(1.0, Double(image.width) / 120.0)
        let output = source.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: source.extent)
        // one context per save, rather than one kept alive for a picture taken now and then
        return CIContext().pngRepresentation(of: output,
                                             format: .RGBA8,
                                             colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
