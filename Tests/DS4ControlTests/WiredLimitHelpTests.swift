import Foundation
import XCTest

@testable import DS4Control

final class WiredLimitHelpTests: XCTestCase {
    func testOverflowRequirementUsesUnboundedDisplaySentinel() {
        XCTAssertNil(boundedWiredRequirementMB(Int.max))
        XCTAssertEqual(boundedWiredRequirementMB(94_208), 94_208)
    }

    func testPersistenceScriptReplacesSettingAndNormalizesFinalNewline() throws {
        let advisoryMB = 94_208
        let cases = [
            ("", "iogpu.wired_limit_mb=94208\n"),
            ("kern.foo=1\n", "kern.foo=1\niogpu.wired_limit_mb=94208\n"),
            ("kern.foo=1", "kern.foo=1\niogpu.wired_limit_mb=94208\n"),
            (
                "iogpu.wired_limit_mb=1\nkern.foo=1\n iogpu.wired_limit_mb = 2",
                "kern.foo=1\niogpu.wired_limit_mb=94208\n"
            ),
        ]

        for (input, expected) in cases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("sysctl.conf")
            try Data(input.utf8).write(to: file)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c", wiredLimitPersistenceScript(advisoryMB: advisoryMB), "sh", file.path,
            ]
            try process.run()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0, "input: \(input.debugDescription)")
            XCTAssertEqual(
                try String(contentsOf: file, encoding: .utf8), expected,
                "input: \(input.debugDescription)")
        }
    }

    func testPersistenceCommandTargetsSystemConfiguration() {
        let command = wiredLimitPersistenceCommand(advisoryMB: 94_208)
        XCTAssertTrue(command.hasPrefix("sudo sh -c '"))
        XCTAssertTrue(command.hasSuffix("' sh /etc/sysctl.conf"))
        XCTAssertTrue(command.contains("iogpu.wired_limit_mb=94208"))
    }
}
