import XCTest
@testable import Plans

/// Tests for the `String.titleized()` helper that turns a raw project directory
/// name (hyphenated, underscored, or camelCase) into a human-readable title.
/// Pure value assertions, mirroring `TaskStatusGlanceTests`.
final class StringTitleizeTests: XCTestCase {

    func testHyphenSeparator() {
        XCTAssertEqual("plans-desktop".titleized(), "Plans Desktop")
    }

    func testUnderscoreSeparator() {
        XCTAssertEqual("my_project_name".titleized(), "My Project Name")
    }

    func testMixedSeparators() {
        XCTAssertEqual("my-project_name".titleized(), "My Project Name")
    }

    func testCamelCase() {
        XCTAssertEqual("PlansDesktop".titleized(), "Plans Desktop")
    }

    func testSingleWord() {
        XCTAssertEqual("plans".titleized(), "Plans")
    }

    func testEmptyString() {
        XCTAssertEqual("".titleized(), "")
    }
}
