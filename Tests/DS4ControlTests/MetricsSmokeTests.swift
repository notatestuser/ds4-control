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

    /// An idle app (popup closed, nothing running) must stop sampling: deactivating halts the
    /// timer, so no snapshots accumulate even after several intervals — the main thread is not
    /// woken (and not blocked ~100 ms per tick by the power sampler) while nothing watches.
    @MainActor func testInactiveManagerStopsCollecting() async throws {
        let m = MetricsManager()
        m.refreshInterval = 0.05
        m.setActive(true)
        try await Task.sleep(nanoseconds: 300_000_000)  // several ticks while active
        XCTAssertGreaterThan(m.history.snapshots.count, 0, "active collection must sample")

        m.setActive(false)
        XCTAssertFalse(m.isRunning)
        let frozen = m.history.snapshots.count
        try await Task.sleep(nanoseconds: 300_000_000)  // would be ~6 ticks if still running
        XCTAssertEqual(m.history.snapshots.count, frozen, "inactive collection must not sample")
    }
}
