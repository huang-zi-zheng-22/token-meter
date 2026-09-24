import Foundation

@main
enum SelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeDirectory = root.appendingPathComponent(".claude/projects/test", isDirectory: true)
        let openClawDirectory = root.appendingPathComponent(".openclaw/agents/main/sessions", isDirectory: true)
        let codexDirectory = root.appendingPathComponent(".codex/sessions/2026/08/26", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openClawDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

        let claudeLine = #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","requestId":"request-1","message":{"id":"message-1","model":"claude-test","usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":50}}}"#
        try (claudeLine + "\n" + claudeLine + "\n").write(
            to: claudeDirectory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let openClawLine = #"{"type":"message","id":"openclaw-1","timestamp":"2026-08-26T11:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-test","usage":{"totalTokens":200}}}"#
        let deepSeekLine = #"{"type":"message","id":"deepseek-1","timestamp":"2026-08-26T11:30:00.000Z","message":{"role":"assistant","provider":"deepseek","model":"deepseek-test","usage":{"totalTokens":300,"cost":{"total":0.2}}}}"#
        try (openClawLine + "\n" + deepSeekLine + "\n").write(
            to: openClawDirectory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let codexLines = [
            #"{"timestamp":"2026-08-26T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"rate_limits":null}}}"#,
            #"{"timestamp":"2026-08-26T12:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":175},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1787770000},"secondary":{"used_percent":60,"window_minutes":10080,"resets_at":1788012567}}}}}"#,
        ]
        try (codexLines.joined(separator: "\n") + "\n").write(
            to: codexDirectory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let now = ISO8601DateFormatter().date(from: "2026-08-26T15:00:00Z")!
        var snapshot = UsageCollector(homeURL: root, calendar: calendar).collect(now: now)
        snapshot.deepSeekBalance = DeepSeekBalance(isAvailable: true, total: 4.8, currency: "USD")

        try expect(snapshot.claudeToday == 400, "Claude deduplication and OpenClaw aggregation")
        try expect(snapshot.claudeMonth == 400, "Claude monthly aggregation")
        try expect(snapshot.claudePercentUsed == nil, "Claude percent absent before plan fetch")
        try expect(snapshot.codexToday == 175, "Codex cumulative delta aggregation")
        try expect(snapshot.codexMonth == 175, "Codex monthly aggregation")
        try expect(snapshot.codexPlan?.session?.usedPercent == 25, "Codex session window percent")
        try expect(snapshot.codexPlan?.session?.windowMinutes == 300, "Codex session window minutes")
        try expect(snapshot.codexPlan?.weekly?.usedPercent == 60, "Codex weekly window percent")
        try expect(snapshot.codexPercentUsed == 60, "Codex headline is the fuller window")
        try expect(snapshot.deepSeekToday == 300, "DeepSeek daily aggregation")
        try expect(snapshot.deepSeekMonth == 300, "DeepSeek monthly aggregation")
        try expect(abs(snapshot.deepSeekMonthCostUSD - 0.2) < 0.000_001, "DeepSeek cost aggregation")
        try expect(abs((snapshot.deepSeekPercentUsed ?? -1) - 4) < 0.000_001, "DeepSeek spent share of pool")

        let claudeUsageJSON = Data(#"""
        {"five_hour":{"utilization":24.0,"resets_at":"2026-08-26T20:10:00.110987+00:00"},"seven_day":{"utilization":5.0,"resets_at":"2026-08-27T11:00:00.111005+00:00"},"extra_usage":{"is_enabled":false}}
        """#.utf8)
        let claudePlan = try ClaudeUsageClient().decodePlan(claudeUsageJSON, now: now)
        try expect(claudePlan.session?.usedPercent == 24, "Claude session utilization decode")
        try expect(claudePlan.weekly?.usedPercent == 5, "Claude weekly utilization decode")
        try expect(claudePlan.session?.resetsAt != nil, "Claude microsecond reset date parse")
        try expect(claudePlan.headline?.usedPercent == 24, "Claude headline is the fuller window")
        snapshot.claudePlan = claudePlan
        try expect(snapshot.claudePercentUsed == 24, "Claude percent used after plan fetch")

        let modelDirectory = root.appendingPathComponent(".openclaw/agents/main/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let modelJSON = #"{"providers":{"deepseek":{"apiKey":"test-key-not-secret"}}}"#
        try modelJSON.write(
            to: modelDirectory.appendingPathComponent("models.json"),
            atomically: true,
            encoding: .utf8
        )
        let balanceClient = DeepSeekBalanceClient(homeURL: root)
        try expect(balanceClient.loadAPIKey() == "test-key-not-secret", "DeepSeek OpenClaw key discovery")

        // Post-27-Aug layout: models.json emptied, key lives in the provider plugin's catalog.json.
        try #"{"providers":{}}"#.write(
            to: modelDirectory.appendingPathComponent("models.json"),
            atomically: true,
            encoding: .utf8
        )
        try expect(balanceClient.loadAPIKey() == nil, "DeepSeek key absent when models.json is emptied")
        let catalogDirectory = modelDirectory.appendingPathComponent("plugins/deepseek", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try #"{"generatedBy":"openclaw-plugin-model-catalog-v1","providers":{"deepseek":{"baseUrl":"https://api.deepseek.com","models":[],"apiKey":"catalog-key-not-secret"}}}"#.write(
            to: catalogDirectory.appendingPathComponent("catalog.json"),
            atomically: true,
            encoding: .utf8
        )
        try expect(balanceClient.loadAPIKey() == "catalog-key-not-secret", "DeepSeek key discovery from plugin catalog.json")
        let balanceData = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"5.80","granted_balance":"0.00","topped_up_balance":"5.80"}]}"#.utf8)
        let decodedBalance = try balanceClient.decodeBalance(balanceData)
        try expect(decodedBalance == DeepSeekBalance(isAvailable: true, total: 5.8, currency: "USD"), "DeepSeek balance decoding")

        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let emptySnapshot = UsageCollector(homeURL: emptyRoot, calendar: calendar).collect(now: now)
        try expect(
            emptySnapshot.warnings.contains("Claude Code usage logs were not found"),
            "missing Claude log warning"
        )
        try expect(
            emptySnapshot.warnings.contains("Codex usage logs were not found"),
            "missing Codex log warning"
        )
        try expect(emptySnapshot.codexPercentUsed == nil, "Codex percent absent without logs")

        print("Self-test passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else {
            throw SelfTestError.failed(label)
        }
    }
}

private enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let label): return "Self-test failed: \(label)"
        }
    }
}
