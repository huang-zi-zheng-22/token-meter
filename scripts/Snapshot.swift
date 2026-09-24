import Foundation

@main
enum Snapshot {
    static func main() throws {
        let startedAt = Date()
        let snapshot = UsageCollector().collect()
        var output: [String: Any] = [
            "claudeToday": snapshot.claudeToday,
            "claudeMonth": snapshot.claudeMonth,
            "codexToday": snapshot.codexToday,
            "codexMonth": snapshot.codexMonth,
            "deepSeekToday": snapshot.deepSeekToday,
            "deepSeekMonth": snapshot.deepSeekMonth,
            "deepSeekMonthCostUSD": snapshot.deepSeekMonthCostUSD,
            "codexPlanAvailable": snapshot.codexPlan != nil,
            "elapsedSeconds": Date().timeIntervalSince(startedAt),
            "warnings": snapshot.warnings,
        ]
        if let plan = snapshot.codexPlan {
            output["codexSessionUsedPercent"] = plan.session?.usedPercent
            output["codexWeeklyUsedPercent"] = plan.weekly?.usedPercent
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
