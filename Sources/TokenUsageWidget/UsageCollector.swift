import Foundation

struct PlanWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
}

struct PlanUsage: Equatable, Sendable {
    let session: PlanWindow?
    let weekly: PlanWindow?
    let observedAt: Date?

    var headline: PlanWindow? {
        switch (session, weekly) {
        case let (session?, weekly?):
            return session.usedPercent >= weekly.usedPercent ? session : weekly
        case let (session?, nil):
            return session
        case let (nil, weekly?):
            return weekly
        default:
            return nil
        }
    }
}

struct DeepSeekBalance: Equatable, Sendable {
    let isAvailable: Bool
    let total: Double
    let currency: String
}

struct UsageSnapshot: Equatable, Sendable {
    let claudeToday: Int64
    let claudeMonth: Int64
    let codexToday: Int64
    let codexMonth: Int64
    let deepSeekToday: Int64
    let deepSeekMonth: Int64
    let deepSeekMonthCostUSD: Double
    let codexPlan: PlanUsage?
    var claudePlan: PlanUsage?
    var claudePlanWarning: String?
    var deepSeekBalance: DeepSeekBalance?
    var deepSeekBalanceWarning: String?
    let refreshedAt: Date
    let warnings: [String]

    var claudePercentUsed: Double? {
        guard let percent = claudePlan?.headline?.usedPercent else { return nil }
        return min(100, max(0, percent))
    }

    var codexPercentUsed: Double? {
        guard let percent = codexPlan?.headline?.usedPercent else { return nil }
        return min(100, max(0, percent))
    }

    // Share of the tracked monthly pool (live balance + month-to-date spend)
    // that has already been spent.
    var deepSeekPercentUsed: Double? {
        guard let balance = deepSeekBalance,
              balance.currency.caseInsensitiveCompare("USD") == .orderedSame
        else { return nil }
        let spent = max(0, deepSeekMonthCostUSD)
        let pool = balance.total + spent
        guard pool > 0 else { return balance.isAvailable ? 0 : 100 }
        return min(100, max(0, spent / pool * 100))
    }
}

private enum UsageSource: Hashable {
    case claudeCode
    case openClaw
    case codex
}

private enum UsageCategory {
    case claude
    case codex
    case deepSeek
}

private struct LocalUsageEvent {
    let category: UsageCategory
    let key: String?
    let timestamp: Date
    let tokens: Int64
    let costUSD: Double
}

private struct UsageFileSignature: Equatable {
    let size: Int
    let modifiedAt: Date
}

private struct CachedUsageFile {
    let signature: UsageFileSignature
    let events: [LocalUsageEvent]
    let plan: (date: Date, plan: PlanUsage)?
}

private struct UsageCacheKey: Hashable {
    let path: String
    let source: UsageSource
}

