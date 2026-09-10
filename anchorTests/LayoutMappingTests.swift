import XCTest
@testable import anchor

@MainActor
final class LayoutMappingTests: XCTestCase {
    private func map(_ frame: CGRect,
                     destination: DestinationDisplay? = nil,
                     source: DisplayRecord? = nil,
                     fullScreen: String = "ordinary window") -> LayoutPlan {
        let record = RestoreFixtures.window(frame: frame,
                                            fullScreen: fullScreen,
                                            resources: .empty(.unsupported, .appNotSupported, "no adapter"))
        return LayoutMapping.map(window: record,
                                 source: source ?? SnapshotFixtures.display(),
                                 destination: destination ?? RestoreFixtures.destination())
    }

    func testSameDisplayKeepsTheSavedRectangle() {
        guard case .mapped(let mapped) = map(CGRect(x: 10, y: 20, width: 700, height: 800)) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertEqual(mapped.appKitFrame, CGRect(x: 10, y: 20, width: 700, height: 800))
        XCTAssertFalse(mapped.wasScaled)
        XCTAssertFalse(mapped.wasClamped)
    }

    func testSmallerDestinationScalesPositionAndSizeTogether() {
        let destination = RestoreFixtures.destination(frame: CGRect(x: 0, y: 0, width: 756, height: 491),
                                                      visible: CGRect(x: 0, y: 0, width: 756, height: 472))
        guard case .mapped(let mapped) = map(CGRect(x: 200, y: 100, width: 600, height: 600), destination: destination) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertEqual(mapped.appKitFrame.minX, 100, accuracy: 1)
        XCTAssertEqual(mapped.appKitFrame.width, 300, accuracy: 1)
        XCTAssertEqual(mapped.appKitFrame.minY, 50, accuracy: 1)
        XCTAssertEqual(mapped.appKitFrame.height, 300, accuracy: 1)
        XCTAssertTrue(mapped.wasScaled)
    }

    // a window saved half off the right edge comes back fully inside the usable area
    func testWindowPastTheEdgeIsClampedInside() {
        guard case .mapped(let mapped) = map(CGRect(x: 1300, y: 800, width: 700, height: 400)) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertTrue(mapped.wasClamped)
        XCTAssertLessThanOrEqual(mapped.appKitFrame.maxX, 1512)
        XCTAssertLessThanOrEqual(mapped.appKitFrame.maxY, 944)
        XCTAssertGreaterThanOrEqual(mapped.appKitFrame.minX, 0)
    }

    func testNegativeOriginIsClampedRatherThanCarriedOver() {
        guard case .mapped(let mapped) = map(CGRect(x: -320, y: -40, width: 600, height: 500)) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertEqual(mapped.appKitFrame.minX, 0)
        XCTAssertEqual(mapped.appKitFrame.minY, 0)
        XCTAssertTrue(mapped.wasClamped)
    }

    func testWindowLargerThanTheDestinationIsCutToTheUsableArea() {
        let destination = RestoreFixtures.destination(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                      visible: CGRect(x: 0, y: 0, width: 800, height: 560))
        guard case .mapped(let mapped) = map(CGRect(x: 0, y: 0, width: 1500, height: 900), destination: destination) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertLessThanOrEqual(mapped.appKitFrame.width, 800)
        XCTAssertLessThanOrEqual(mapped.appKitFrame.height, 560)
    }

    func testTinyWindowIsRaisedToTheMinimumSize() {
        guard case .mapped(let mapped) = map(CGRect(x: 10, y: 10, width: 60, height: 40)) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertEqual(mapped.appKitFrame.width, LayoutMapping.minimumSize.width)
        XCTAssertEqual(mapped.appKitFrame.height, LayoutMapping.minimumSize.height)
    }

    func testZeroSizedRecordHasNoLayout() {
        guard case .unavailable = map(CGRect(x: 0, y: 0, width: 0, height: 400)) else {
            return XCTFail("a zero width record must not map")
        }
    }

    func testNonFiniteRecordHasNoLayout() {
        guard case .unavailable = map(CGRect(x: CGFloat.nan, y: 0, width: 400, height: 400)) else {
            return XCTFail("a record that is not a number must not map")
        }
    }

    func testDisplayWithNoUsableAreaHasNoLayout() {
        let destination = RestoreFixtures.destination(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                      visible: CGRect(x: 0, y: 0, width: 100, height: 100))
        guard case .unavailable = map(CGRect(x: 0, y: 0, width: 400, height: 400), destination: destination) else {
            return XCTFail("a destination smaller than a usable window must not map")
        }
    }

    // the offset between a display frame and its usable area is not the same on both
    // machines, so the transform works from the usable origin rather than the frame origin
    func testUsableOriginOffsetIsHonoured() {
        let source = DisplayRecord(displayID: 1,
                                   name: "Source",
                                   frame: RectRecord(CGRect(x: 0, y: 0, width: 1000, height: 1000)),
                                   visibleFrame: RectRecord(CGRect(x: 0, y: 100, width: 1000, height: 860)),
                                   backingScale: 2,
                                   isPrimary: true,
                                   attachedDisplays: 1,
                                   selectionSource: "test",
                                   selectionDetail: nil)
        let destination = RestoreFixtures.destination(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                                      visible: CGRect(x: 0, y: 50, width: 1000, height: 860))
        guard case .mapped(let mapped) = map(CGRect(x: 100, y: 150, width: 400, height: 400),
                                             destination: destination,
                                             source: source) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertEqual(mapped.appKitFrame.minY, 100, accuracy: 1)
    }

    // the reported pycharm case, saved and restored on the same display
    // the request is the saved rectangle itself, so a half width result cannot come from
    // this transform
    func testTheSavedIdeRectangleIsRequestedUnchangedOnTheSameDisplay() {
        let display = DisplayRecord(displayID: 1,
                                    name: "Built-in Retina Display",
                                    frame: RectRecord(CGRect(x: 0, y: 0, width: 1512, height: 982)),
                                    visibleFrame: RectRecord(CGRect(x: 0, y: 81, width: 1512, height: 868)),
                                    backingScale: 2,
                                    isPrimary: true,
                                    attachedDisplays: 1,
                                    selectionSource: "test",
                                    selectionDetail: nil)
        let destination = RestoreFixtures.destination(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                      visible: CGRect(x: 0, y: 81, width: 1512, height: 868))
        guard case .mapped(let mapped) = map(CGRect(x: 668, y: 81, width: 844, height: 868),
                                             destination: destination,
                                             source: display) else {
            return XCTFail("expected a mapped layout")
        }
        XCTAssertEqual(mapped.appKitFrame, CGRect(x: 668, y: 81, width: 844, height: 868))
        XCTAssertFalse(mapped.wasScaled)
        XCTAssertFalse(mapped.wasClamped)
    }

    func testApplicationAdjustmentIsDescribedOnlyWhenItMatters() {
        let requested = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertNil(LayoutMapping.describeAdjustment(requested: requested,
                                                      actual: CGRect(x: 1, y: 1, width: 600, height: 400)))
        XCTAssertNotNil(LayoutMapping.describeAdjustment(requested: requested,
                                                         actual: CGRect(x: 0, y: 0, width: 600, height: 700)))
    }
}
