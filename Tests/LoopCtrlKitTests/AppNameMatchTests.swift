import XCTest

final class AppNameMatchTests: XCTestCase {
    private func app(_ name: String, _ bid: String, _ from: String = "installed") -> AppNameMatch.App {
        .init(bundleId: bid, name: name, from: from)
    }

    private lazy var installed = [
        app("Idol Ludo Board", "com.ex.idolludo"), app("Settings", "com.apple.Preferences"),
        app("微信", "com.tencent.xin"), app("微信读书", "com.tencent.weread"),
        app("Google Maps", "com.google.Maps"), app("Maps", "com.apple.Maps"),
        app("Trip.com", "ctrip.english"),
    ]

    func testWholeNameWinsOverPartOfAnother() {
        // "微信" is also part of "微信读书": the exact name decides.
        XCTAssertEqual(AppNameMatch.best("微信", pools: [installed]), .one(installed[2], how: "exact"))
        XCTAssertEqual(AppNameMatch.best("maps", pools: [installed]), .one(installed[5], how: "exact"))
        XCTAssertEqual(AppNameMatch.best("settings ", pools: [installed]), .one(installed[1], how: "exact"))
    }

    func testStartsOfWordsAndInitials() {
        XCTAssertEqual(AppNameMatch.best("idol ludo", pools: [installed]), .one(installed[0], how: "words"))
        XCTAssertEqual(AppNameMatch.best("ilb", pools: [installed]), .one(installed[0], how: "initials"))
        XCTAssertEqual(AppNameMatch.best("google m", pools: [installed]), .one(installed[4], how: "words"))
    }

    func testPartOfNameOnlyWhenUnique() {
        XCTAssertEqual(AppNameMatch.best("读书", pools: [installed]), .one(installed[3], how: "contains"))
        // "a" is too short to mean anything; "ma" is in both Maps apps.
        XCTAssertEqual(AppNameMatch.best("a", pools: [installed]), .none)
        guard case .several(let apps) = AppNameMatch.best("ma", pools: [installed]) else { return XCTFail("guessed") }
        XCTAssertEqual(Set(apps.map(\.bundleId)), ["com.google.Maps", "com.apple.Maps"])
    }

    func testCatalogOnlyWhenNothingOnThePhoneMatches() {
        let catalog = [app("Settings Plus", "com.ex.settingsplus", "catalog"), app("Notion", "notion.id", "catalog")]
        XCTAssertEqual(AppNameMatch.best("settings", pools: [installed, catalog]), .one(installed[1], how: "exact"))
        XCTAssertEqual(AppNameMatch.best("notion", pools: [installed, catalog]), .one(catalog[1], how: "exact"))
        XCTAssertEqual(AppNameMatch.best("nothing like it", pools: [installed, catalog]), .none)
    }
}
