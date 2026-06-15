import Foundation

enum ModelFileValidationError: Error, Equatable, CustomStringConvertible {
    case missing
    case tooSmall(actual: Int64, minimum: Int64)
    case wrongSize(actual: Int64, expected: Int64)
    case badMagic

    var description: String {
        switch self {
        case .missing:
            return "file is missing"
        case let .tooSmall(actual, minimum):
            return "file is too small (\(actual) bytes, expected at least \(minimum))"
        case let .wrongSize(actual, expected):
            return "file size is \(actual) bytes, expected \(expected)"
        case .badMagic:
            return "file is not a GGUF"
        }
    }
}

enum ModelFileValidator {
    private static let ggufMagic = Data("GGUF".utf8)
    private static let minimumSizeFactor = 0.90

    static func minimumBytes(for quant: Quant) -> Int64 {
        Int64((quant.weightsGiB * 1_073_741_824 * minimumSizeFactor).rounded(.down))
    }

    static func validateGGUF(
        at url: URL, minimumBytes: Int64? = nil, exactBytes: Int64? = nil
    ) -> Result<Void, ModelFileValidationError> {
        guard let size = fileSize(url) else { return .failure(.missing) }
        if let exactBytes, size != exactBytes {
            return .failure(.wrongSize(actual: size, expected: exactBytes))
        }
        if let minimumBytes, size < minimumBytes {
            return .failure(.tooSmall(actual: size, minimum: minimumBytes))
        }
        guard let magic = readPrefix(url, count: ggufMagic.count), magic == ggufMagic else {
            return .failure(.badMagic)
        }
        return .success(())
    }

    static func isValidGGUF(at url: URL, minimumBytes: Int64? = nil, exactBytes: Int64? = nil) -> Bool {
        if case .success = validateGGUF(at: url, minimumBytes: minimumBytes, exactBytes: exactBytes) {
            return true
        }
        return false
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    private static func readPrefix(_ url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }
}
