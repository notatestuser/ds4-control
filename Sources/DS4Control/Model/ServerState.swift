import Foundation

enum ServerError: Equatable {
    case ds4DirInvalid(missing: String)
    case modelMissing(filename: String)
    case startupTimeout
    case unhealthy
    case crashed(tail: String)
    case downloadFailed(detail: String)
    case badState(message: String)
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

    init(pct: Double, file: String, receivedBytes: Int64, totalBytes: Int64?) {
        self.pct = min(max(pct, 0), 100)
        self.file = file
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

struct HealthStatus: Equatable {
    let ok: Bool
    let latencyMs: Int
}
