import Foundation

enum ServerError: Equatable {
    case ds4DirInvalid(missing: String)
    case modelMissing(filename: String)
    case startupTimeout
    case unhealthy
    case crashed(tail: String)
    case downloadFailed(detail: String)
    case badState(message: String)
    case configurationBlocked(reason: String)
    /// start() refused: the launch config's GPU-wired working set exceeds the effective
    /// Metal wired limit and the override wasn't passed. `requiredMB`/`advisoryMB` match
    /// `Feasibility.wiredLimitTooLow` so the UI can point at the help window.
    case wiredLimitTooLow(requiredMB: Int, advisoryMB: Int)
}

enum ServerState: Equatable {
    case idle
    case downloading
    case starting
    case ready
    case stopping
    case error(ServerError)
}

struct DownloadProgress: Equatable {
    let pct: Double
    let file: String
    let receivedBytes: Int64
    let totalBytes: Int64?
    /// Human-readable transfer rate (e.g. "213MB/s"), or nil if unknown.
    let rate: String?
    /// Live downloader connection count (the ramped worker pool), or nil when unknown.
    let connections: Int?

    init(
        pct: Double, file: String, receivedBytes: Int64, totalBytes: Int64?, rate: String? = nil,
        connections: Int? = nil
    ) {
        self.pct = min(max(pct, 0), 100)
        self.file = file
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.rate = rate
        self.connections = connections
    }
}

/// Progress of a digest-verification pass (minutes-long on the V4.1 quants), surfaced in the
/// popup so a verification never reads as a stalled download.
struct VerificationProgress: Equatable {
    /// Phase, e.g. "Verifying part 1 of 2…" or "Verifying the joined file…".
    let label: String
    /// 0–100.
    let pct: Double
    let processedBytes: Int64
    let totalBytes: Int64
}

struct HealthStatus: Equatable {
    let ok: Bool
    let latencyMs: Int
}