final class UsageCollector: @unchecked Sendable {
    let homeURL: URL
    let calendar: Calendar
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let standardDateFormatter: ISO8601DateFormatter
    private var fileCache: [UsageCacheKey: CachedUsageFile] = [:]

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser, calendar: Calendar = .current) {
        self.homeURL = homeURL
        self.calendar = calendar

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalDateFormatter = fractional

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        self.standardDateFormatter = standard
    }

    func collect(now: Date = Date()) -> UsageSnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        var warnings: [String] = []
        var seenClaudeMessages = Set<String>()
        var seenDeepSeekMessages = Set<String>()
        var activeCacheKeys = Set<UsageCacheKey>()
        var claudeToday: Int64 = 0
        var claudeMonth: Int64 = 0
        var deepSeekToday: Int64 = 0
        var deepSeekMonth: Int64 = 0
        var deepSeekMonthCostUSD: Double = 0

        let claudeCodeRoot = homeURL.appendingPathComponent(".claude/projects", isDirectory: true)
        let claudeCodeFiles = candidateJSONLFiles(under: claudeCodeRoot, modifiedSince: monthStart)
        if claudeCodeFiles.isEmpty {
            warnings.append("Claude Code usage logs were not found")
        }

        for file in claudeCodeFiles {
            let cacheKey = UsageCacheKey(path: file.path, source: .claudeCode)
            activeCacheKeys.insert(cacheKey)
            guard let cached = cachedUsage(for: file, key: cacheKey) else { continue }
            for event in cached.events where event.timestamp >= monthStart {
                guard seenClaudeMessages.insert("claude-code:\(event.key ?? cacheKey.path)").inserted else { continue }
                claudeMonth += event.tokens
                if event.timestamp >= dayStart { claudeToday += event.tokens }
            }
        }

        let openClawAgentsRoot = homeURL.appendingPathComponent(".openclaw/agents", isDirectory: true)
        let openClawFiles = candidateJSONLFiles(under: openClawAgentsRoot, modifiedSince: monthStart)
            .filter { !$0.lastPathComponent.contains(".trajectory.") }

        for file in openClawFiles {
            let cacheKey = UsageCacheKey(path: file.path, source: .openClaw)
            activeCacheKeys.insert(cacheKey)
            guard let cached = cachedUsage(for: file, key: cacheKey) else { continue }
            for event in cached.events where event.timestamp >= monthStart {
                let key = "openclaw:\(event.key ?? cacheKey.path)"
                switch event.category {
                case .claude:
                    guard seenClaudeMessages.insert(key).inserted else { continue }
                    claudeMonth += event.tokens
                    if event.timestamp >= dayStart { claudeToday += event.tokens }
                case .deepSeek:
                    guard seenDeepSeekMessages.insert(key).inserted else { continue }
                    deepSeekMonth += event.tokens
                    deepSeekMonthCostUSD += event.costUSD
                    if event.timestamp >= dayStart { deepSeekToday += event.tokens }
                case .codex:
                    continue
                }
            }
        }

        let codexRoot = homeURL.appendingPathComponent(".codex/sessions", isDirectory: true)
        let codexFiles = candidateJSONLFiles(under: codexRoot, modifiedSince: monthStart)
        if codexFiles.isEmpty {
            warnings.append("Codex usage logs were not found")
        }

        var codexToday: Int64 = 0
        var codexMonth: Int64 = 0
        var latestPlan: (date: Date, plan: PlanUsage)?

        for file in codexFiles {
            let cacheKey = UsageCacheKey(path: file.path, source: .codex)
            activeCacheKeys.insert(cacheKey)
            guard let cached = cachedUsage(for: file, key: cacheKey) else { continue }
            for event in cached.events where event.timestamp >= monthStart {
                codexMonth += event.tokens
                if event.timestamp >= dayStart { codexToday += event.tokens }
            }
            if let candidate = cached.plan,
               latestPlan == nil || candidate.date > latestPlan!.date {
                latestPlan = candidate
            }
        }

        fileCache = fileCache.filter { activeCacheKeys.contains($0.key) }

        return UsageSnapshot(
            claudeToday: claudeToday,
            claudeMonth: claudeMonth,
            codexToday: codexToday,
            codexMonth: codexMonth,
            deepSeekToday: deepSeekToday,
            deepSeekMonth: deepSeekMonth,
            deepSeekMonthCostUSD: deepSeekMonthCostUSD,
            codexPlan: latestPlan?.plan,
            claudePlan: nil,
            claudePlanWarning: nil,
            deepSeekBalance: nil,
            deepSeekBalanceWarning: nil,
            refreshedAt: now,
            warnings: warnings
        )
    }

    // MARK: - File parsing

    private func cachedUsage(for url: URL, key: UsageCacheKey) -> CachedUsageFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate
        else { return nil }

        let signature = UsageFileSignature(size: size, modifiedAt: modifiedAt)
        if let cached = fileCache[key], cached.signature == signature {
            return cached
        }

        let parsed: CachedUsageFile
        switch key.source {
        case .claudeCode:
            parsed = CachedUsageFile(signature: signature, events: parseClaudeCode(url), plan: nil)
        case .openClaw:
            parsed = CachedUsageFile(signature: signature, events: parseOpenClaw(url), plan: nil)
        case .codex:
            let (events, plan) = parseCodex(url)
            parsed = CachedUsageFile(signature: signature, events: events, plan: plan)
        }
        fileCache[key] = parsed
        return parsed
    }

    private func parseClaudeCode(_ url: URL) -> [LocalUsageEvent] {
        var events: [LocalUsageEvent] = []
        scanJSONLines(in: url) { object in
            guard string(object["type"]) == "assistant",
                  let message = dictionary(object["message"]),
                  let usage = dictionary(message["usage"]),
                  let timestamp = parseDate(string(object["timestamp"]))
            else { return }
            let tokens = tokenTotalForClaudeCode(usage)
            guard tokens > 0 else { return }
            let key = string(object["requestId"]) ?? string(message["id"]) ?? string(object["uuid"])
            events.append(LocalUsageEvent(
                category: .claude,
                key: key,
                timestamp: timestamp,
                tokens: tokens,
                costUSD: 0
            ))
        }
        return events
    }

    private func parseOpenClaw(_ url: URL) -> [LocalUsageEvent] {
        var events: [LocalUsageEvent] = []
        scanJSONLines(in: url) { object in
            guard string(object["type"]) == "message",
                  let message = dictionary(object["message"]),
                  string(message["role"]) == "assistant",
                  let usage = dictionary(message["usage"])
            else { return }
            let timestamp = parseDate(string(object["timestamp"]))
                ?? epochDate(message["timestamp"])
            guard let timestamp else { return }
            let tokens = tokenTotalForOpenClaw(usage)
            guard tokens > 0 else { return }
            let provider = string(message["provider"])?.lowercased() ?? ""
            let category: UsageCategory = provider.contains("deepseek") ? .deepSeek : .claude
            events.append(LocalUsageEvent(
                category: category,
                key: string(object["id"]),
                timestamp: timestamp,
                tokens: tokens,
                costUSD: category == .deepSeek ? openClawCost(usage) : 0
            ))
        }
        return events
    }

    private func parseCodex(_ url: URL) -> ([LocalUsageEvent], (date: Date, plan: PlanUsage)?) {
        var events: [LocalUsageEvent] = []
        var plan: (date: Date, plan: PlanUsage)?
        var previousCumulative: Int64 = 0

        scanJSONLines(in: url) { object in
            guard string(object["type"]) == "event_msg",
                  let payload = dictionary(object["payload"]),
                  string(payload["type"]) == "token_count",
                  let timestamp = parseDate(string(object["timestamp"]))
            else { return }

            if let info = dictionary(payload["info"]),
               let total = dictionary(info["total_token_usage"]),
               let cumulative = integer(total["total_tokens"]) {
                // Cumulative session counter; a drop means the counter restarted.
                let delta = cumulative >= previousCumulative
                    ? cumulative - previousCumulative
                    : cumulative
                previousCumulative = cumulative
                if delta > 0 {
                    events.append(LocalUsageEvent(
                        category: .codex,
                        key: nil,
                        timestamp: timestamp,
                        tokens: delta,
                        costUSD: 0
                    ))
                }
            }

            let rateLimits = dictionary(payload["rate_limits"])
                ?? dictionary(payload["info"]).flatMap { dictionary($0["rate_limits"]) }
            if let rateLimits {
                let session = planWindow(dictionary(rateLimits["primary"]))
                let weekly = planWindow(dictionary(rateLimits["secondary"]))
                if session != nil || weekly != nil {
                    if plan == nil || timestamp > plan!.date {
                        plan = (timestamp, PlanUsage(session: session, weekly: weekly, observedAt: timestamp))
                    }
                }
            }
        }
        return (events, plan)
    }

    private func planWindow(_ object: [String: Any]?) -> PlanWindow? {
        guard let object, let usedPercent = number(object["used_percent"]) else { return nil }
        return PlanWindow(
            usedPercent: usedPercent,
            windowMinutes: integer(object["window_minutes"]).map(Int.init),
            resetsAt: epochDate(object["resets_at"])
        )
    }

    private func candidateJSONLFiles(under root: URL, modifiedSince: Date) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= modifiedSince
            else { continue }
            files.append(url)
        }
        return files
    }

    private func scanJSONLines(in url: URL, body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return }
        data.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dictionary = object as? [String: Any]
            else { return }
            body(dictionary)
        }
    }

    private func tokenTotalForClaudeCode(_ usage: [String: Any]) -> Int64 {
        (integer(usage["input_tokens"]) ?? 0)
            + (integer(usage["cache_creation_input_tokens"]) ?? 0)
            + (integer(usage["cache_read_input_tokens"]) ?? 0)
            + (integer(usage["output_tokens"]) ?? 0)
    }

    private func tokenTotalForOpenClaw(_ usage: [String: Any]) -> Int64 {
        if let total = integer(usage["totalTokens"]) ?? integer(usage["total_tokens"]) {
            return total
        }
        return (integer(usage["input"]) ?? integer(usage["input_tokens"]) ?? 0)
            + (integer(usage["output"]) ?? integer(usage["output_tokens"]) ?? 0)
            + (integer(usage["cacheRead"]) ?? integer(usage["cache_read_input_tokens"]) ?? 0)
            + (integer(usage["cacheWrite"]) ?? integer(usage["cache_creation_input_tokens"]) ?? 0)
    }

    private func openClawCost(_ usage: [String: Any]) -> Double {
        guard let cost = dictionary(usage["cost"]) else { return 0 }
        return number(cost["total"]) ?? 0
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
    }

    private func epochDate(_ value: Any?) -> Date? {
        guard let epoch = number(value) else { return nil }
        return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1_000 : epoch)
    }

    private func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func integer(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        let magnitude = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000_000 {
            return sign + trimmed(magnitude / 1_000_000_000) + "B"
        }
        if magnitude >= 1_000_000 {
            return sign + trimmed(magnitude / 1_000_000) + "M"
        }
        if magnitude >= 1_000 {
            return sign + trimmed(magnitude / 1_000) + "K"
        }
        return "\(value)"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0, value < 1 { return String(format: "%.1f%%", value) }
        if value > 99, value < 100 { return String(format: "%.1f%%", value) }
        return "\(Int(value.rounded()))%"
    }

    static func currency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(code) \(String(format: "%.2f", value))"
    }

    private static func trimmed(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "") }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}
