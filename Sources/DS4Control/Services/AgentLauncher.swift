import Foundation

/// Opens Terminal.app running a coding agent (pi or claude) against the local ds4 server.
/// A generated wrapper prompts for agent + thinking effort + directory, then launches the
/// chosen CLI: claude via `ANTHROPIC_*` env vars, pi via a bundled `models.json`
/// (`PI_CODING_AGENT_DIR`). Port and context window are baked in at click time.
enum AgentLauncher {
    /// Model ids ds4-server exposes; used to prefer the server's reported model.
    static let knownModelIds = ["deepseek-v4-pro", "deepseek-v4-flash"]

    /// The running model id (e.g. "deepseek-v4-flash"). Prefers the server's reported
    /// `activeModel` when it is a known id; otherwise the selected variant's id (covers the
    /// orphan-attach case where `activeModel` is a server display name).
    static func modelId(for activeModel: String?, fallback: Variant) -> String {
        activeModel.flatMap { knownModelIds.contains($0) ? $0 : nil } ?? fallback.modelId
    }

    /// pi's `ds4` provider config, written to `PI_CODING_AGENT_DIR/models.json`. Mirrors the
    /// upstream schema; `baseUrl` port and per-model `contextWindow` are substituted live so
    /// pi tracks the running server without depending on the user's `~/.pi`.
    static func piModelsJSON(port: Int, contextWindow: Int) -> String {
        let levelMap =
            #"{ "off": null, "minimal": "low", "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh" }"#
        return """
        {
          "providers": {
            "ds4": {
              "name": "ds4.c local",
              "baseUrl": "http://127.0.0.1:\(port)/v1",
              "api": "openai-completions",
              "apiKey": "dsv4-local",
              "compat": {
                "supportsStore": false,
                "supportsDeveloperRole": false,
                "supportsReasoningEffort": true,
                "supportsUsageInStreaming": true,
                "maxTokensField": "max_tokens",
                "supportsStrictMode": false,
                "thinkingFormat": "deepseek",
                "requiresReasoningContentOnAssistantMessages": true
              },
              "models": [
                {
                  "id": "deepseek-v4-pro",
                  "name": "DeepSeek V4 Pro (ds4.c local)",
                  "reasoning": true,
                  "thinkingLevelMap": \(levelMap),
                  "input": ["text"],
                  "contextWindow": \(contextWindow),
                  "maxTokens": 393216,
                  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
                },
                {
                  "id": "deepseek-v4-flash",
                  "name": "DeepSeek V4 Flash (ds4.c local)",
                  "reasoning": true,
                  "thinkingLevelMap": \(levelMap),
                  "input": ["text"],
                  "contextWindow": \(contextWindow),
                  "maxTokens": 393216,
                  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
                }
              ]
            }
          }
        }
        """
    }

    /// Wrapper script: prints its own path (so the user can read it), prompts for agent (default pi) / effort
    /// (default low) / directory (default cwd), then launches the chosen CLI against the local
    /// server. Effort is normalized to the claude∩pi set (low/medium/high/xhigh) so the same
    /// input works for either. `port`/`modelId`/`contextWindow`/`piConfigDir` are baked in.
    static func wrapperScript(port: Int, modelId: String, contextWindow: Int, piConfigDir: String) -> String {
        """
        #!/bin/sh
        echo "Launcher script: $0"
        echo
        printf 'Agent [pi/claude] (pi): '
        read agent
        [ -n "$agent" ] || agent=pi
        case "$agent" in pi|claude|testoption) ;; *) echo "unknown agent '$agent' — using pi"; agent=pi ;; esac
        # testoption is a hidden choice (never installed) for exercising this not-installed path.
        if ! command -v "$agent" >/dev/null 2>&1; then
          echo "'$agent' is not installed or not on your PATH. Please install it, then run this again."
          exit 1
        fi
        printf 'Effort [low/medium/high/xhigh] (low): '
        read effort
        [ -n "$effort" ] || effort=low
        case "$effort" in low|medium|high|xhigh) ;; *) echo "unknown effort '$effort' — using low"; effort=low ;; esac
        printf 'Start in [%s]: ' "$PWD"
        read dir
        [ -n "$dir" ] || dir=$PWD
        case "$dir" in
          "~") dir=$HOME ;;
          "~/"*) dir=$HOME/${dir#"~/"} ;;
        esac
        cd "$dir" || { echo "cd failed: $dir"; exit 1; }
        if [ "$agent" = claude ]; then
          # Optionally use --bare: skips hooks, plugins, LSP and MCP (CLAUDE_CODE_SIMPLE=1) —
          # much faster against a local model. In bare mode auth is strictly ANTHROPIC_API_KEY
          # or apiKeyHelper (your OAuth login is ignored), so we unset ANTHROPIC_API_KEY (no
          # "custom API key" prompt) and feed a dummy key via apiKeyHelper — seamless; the local
          # server ignores the key. Non-bare keeps your normal login.
          printf 'Use claude --bare for speed? Skips MCP/hooks/plugins/memory — faster on a local model [Y/n]: '
          read bare
          unset ANTHROPIC_API_KEY
          export ANTHROPIC_BASE_URL="http://127.0.0.1:\(port)"
          export ANTHROPIC_MODEL="\(modelId)"
          export CLAUDE_CODE_EFFORT_LEVEL="$effort"
          export CLAUDE_CODE_MAX_CONTEXT_TOKENS=\(contextWindow)
          export DISABLE_COMPACT=1
          case "$bare" in
            [Nn]*) exec claude --exclude-dynamic-system-prompt-sections "say hi (first prompt will take some time)" ;;
            *) exec claude --bare --settings '{"apiKeyHelper":"echo dsv4-local"}' --exclude-dynamic-system-prompt-sections "say hi (first prompt will take some time)" ;;
          esac
        else
          export PI_CODING_AGENT_DIR="\(piConfigDir)"
          exec pi --model ds4/\(modelId) --thinking "$effort" "say hi (first prompt will take some time)"
        fi
        """
    }

    /// AppleScript that opens Terminal and runs the wrapper at `scriptPath`. The path is
    /// single-quoted for the shell (the App Support dir contains spaces); it never contains a
    /// single quote, so there is no injection surface.
    static func appleScript(scriptPath: String) -> String {
        """
        tell application "Terminal"
            activate
            do script "'\(scriptPath)'"
        end tell
        """
    }

    /// Regenerate the pi provider config + the wrapper (so port/context track the running
    /// server), then open Terminal running the wrapper via `osascript`.
    static func launch(port: Int, modelId: String, ramGiB: Double) {
        let cw = agentContextWindow(ramGiB: ramGiB)
        let support = ds4AppSupportDir()
        let piDir = support.appendingPathComponent("pi-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        try? piModelsJSON(port: port, contextWindow: cw)
            .write(to: piDir.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        let url = support.appendingPathComponent("agent-launch.sh")
        do {
            try wrapperScript(port: port, modelId: modelId, contextWindow: cw, piConfigDir: piDir.path)
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(scriptPath: url.path)]
        try? process.run()
    }
}
