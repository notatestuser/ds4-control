import AppKit
import XCTest
@testable import DS4Control

@MainActor
private final class FakeQuitSupervisor: ServerQuitSupervising {
    var state: ServerState
    private(set) var stopCallCount = 0
    private var completion: ((Bool) -> Void)?

    init(state: ServerState) {
        self.state = state
    }

    func stopForTermination(completion: ((Bool) -> Void)?) {
        stopCallCount += 1
        self.completion = completion
        state = .stopping
    }

    func finishStop(success: Bool) {
        state = success ? .idle : .ready
        let completion = completion
        self.completion = nil
        completion?(success)
    }
}

@MainActor
final class AppTerminationCoordinatorTests: XCTestCase {
    private func makeApp() -> AppState {
        AppState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    func testIrrelevantStatesQuitImmediatelyWithoutConsumingPrompt() {
        for state in [ServerState.idle, .downloading, .error(.badState(message: "test"))] {
            let app = makeApp()
            let supervisor = FakeQuitSupervisor(state: state)
            var promptCount = 0
            let coordinator = AppTerminationCoordinator(
                app: app, supervisor: supervisor,
                presentChoice: {
                    promptCount += 1; return .alwaysStop
                })

            XCTAssertEqual(coordinator.applicationShouldTerminate { _ in XCTFail("unexpected reply") }, .terminateNow)
            XCTAssertEqual(promptCount, 0)
            XCTAssertEqual(supervisor.stopCallCount, 0)
            XCTAssertFalse(app.quitBehaviorChosen)
        }
    }

    func testKeepRunningChoicePersistsAndQuitsImmediately() {
        let app = makeApp()
        let supervisor = FakeQuitSupervisor(state: .ready)
        var promptCount = 0
        let coordinator = AppTerminationCoordinator(
            app: app, supervisor: supervisor,
            presentChoice: {
                promptCount += 1; return .keepRunning
            })

        XCTAssertEqual(coordinator.applicationShouldTerminate { _ in XCTFail("unexpected reply") }, .terminateNow)
        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(app.quitBehaviorChosen)
        XCTAssertFalse(app.stopServerOnQuit)
        XCTAssertEqual(supervisor.stopCallCount, 0)

        XCTAssertEqual(coordinator.applicationShouldTerminate { _ in XCTFail("unexpected reply") }, .terminateNow)
        XCTAssertEqual(promptCount, 1)
    }

    func testCancelKeepsAppRunningWithoutRecordingAChoice() {
        let app = makeApp()
        let supervisor = FakeQuitSupervisor(state: .ready)
        let coordinator = AppTerminationCoordinator(
            app: app, supervisor: supervisor,
            presentChoice: { .cancel })

        XCTAssertEqual(
            coordinator.applicationShouldTerminate { _ in XCTFail("unexpected reply") },
            .terminateCancel)
        XCTAssertFalse(app.quitBehaviorChosen)
        XCTAssertFalse(app.stopServerOnQuit)
        XCTAssertEqual(supervisor.stopCallCount, 0)
    }

    func testQuitAlertMakesAlwaysStopDefaultAndCancelEscapable() {
        let alert = AppTerminationCoordinator.makeQuitBehaviorAlert()

        XCTAssertEqual(alert.messageText, "Stop ds4-server when DS4 Control quits?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Always Stop", "Keep Running", "Cancel"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "", "\u{1b}"])
        XCTAssertEqual(
            AppTerminationCoordinator.quitBehaviorChoice(for: .alertFirstButtonReturn),
            .alwaysStop)
        XCTAssertEqual(
            AppTerminationCoordinator.quitBehaviorChoice(for: .alertSecondButtonReturn),
            .keepRunning)
        XCTAssertEqual(
            AppTerminationCoordinator.quitBehaviorChoice(for: .alertThirdButtonReturn),
            .cancel)
    }

    func testAlwaysStopChoiceDefersQuitUntilConfirmedExit() async {
        let app = makeApp()
        let supervisor = FakeQuitSupervisor(state: .starting)
        var promptCount = 0
        let replied = expectation(description: "termination reply")
        var replyValue: Bool?
        let coordinator = AppTerminationCoordinator(
            app: app, supervisor: supervisor,
            presentChoice: {
                promptCount += 1; return .alwaysStop
            })

        let result = coordinator.applicationShouldTerminate {
            replyValue = $0
            replied.fulfill()
        }

        XCTAssertEqual(result, .terminateLater)
        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(app.stopServerOnQuit)
        XCTAssertTrue(app.quitBehaviorChosen)
        XCTAssertEqual(supervisor.stopCallCount, 1)
        supervisor.finishStop(success: true)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replyValue, true)
    }

    func testExistingStopPolicySkipsPromptAndCoalescesRepeatedQuit() async {
        let app = makeApp()
        app.setStopServerOnQuit(true)
        let supervisor = FakeQuitSupervisor(state: .ready)
        var promptCount = 0
        let replied = expectation(description: "termination reply")
        var secondReplyCalled = false
        let coordinator = AppTerminationCoordinator(
            app: app, supervisor: supervisor,
            presentChoice: {
                promptCount += 1; return .keepRunning
            })

        XCTAssertEqual(
            coordinator.applicationShouldTerminate { value in
                XCTAssertTrue(value)
                replied.fulfill()
            },
            .terminateLater)
        XCTAssertEqual(
            coordinator.applicationShouldTerminate { _ in secondReplyCalled = true },
            .terminateLater)
        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(supervisor.stopCallCount, 1)

        supervisor.finishStop(success: true)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertFalse(secondReplyCalled)
    }

    func testAlreadyStoppingWaitsWithoutPrompt() async {
        let app = makeApp()
        let supervisor = FakeQuitSupervisor(state: .stopping)
        var promptCount = 0
        let replied = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            app: app, supervisor: supervisor,
            presentChoice: {
                promptCount += 1; return .keepRunning
            })

        XCTAssertEqual(
            coordinator.applicationShouldTerminate { value in
                XCTAssertTrue(value)
                replied.fulfill()
            },
            .terminateLater)
        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(supervisor.stopCallCount, 1)
        XCTAssertFalse(app.quitBehaviorChosen)

        supervisor.finishStop(success: true)
        await fulfillment(of: [replied], timeout: 1)
    }

    func testStopFailureCancelsQuitAndSurfacesFailure() async {
        let app = makeApp()
        app.setStopServerOnQuit(true)
        let supervisor = FakeQuitSupervisor(state: .ready)
        var failureCount = 0
        let replied = expectation(description: "termination cancellation reply")
        var replyValue: Bool?
        let coordinator = AppTerminationCoordinator(
            app: app, supervisor: supervisor,
            presentStopFailure: { failureCount += 1 })

        XCTAssertEqual(
            coordinator.applicationShouldTerminate {
                replyValue = $0
                replied.fulfill()
            },
            .terminateLater)
        supervisor.finishStop(success: false)
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(replyValue, false)
        XCTAssertEqual(failureCount, 1)
    }
}
