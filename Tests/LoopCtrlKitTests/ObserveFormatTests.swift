import XCTest

final class ObserveFormatTests: XCTestCase {
    func testStripsTrailingFrame() {
        let line = "Button, label: '关于本机', id: 'com.apple.settings.general.about', {{16, 385}, {370, 52}}"
        XCTAssertEqual(ObserveFormat.compact(line), "Button, label: '关于本机', id: 'com.apple.settings.general.about'")
    }

    func testLabelContainingBracesKeepsLabelDropsOnlyFrame() {
        let line = "StaticText, label: 'a {{b}}', {{1, 2}, {3, 4}}"
        XCTAssertEqual(ObserveFormat.compact(line), "StaticText, label: 'a {{b}}'")
    }

    func testDropsEmptyLinesAndIndent() {
        let body = "Application, label: '设置', {{0, 0}, {402, 874}}\n\n  Window, {{0, 0}, {402, 874}}\n"
        XCTAssertEqual(ObserveFormat.compact(body), "Application, label: '设置'\nWindow")
    }
}
