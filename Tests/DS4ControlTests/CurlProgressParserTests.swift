import XCTest
@testable import DS4Control

final class CurlProgressParserTests: XCTestCase {
    func testSingleLine() {
        let line = " 14 80.8G   14 11.5G    0     0  85.2M      0  0:16:12  0:02:18  0:13:54 85.1M"
        XCTAssertEqual(parseCurlProgress(line) ?? .nan, 14, accuracy: 0.001)
    }
    func testLatestOfMany() {
        let buf = " 14 80.8G   14 11.5G ...\r 37 80.8G   37 29.9G ...\r 100 80.8G  100 80.8G ..."
        XCTAssertEqual(parseCurlProgress(buf) ?? .nan, 100, accuracy: 0.001)
    }
    func testHeaderIgnored() {
        let header = "  % Total    % Received % Xferd  Average Speed   Time"
        XCTAssertNil(parseCurlProgress(header))
    }
    func testEmpty() { XCTAssertNil(parseCurlProgress("")) }
}
