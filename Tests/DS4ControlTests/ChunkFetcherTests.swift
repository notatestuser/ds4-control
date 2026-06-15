import XCTest

@testable import DS4Control

final class ChunkFetcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chunkfetcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    func testRejectsHTTP200WhenRangeWasRequested() async throws {
        MockURLProtocol.setHandler { request, proto in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-3")
            proto.respond(status: 200, headers: ["Content-Length": "4"], body: Data("GGUF".utf8))
        }

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let output = dir.appendingPathComponent("model.part")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        do {
            _ = try await ChunkFetcher(session: session).fetch(
                url: URL(string: "https://unit.test/model.gguf")!,
                offset: 0, end: 3, token: nil, fileHandle: handle, onBytes: { _ in })
            XCTFail("HTTP 200 must not satisfy a ranged chunk fetch")
        } catch HFDownloader.Failure.http(let code) {
            XCTAssertEqual(code, 200)
        } catch {
            XCTFail("expected HTTP 200 failure, got \(error)")
        }
    }

    func testLateCompletionFromFailedTaskDoesNotCancelNextFetch() async throws {
        let sequence = RequestSequence()
        MockURLProtocol.setHandler { request, proto in
            switch sequence.next() {
            case 0:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-3")
                proto.respond(
                    status: 500, headers: ["Content-Length": "0"], body: Data(),
                    finishDelay: 150_000_000)
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-7")
                proto.respond(
                    status: 206,
                    headers: ["Content-Range": "bytes 4-7/8", "Content-Length": "4"],
                    body: Data("WXYZ".utf8),
                    startDelay: 300_000_000)
            }
        }

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let output = dir.appendingPathComponent("model.part")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let fetcher = ChunkFetcher(session: session)

        do {
            _ = try await fetcher.fetch(
                url: URL(string: "https://unit.test/model.gguf")!,
                offset: 0, end: 3, token: nil, fileHandle: handle, onBytes: { _ in })
            XCTFail("first request should fail")
        } catch HFDownloader.Failure.http(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("expected first request HTTP 500, got \(error)")
        }

        try handle.seek(toOffset: 4)
        let total = try await fetcher.fetch(
            url: URL(string: "https://unit.test/model.gguf")!,
            offset: 4, end: 7, token: nil, fileHandle: handle, onBytes: { _ in })

        XCTAssertEqual(total, 8)
        try handle.synchronize()
        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.subdata(in: 4..<8), Data("WXYZ".utf8))
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

private final class RequestSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, MockURLProtocol) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var handler: Handler?

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let h = Self.handler
        Self.lock.unlock()
        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        h(request, self)
    }

    override func stopLoading() {}

    func respond(
        status: Int, headers: [String: String], body: Data,
        startDelay: UInt64 = 0, finishDelay: UInt64 = 0
    ) {
        let sendResponse: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { self.client?.urlProtocol(self, didLoad: body) }
            let finish: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if finishDelay == 0 {
                finish()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(finishDelay))) {
                    finish()
                }
            }
        }
        if startDelay == 0 {
            sendResponse()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(startDelay))) {
                sendResponse()
            }
        }
    }
}
