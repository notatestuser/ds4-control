import XCTest
@testable import DS4Control

final class MetricsSmokeTests: XCTestCase {
    @MainActor func testCollectProducesSnapshot() {
        let m = MetricsManager()
        m.collect()
        let snap = m.currentSnapshot
        XCTAssertNotNil(snap)
        XCTAssertGreaterThan(snap!.memory.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(snap!.cpu.totalUsage, 0)
        // power may be nil in CI VMs — do not assert it is present.
    }
}
