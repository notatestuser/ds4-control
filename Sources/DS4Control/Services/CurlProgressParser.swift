import Foundation

/// Extract the most recent download percentage (0–100) from a chunk of
/// downloader output. Handles both formats `download_model.sh` may emit:
///   • `hf` / tqdm style — a `NN%` token (e.g. `…gguf: 37%|███▋ | 159G/430G …`)
///   • curl `--progress-meter` style — first whitespace column is the percent,
///     second column is a size (legacy path, kept for compatibility).
/// Updates are CR/LF-delimited; the last valid percentage wins.
func parseCurlProgress(_ chunk: String) -> Double? {
    let units = CharacterSet(charactersIn: "0123456789.kKmMgGtTbB:")
    var latest: Double?
    let lines = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
    for line in lines {
        // hf / tqdm style: a "NN%" token anywhere in the line.
        if let pct = lastPercentToken(in: line) {
            latest = pct
            continue
        }
        // curl --progress-meter style: first token is the percent, second a size.
        let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let first = tokens.first, let pct = Double(first),
            pct >= 0, pct <= 100, tokens.count >= 2
        else { continue }
        // Second token must look like a size (digits + unit), not header text.
        let second = tokens[1]
        guard second.unicodeScalars.allSatisfy({ units.contains($0) }),
            second.rangeOfCharacter(from: .decimalDigits) != nil
        else { continue }
        latest = pct
    }
    return latest
}

/// The last `NN%` (or `NN.N%`) percentage token in a line, clamped to 0...100,
/// or nil if none. Matches digits (optionally with a decimal point) immediately
/// followed by `%`, so curl's `% Total` header (no preceding digit) is ignored.
private func lastPercentToken(in line: Substring) -> Double? {
    var result: Double?
    var digits = ""
    for ch in line {
        if ch.isNumber || ch == "." {
            digits.append(ch)
        } else if ch == "%" {
            if let v = Double(digits), v >= 0, v <= 100 { result = v }
            digits = ""
        } else {
            digits = ""
        }
    }
    return result
}
