import XCTest
@testable import anchor

// the ide shows a splash before the project window, and placing the splash is what left
// the real window wherever the ide put it
@MainActor
final class ProjectWindowReadinessTests: XCTestCase {
    private let request = ProjectOpenRequest(app: .pycharm,
                                             itemID: "item",
                                             path: "/Users/test/gameboy_emu",
                                             projectName: "gameboy_emu")

    private func resolve(_ windows: [LiveWindow],
                         excluding: Set<CGWindowID> = [],
                         accessibility: Bool = true) -> ProjectWindowReadiness.Resolution {
        ProjectWindowReadiness.resolve(request: request,
                                       candidates: windows,
                                       excluding: excluding,
                                       accessibilityGranted: accessibility)
    }

    private func splash() -> LiveWindow {
        RestoreFixtures.liveWindow(id: 11,
                                   title: nil,
                                   frame: CGRect(x: 600, y: 400, width: 500, height: 300))
    }

    private func welcome() -> LiveWindow {
        RestoreFixtures.liveWindow(id: 12,
                                   title: "Welcome to PyCharm",
                                   frame: CGRect(x: 300, y: 200, width: 1000, height: 720))
    }

    private func project(id: CGWindowID = 13,
                         title: String = "gameboy_emu \u{2013} main.py",
                         frame: CGRect = CGRect(x: 668, y: 81, width: 844, height: 868)) -> LiveWindow {
        RestoreFixtures.liveWindow(id: id, title: title, frame: frame)
    }

    func testASplashWindowIsNotTheProjectWindow() {
        XCTAssertEqual(resolve([splash()]),
                       .notYet("1 windows have appeared but none of them is the gameboy_emu window yet"))
    }

    func testTheWelcomeScreenIsNotTheProjectWindow() {
        guard case .notYet = resolve([welcome()]) else {
            return XCTFail("a welcome screen must never be treated as the project")
        }
    }

    func testTheProjectWindowIsTakenOnceItCarriesTheProject() {
        guard case .ready(let id, _) = resolve([splash(), project()]) else {
            return XCTFail("expected the project window")
        }
        XCTAssertEqual(id, 13)
    }

    // the same window can carry the project only after its title arrives
    func testAWindowThatGainsItsTitleLaterIsAcceptedThen() {
        let untitled = RestoreFixtures.liveWindow(id: 13,
                                                  title: nil,
                                                  frame: CGRect(x: 668, y: 81, width: 844, height: 868))
        guard case .notYet = resolve([untitled]) else { return XCTFail("an untitled window proves nothing") }
        guard case .ready(let id, _) = resolve([project()]) else { return XCTFail("expected the project window") }
        XCTAssertEqual(id, 13)
    }

    func testWindowsThatWereAlreadyOpenAreNeverChosen() {
        guard case .notYet = resolve([project()], excluding: [13]) else {
            return XCTFail("a window that was open before the operation is not the one this run created")
        }
    }

    func testTwoWindowsClaimingTheProjectResolveToNeither() {
        guard case .ambiguous(let ids, _) = resolve([project(id: 13), project(id: 14)]) else {
            return XCTFail("two claimants identify nothing")
        }
        XCTAssertEqual(ids.sorted(), [13, 14])
    }

    func testAProjectWindowTooSmallToPlaceIsNotAccepted() {
        let tiny = project(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        guard case .notYet = resolve([tiny]) else {
            return XCTFail("a window smaller than a placeable one is still a startup window")
        }
    }

    func testWithoutAccessibilityAnchorPlacesNothingRatherThanGuessing() {
        guard case .unavailable = resolve([project()], accessibility: false) else {
            return XCTFail("without titles anchor cannot tell the windows apart")
        }
    }

    func testXcodeUsesItsDocumentRatherThanItsTitle() {
        let xcodeRequest = ProjectOpenRequest(app: .xcode,
                                              itemID: "item",
                                              path: "/Users/test/thing.xcodeproj",
                                              projectName: "thing.xcodeproj")
        let titled = RestoreFixtures.liveWindow(id: 20,
                                                title: "thing.xcodeproj",
                                                frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let documented = RestoreFixtures.liveWindow(id: 21,
                                                    document: "/Users/test/thing.xcodeproj",
                                                    frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        guard case .notYet = ProjectWindowReadiness.resolve(request: xcodeRequest,
                                                            candidates: [titled],
                                                            excluding: [],
                                                            accessibilityGranted: true) else {
            return XCTFail("a matching title alone is not evidence for xcode")
        }
        guard case .ready(let id, _) = ProjectWindowReadiness.resolve(request: xcodeRequest,
                                                                      candidates: [documented],
                                                                      excluding: [],
                                                                      accessibilityGranted: true) else {
            return XCTFail("expected the documented window")
        }
        XCTAssertEqual(id, 21)
    }
}
