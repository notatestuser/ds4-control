import Foundation

enum Architecture {
    static let isAppleSilicon: Bool = {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &ret, &size, nil, 0)
        return result == 0 && ret == 1
    }()
}
