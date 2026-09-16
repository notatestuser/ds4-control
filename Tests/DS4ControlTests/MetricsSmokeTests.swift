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

    /// Hiding the popup must not stop sampling — that would leave a hole in the graphs — it
    /// drops to a slow background cadence instead, so reopening shows a continuous series.
    /// The hidden cadence must stay far below the visible one (no idle main-thread churn).
    @MainActor func testHiddenManagerSamplesSlowly() async throws {
        let m = MetricsManager()
        m.refreshInterval = 0.05
        m.backgroundRefreshInterval = 0.25
        m.setActive(true)
        try await Task.sleep(nanoseconds: 500_000_000)  // several fast ticks while visible
        let visibleCount = m.history.snapshots.count
        XCTAssertGreaterThan(visibleCount, 3, "visible collection must sample at the fast cadence")

        m.setActive(false)
        let hiddenStart = m.history.snapshots.count
        // Generous window: the first slow tick (0.25 s) must land well inside it even with
        // ~100 ms blocking collects and CI scheduling jitter; a straggler fast tick may add
        // one more, hence the relaxed upper bound (fast mode would produce ≥6 here).
        try await Task.sleep(nanoseconds: 600_000_000)
        let hiddenGrowth = m.history.snapshots.count - hiddenStart
        XCTAssertGreaterThan(hiddenGrowth, 0, "hidden sampling must continue — no graph holes")
        XCTAssertLessThanOrEqual(hiddenGrowth, 4, "hidden sampling must use the slow cadence")
    }
}
