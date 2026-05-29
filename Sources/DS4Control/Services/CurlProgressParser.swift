import Foundation

/// Extract the most recent overall-percent (the "% Total" column) from a chunk
/// of curl `--progress-meter` output. Updates are CR-delimited; return the last.
func parseCurlProgress(_ chunk: String) -> Double? {
    let units = CharacterSet(charactersIn: "0123456789.kKmMgGtTbB:")
    var latest: Double?
    let lines = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
    for line in lines {
        let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let first = tokens.first, let pct = Double(first),
              pct >= 0, pct <= 100, tokens.count >= 2 else { continue }
        // Second token must look like a size (digits + unit), not header text.
        let second = tokens[1]
        guard second.unicodeScalars.allSatisfy({ units.contains($0) }),
              second.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
        latest = pct
    }
    return latest
}
