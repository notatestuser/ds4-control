import XCTest

@testable import DS4Control

final class AgentLauncherTests: XCTestCase {
    func testModelIdPrefersRunningModel() {
        XCTAssertEqual(AgentLauncher.modelId(for: "deepseek-v4-pro", fallback: .flash), "deepseek-v4-pro")
        XCTAssertEqual(AgentLauncher.modelId(for: "deepseek-v4-flash", fallback: .pro), "deepseek-v4-flash")
    }

    func testModelIdFallsBackWhenNilOrUnknown() {
        XCTAssertEqual(AgentLauncher.modelId(for: nil, fallback: .pro), "deepseek-v4-pro")
        // Orphan-attach case: activeModel is a server display name, not a known model id.
        XCTAssertEqual(AgentLauncher.modelId(for: "ds4-server", fallback: .flash), "deepseek-v4-flash")
    }

    func testContextWindowPolicy() {
        XCTAssertEqual(agentContextWindow(ramGiB: 512), 1_000_000)
        XCTAssertEqual(agentContextWindow(ramGiB: 128), 1_000_000)  // >=128 → full 1M
        XCTAssertEqual(agentContextWindow(ramGiB: 96), 393_216)  // below → Think-Max
    }

    func testPiModelsJSONValidAndPointsAtLocalServer() throws {
        let s = AgentLauncher.piModelsJSON(port: 8137, contextWindow: 1_000_000)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(s.utf8)))  // valid JSON
        XCTAssertTrue(s.contains("http://127.0.0.1:8137/v1"))
        XCTAssertTrue(s.contains("\"contextWindow\": 1000000"))
        XCTAssertTrue(s.contains("openai-completions"))
        XCTAssertTrue(s.contains("deepseek-v4-pro"))
        XCTAssertTrue(s.contains("deepseek-v4-flash"))
        XCTAssertTrue(s.contains("thinkingLevelMap"))
    }

    func testWrapperScriptBranchesForBothAgents() {
        let s = AgentLauncher.wrapperScript(
            port: 8137, modelId: "deepseek-v4-flash", contextWindow: 1_000_000,
            piConfigDir: "/tmp/x/pi-agent")
        // Prompts + defaults + normalized effort gate.
        XCTAssertTrue(s.contains("echo \"Launcher script: $0\""))  // shows path, not full contents
        XCTAssertFalse(s.contains("cat \"$0\""))
        XCTAssertTrue(s.contains("Agent [pi/claude] (pi): "))
        XCTAssertTrue(s.contains("agent=pi"))
        XCTAssertTrue(s.contains("Effort [low/medium/high/xhigh] (low): "))
        XCTAssertTrue(s.contains("low|medium|high|xhigh"))
        // Hidden "testoption" choice + install check that gracefully fails when the chosen
        // agent's executable isn't on PATH (testoption never resolves, so it exercises this).
        XCTAssertTrue(s.contains("pi|claude|testoption"))  // accepted, but absent from the [pi/claude] prompt
        XCTAssertFalse(s.contains("[pi/claude/testoption]"))  // stays secret
        XCTAssertTrue(s.contains("command -v \"$agent\""))  // detect whether it's installed
        XCTAssertTrue(s.contains("is not installed"))  // graceful message before exit 1
        // claude branch (no DISABLE_COMPACT — user observes compaction behavior).
        XCTAssertTrue(s.contains("export ANTHROPIC_BASE_URL=\"http://127.0.0.1:8137\""))
        XCTAssertTrue(s.contains("export CLAUDE_CODE_EFFORT_LEVEL=\"$effort\""))
        XCTAssertTrue(s.contains("export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000"))
        XCTAssertTrue(s.contains("export DISABLE_COMPACT=1"))  // required for MAX_CONTEXT_TOKENS to apply
        XCTAssertTrue(s.contains("unset ANTHROPIC_API_KEY"))  // neither mode prompts about a "custom API key"
        XCTAssertTrue(s.contains("\"apiKeyHelper\":\"echo dsv4-local\""))  // dummy key keeps --bare seamless
        XCTAssertFalse(s.contains("--strict-mcp-config"))  // reverted to --bare
        XCTAssertTrue(s.contains("[Y/n]"))  // prompt: launch with --bare?
        XCTAssertTrue(s.contains("exec claude --bare --settings"))  // bare path supplies the dummy key
        XCTAssertTrue(s.contains("exec claude --exclude-dynamic-system-prompt-sections"))  // non-bare path: normal login
        // pi branch.
        XCTAssertTrue(s.contains("export PI_CODING_AGENT_DIR=\"/tmp/x/pi-agent\""))
        XCTAssertTrue(s.contains("exec pi --model ds4/deepseek-v4-flash --thinking \"$effort\""))
    }

    func testAppleScriptRunsWrapperAndActivatesTerminal() {
        let script = AgentLauncher.appleScript(scriptPath: "/tmp/x/agent-launch.sh")
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains(#"do script "'/tmp/x/agent-launch.sh'""#))
    }
}
