import XCTest

@testable import DS4Control

final class PiLauncherTests: XCTestCase {
    func testModelSpecPrefersRunningModel() {
        XCTAssertEqual(PiLauncher.modelSpec(for: "deepseek-v4-pro", fallback: .flash), "ds4/deepseek-v4-pro")
        XCTAssertEqual(PiLauncher.modelSpec(for: "deepseek-v4-flash", fallback: .pro), "ds4/deepseek-v4-flash")
    }

    func testModelSpecFallsBackWhenNilOrUnknown() {
        XCTAssertEqual(PiLauncher.modelSpec(for: nil, fallback: .pro), "ds4/deepseek-v4-pro")
        XCTAssertEqual(PiLauncher.modelSpec(for: nil, fallback: .flash), "ds4/deepseek-v4-flash")
        // Orphan-attach case: activeModel is a server display name, not a known model id.
        XCTAssertEqual(PiLauncher.modelSpec(for: "ds4-server", fallback: .pro), "ds4/deepseek-v4-pro")
    }

    func testAppleScriptRunsPiAndActivatesTerminal() {
        let script = PiLauncher.appleScript(modelSpec: "ds4/deepseek-v4-pro")
        XCTAssertTrue(script.contains(#"do script "pi --model ds4/deepseek-v4-pro""#))
        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
    }
}
