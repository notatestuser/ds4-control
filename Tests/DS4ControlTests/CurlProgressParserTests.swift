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

    // hf / tqdm download output (download_model.sh now uses `hf download`).
    func testHfTqdmLine() {
        let line = "DeepSeek-V4-Pro-…-imatrix.gguf:  37%|███▋      | 159G/430G [12:34<21:10, 213MB/s]"
        XCTAssertEqual(parseCurlProgress(line) ?? .nan, 37, accuracy: 0.001)
    }
    func testHfTqdmLatestOfMany() {
        let buf =
            "file.gguf:   3%|▎ | 13G/430G\rfile.gguf:  41%|████ | 176G/430G\rfile.gguf: 100%|██████████| 430G/430G"
        XCTAssertEqual(parseCurlProgress(buf) ?? .nan, 100, accuracy: 0.001)
    }
    func testHfTqdmNoFalsePositiveOnSpeed() {
        // "213MB/s" etc. must not be read as a percent; only the NN% token counts.
        let line = "file.gguf:   5%|▌ | 21G/430G [01:00<19:00, 336MB/s]"
        XCTAssertEqual(parseCurlProgress(line) ?? .nan, 5, accuracy: 0.001)
    }
    func testFetchingSummaryIgnored() {
        // hf prints a file-count summary that hits 100% before the blob download begins;
        // it has no byte-size token, so it must not jump the bar to 100%.
        XCTAssertNil(parseCurlProgress("Fetching 1 files:   0%|          | 0/1"))
        XCTAssertNil(parseCurlProgress("Fetching 1 files: 100%|██████████| 1/1 [00:00<00:00]"))
    }

    // Transfer-rate extraction for the popup.
    func testRateFromTqdmLine() {
        let line = "file.gguf:  37%|███▋ | 159G/430G [12:34<21:10, 213MB/s]"
        XCTAssertEqual(parseDownloadRate(line), "213MB/s")
    }
    func testRateLatestOfMany() {
        let buf = "f:  3%| 13G/430G, 90MB/s\rf:  41%| 176G/430G, 1.2GB/s"
        XCTAssertEqual(parseDownloadRate(buf), "1.2GB/s")
    }
    func testRateDecimalAndKilo() {
        XCTAssertEqual(parseDownloadRate("f:  9%| 4G/430G, 850kB/s]"), "850kB/s")
    }
    func testRateNilWhenAbsent() {
        XCTAssertNil(parseDownloadRate(" 14 80.8G  14 11.5G  85.2M  0:13:54 85.1M"))
        XCTAssertNil(parseDownloadRate(""))
    }
}
