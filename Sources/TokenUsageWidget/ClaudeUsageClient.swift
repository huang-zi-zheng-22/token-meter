import Foundation
import Security

struct ClaudePlanResult: Sendable {
    let plan: PlanUsage?
    let warning: String?
}

/// Fetches the live subscription utilization Claude Code's own /usage panel
/// shows, using the OAuth credential Claude Code keeps in the login Keychain.
/// The token is read into memory and sent only to Anthropic's official usage
/// endpoint; it is never logged or stored by this app.
struct ClaudeUsageClient: @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async -> ClaudePlanResult {
        guard let token = loadAccessToken() else {
            return ClaudePlanResult(plan: nil, warning: "Claude sign-in not readable from Keychain")
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return ClaudePlanResult(plan: nil, warning: "Claude usage endpoint is invalid")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ClaudePlanResult(plan: nil, warning: "Claude usage response was invalid")
            }
            guard http.statusCode == 200 else {
                let warning = http.statusCode == 401
                    ? "Claude sign-in expired — open Claude Code once to refresh it"
                    : "Claude usage returned HTTP \(http.statusCode)"
                return ClaudePlanResult(plan: nil, warning: warning)
            }
            return ClaudePlanResult(plan: try decodePlan(data, now: Date()), warning: nil)
        } catch {
            return ClaudePlanResult(plan: nil, warning: "Claude usage is temporarily unavailable")
        }
    }

    func loadAccessToken() -> String? {
        guard let data = credentialData(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Reads the raw credential JSON. Prefers Apple's `security` tool: the
    /// keychain permission then belongs to the stable, Apple-signed tool
    /// rather than this app's ad-hoc signature, so it survives rebuilds of
    /// the widget and Claude Code recreating the item — no password prompt.
    /// Falls back to the direct Keychain read (the pre-existing path, which
    /// may show the one-time "Always Allow" dialog).
    private func credentialData() -> Data? {
        if !UserDefaults.standard.bool(forKey: Self.securityToolDisabledKey),
           let data = readViaSecurityTool() {
            return data
        }
        return readViaSecItem()
    }

    private static let securityToolDisabledKey = "claudeCredentialSecurityToolDisabled"

    private func readViaSecurityTool() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Claude Code-credentials"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // If this read were ever not permitted, `security` would raise a
        // blocking password dialog. Kill it after a grace period (which also
        // dismisses the dialog) and never try this path again on this
        // install, so the widget can never nag on every 3-minute refresh.
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            UserDefaults.standard.set(true, forKey: Self.securityToolDisabledKey)
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return Data(text.utf8)
    }

    private func readViaSecItem() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }

    func decodePlan(_ data: Data, now: Date) throws -> PlanUsage {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let session = window(response.fiveHour, minutes: 300)
        let weekly = window(response.sevenDay, minutes: 10_080)
        guard session != nil || weekly != nil else { throw ClaudeUsageError.missingWindows }
        return PlanUsage(session: session, weekly: weekly, observedAt: now)
    }

    private func window(_ raw: UsageResponse.Window?, minutes: Int) -> PlanWindow? {
        guard let raw, let utilization = raw.utilization else { return nil }
        return PlanWindow(
            usedPercent: utilization,
            windowMinutes: minutes,
            resetsAt: raw.resetsAt.flatMap(Self.parseResetDate)
        )
    }

    // resets_at arrives as ISO8601 with microsecond precision, e.g.
    // "2026-08-26T20:10:00.110987+00:00", which ISO8601DateFormatter's
    // fractional mode does not always accept.
    static func parseResetDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        return formatter.date(from: value)
    }
}

private struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private enum ClaudeUsageError: Error {
    case missingWindows
}
