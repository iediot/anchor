import XCTest
@testable import anchor

final class ResourceValidationTests: XCTestCase {
    private let present: (String) -> FileStatus = { _ in .present(isDirectory: true) }
    private let missing: (String) -> FileStatus = { _ in .missing }

    func testWebAddressesAreReady() {
        XCTAssertEqual(ResourceValidation.decideTab(url: "https://example.com/a?b=c#d", fileStatus: missing),
                       .web("https://example.com/a?b=c#d"))
        XCTAssertEqual(ResourceValidation.decideTab(url: "http://example.com", fileStatus: missing),
                       .web("http://example.com"))
    }

    func testOrdinaryBlankTabsAreRecognised() {
        for value in ["", "   ", "about:blank", "favorites://", "chrome://newtab/"] {
            XCTAssertEqual(ResourceValidation.decideTab(url: value, fileStatus: missing), .blank, value)
        }
        XCTAssertEqual(ResourceValidation.decideTab(url: nil, fileStatus: missing), .blank)
    }

    // an address anchor cannot name a supported handler for is reported, never opened
    func testOtherSchemesAreUnsupportedRatherThanHandedToTheSystem() {
        for value in ["javascript:alert(1)",
                      "mailto:someone@example.com",
                      "ftp://example.com/file",
                      "x-apple.systempreferences:com.apple.preference.security",
                      "chrome://settings/passwords"] {
            guard case .unsupported = ResourceValidation.decideTab(url: value, fileStatus: missing) else {
                return XCTFail("\(value) must not be treated as restorable")
            }
        }
    }

    func testLocalFileAddressesAreCheckedOnDisk() {
        XCTAssertEqual(ResourceValidation.decideTab(url: "file:///tmp/thing.html", fileStatus: present),
                       .localFile("file:///tmp/thing.html"))
        XCTAssertEqual(ResourceValidation.decideTab(url: "file:///tmp/thing.html", fileStatus: missing),
                       .missing("/tmp/thing.html"))
        XCTAssertEqual(ResourceValidation.decideTab(url: "file:///tmp/thing.html",
                                                    fileStatus: { _ in .inaccessible("no read access") }),
                       .inaccessible("no read access"))
    }

    func testMalformedAddressesAreRefused() {
        guard case .malformed = ResourceValidation.decideTab(url: "not a url at all", fileStatus: missing) else {
            return XCTFail("a bare string is not an address")
        }
        guard case .malformed = ResourceValidation.decideTab(url: "https://", fileStatus: missing) else {
            return XCTFail("a web address with no host is not usable")
        }
        guard case .malformed = ResourceValidation.decideTab(url: "https://example.com/\nsecond", fileStatus: missing) else {
            return XCTFail("a line break must be refused")
        }
        let long = "https://example.com/" + String(repeating: "a", count: 9000)
        guard case .malformed = ResourceValidation.decideTab(url: long, fileStatus: missing) else {
            return XCTFail("an oversized address must be refused")
        }
    }

    func testDirectoriesMustExistAndBeDirectories() {
        XCTAssertEqual(ResourceValidation.decideDirectory("/Users/test/work", fileStatus: present),
                       .ready("/Users/test/work"))
        guard case .missing = ResourceValidation.decideDirectory("/Users/test/work", fileStatus: missing) else {
            return XCTFail("a directory that is gone must be reported missing")
        }
        guard case .malformed = ResourceValidation.decideDirectory("/Users/test/file.txt",
                                                                    fileStatus: { _ in .present(isDirectory: false) }) else {
            return XCTFail("a file is not a working directory")
        }
        guard case .malformed = ResourceValidation.decideDirectory("relative/path", fileStatus: present) else {
            return XCTFail("a relative path must be refused")
        }
        guard case .malformed = ResourceValidation.decideDirectory(nil, fileStatus: present) else {
            return XCTFail("no path recorded must be refused")
        }
    }

    func testProjectPathsAcceptFileUrlsAndTidyThemUp() {
        XCTAssertEqual(ResourceValidation.decideProject("file:///Users/test/proj", fileStatus: present),
                       .ready("/Users/test/proj"))
        XCTAssertEqual(ResourceValidation.decideProject("/Users/test/../test/proj", fileStatus: present),
                       .ready("/Users/test/proj"))
    }

    // the only place shell text is unavoidable, so the quoting is checked directly
    func testShellQuotingSurvivesAwkwardDirectories() {
        XCTAssertEqual(ResourceValidation.singleQuoted("/tmp/plain"), "'/tmp/plain'")
        XCTAssertEqual(ResourceValidation.singleQuoted("/tmp/it's here"), "'/tmp/it'\\''s here'")
        XCTAssertEqual(ResourceValidation.singleQuoted("/tmp/; rm -rf ~"), "'/tmp/; rm -rf ~'")
        XCTAssertEqual(ResourceValidation.singleQuoted("/tmp/$(whoami)"), "'/tmp/$(whoami)'")
    }
}
