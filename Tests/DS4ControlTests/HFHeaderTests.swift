import XCTest
@testable import DS4Control

final class HFHeaderTests: XCTestCase {
    private func downloader() -> HFDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderProtocol.self]
        return HFDownloader(
            repo: "test/model", endpoint: "https://headers.invalid", revision: "pinned-revision",
            sessionConfiguration: configuration, probeRetryBackoff: 0)
    }

    func testBoundedPrefixUsesPinnedRevisionAndClosedRange() async throws {
        let data = try await downloader().prefix(file: "valid.gguf", count: 2, expectedBytes: 4, token: "test-token")
        XCTAssertEqual(data, Data("GG".utf8))
    }

    func testRejectsFullResponseWrongRangeAndChangedArtifactSize() async {
        for file in ["full.gguf", "wrong-range.gguf", "changed-size.gguf", "oversized-body.gguf"] {
            do {
                _ = try await downloader().prefix(file: file, count: 2, expectedBytes: 4, token: "test-token")
                XCTFail("accepted invalid response for \(file)")
            } catch {
                XCTAssertTrue(error is HFDownloader.Failure, "unexpected error: \(error)")
            }
        }
    }

    func testPrefixRejectsUnboundedAllocation() async {
        for count in [0, -1, 128 * 1024 * 1024 + 1] {
            do {
                _ = try await downloader().prefix(
                    file: "valid.gguf", count: count, expectedBytes: Int64.max, token: nil)
                XCTFail("accepted invalid prefix length")
            } catch {}
        }
    }
}

private final class HeaderProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url,
            url.path.contains("/resolve/pinned-revision/"),
            request.value(forHTTPHeaderField: "Range") == "bytes=0-1",
            request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let name = url.lastPathComponent
        let range =
            name == "wrong-range.gguf"
            ? "bytes 1-2/4"
            : name == "changed-size.gguf" ? "bytes 0-1/5" : "bytes 0-1/4"
        let response = HTTPURLResponse(
            url: url, statusCode: name == "full.gguf" ? 200 : 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": range])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((name == "oversized-body.gguf" ? "GGUF" : "GG").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
