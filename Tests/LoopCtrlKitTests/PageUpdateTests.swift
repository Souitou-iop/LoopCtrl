import CryptoKit
import XCTest

final class PageUpdateTests: XCTestCase {
    func testBuiltInVersionIsTheBuildTime() {
        // "2026-10-09 12:46" → 202610091246, comparable with a pushed page's version.
        XCTAssertEqual(String(PageUpdate.builtInVersion), BuildStamp.value.filter(\.isNumber))
        XCTAssertGreaterThan(PageUpdate.builtInVersion, 2020_01_01_0000)
    }

    /// Only the project's page key signs pages: another key's signature, a
    /// changed page or a changed version are all refused.
    func testOnlyThePageKeyIsAccepted() throws {
        let other = Curve25519.Signing.PrivateKey()
        let html = "<!doctype html><title>x</title>"
        let sig = try other.signature(for: PageUpdate.message(html: html, version: 202701010000))
        XCTAssertFalse(PageUpdate.verify(html: html, version: 202701010000, signature: sig.hexString))
        XCTAssertFalse(PageUpdate.verify(html: html, version: 202701010000, signature: "zz"))
        XCTAssertFalse(PageUpdate.verify(html: html, version: 202701010000, signature: ""))
    }

    func testTheSignedMessageCoversVersionAndPage() {
        let a = PageUpdate.message(html: "a", version: 1), b = PageUpdate.message(html: "b", version: 1)
        let c = PageUpdate.message(html: "a", version: 2)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(String(decoding: a, as: UTF8.self).hasPrefix("loopctrl-page-v1\n1\n"))
    }
}
