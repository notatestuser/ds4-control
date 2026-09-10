import Foundation

/// One server-side generation-speed sample parsed from ds4-server's stderr.
struct ServerSpeedSnapshot: Equatable {
    enum Phase: Equatable {
        case prefill, decode, idle
    }
    var phase: Phase
    /// tokens/sec from the line's `avg=` value (prefill/decode).
    var tokensPerSecond: Double?
    /// Completed/decoded token count from `gen=N`.
    var tokens: Int?
}

/// Pure parser for ds4-server's per-request stderr timing lines (covers built-in
/// chat AND coding agents, since it reads the server's own log):
///
///   "… chat ctx=0..52:52 prefill chunk 52/52 (100.0%) chunk=0.00 t/s avg=67.91 t/s 0.766s"
///   "… chat ctx=52..57:5 gen=5 decoding chunk=41.40 t/s avg=41.40 t/s 0.121s"
///   "… chat ctx=0..52:52 gen=5 finish=stop 0.887s"
///
/// Returns a snapshot for matching lines, nil otherwise. The per-batch
/// `decode batch count=…` lines are deliberately ignored (MTP batches, and
/// multi-session requests interleave on them); the per-request lines are the
/// clean tok/s signal.
enum ServerSpeedParser {
    private static let decodeRegex = try! NSRegularExpression(
        pattern: #"gen=(\d+) decoding chunk=[\d.]+ t/s avg=([\d.]+) t/s"#)
    private static let prefillRegex = try! NSRegularExpression(
        pattern: #"prefill chunk \S+ \(\d+(?:\.\d+)?%\) chunk=[\d.]+ t/s avg=([\d.]+) t/s"#)
    private static let finishRegex = try! NSRegularExpression(
        pattern: #"gen=(\d+) finish=\S+"#)

    static func feed(_ line: String) -> ServerSpeedSnapshot? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = decodeRegex.firstMatch(in: line, range: full),
            let n = Int(m.capture(1, in: line)),
            let tps = Double(m.capture(2, in: line))
        {
            return ServerSpeedSnapshot(phase: .decode, tokensPerSecond: tps, tokens: n)
        }
        if let m = prefillRegex.firstMatch(in: line, range: full),
            let tps = Double(m.capture(1, in: line))
        {
            return ServerSpeedSnapshot(phase: .prefill, tokensPerSecond: tps, tokens: nil)
        }
        if let m = finishRegex.firstMatch(in: line, range: full),
            let n = Int(m.capture(1, in: line))
        {
            return ServerSpeedSnapshot(phase: .idle, tokensPerSecond: nil, tokens: n)
        }
        return nil
    }
}

private extension NSTextCheckingResult {
    func capture(_ idx: Int, in string: String) -> String {
        guard idx < numberOfRanges else { return "" }
        let r = range(at: idx)
        guard r.location != NSNotFound else { return "" }
        return (string as NSString).substring(with: r)
    }
}
