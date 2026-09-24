import Foundation

struct DeepSeekBalanceResult: Sendable {
    let balance: DeepSeekBalance?
    let warning: String?
}

struct DeepSeekBalanceClient: @unchecked Sendable {
    let homeURL: URL
    let session: URLSession

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        session: URLSession = .shared
    ) {
        self.homeURL = homeURL
        self.session = session
    }

    func fetch() async -> DeepSeekBalanceResult {
        guard let apiKey = loadAPIKey() else {
            return DeepSeekBalanceResult(balance: nil, warning: "DeepSeek key not found in OpenClaw")
        }

        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return DeepSeekBalanceResult(balance: nil, warning: "DeepSeek balance endpoint is invalid")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return DeepSeekBalanceResult(balance: nil, warning: "DeepSeek balance response was invalid")
            }
            guard http.statusCode == 200 else {
                let warning = http.statusCode == 401
                    ? "DeepSeek balance authentication failed"
                    : "DeepSeek balance returned HTTP \(http.statusCode)"
                return DeepSeekBalanceResult(balance: nil, warning: warning)
            }
            return DeepSeekBalanceResult(balance: try decodeBalance(data), warning: nil)
        } catch {
            return DeepSeekBalanceResult(balance: nil, warning: "DeepSeek balance is temporarily unavailable")
        }
    }

    /// OpenClaw has kept the DeepSeek key in two places over time:
    /// `agents/<id>/agent/models.json` (`providers.deepseek.apiKey`) until 27 Aug 2026,
    /// then — after it emptied that file to `{"providers": {}}` — the provider plugin's own
    /// `agents/<id>/agent/plugins/deepseek/catalog.json`, same `providers.deepseek.apiKey` shape.
    /// Both are scanned, `main` first, so either layout works.
    static let keyFileNames: Set<String> = ["models.json", "catalog.json"]

    func loadAPIKey() -> String? {
        let agentsRoot = homeURL.appendingPathComponent(".openclaw/agents", isDirectory: true)
        let mainAgent = agentsRoot.appendingPathComponent("main/agent", isDirectory: true)
        var candidates = [
            mainAgent.appendingPathComponent("models.json"),
            mainAgent.appendingPathComponent("plugins/deepseek/catalog.json"),
        ]

        if let enumerator = FileManager.default.enumerator(
            at: agentsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator
            where Self.keyFileNames.contains(url.lastPathComponent)
                && !candidates.contains(url)
                && !url.path.contains("/sessions/") {
                candidates.append(url)
            }
        }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providers = object["providers"] as? [String: Any],
                  let deepSeek = providers["deepseek"] as? [String: Any],
                  let key = deepSeek["apiKey"] as? String,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return key
        }
        return nil
    }

    func decodeBalance(_ data: Data) throws -> DeepSeekBalance {
        let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
        guard let info = response.balanceInfos.first(where: { $0.currency == "USD" })
                ?? response.balanceInfos.first,
              let total = Double(info.totalBalance)
        else { throw BalanceError.missingBalance }

        return DeepSeekBalance(
            isAvailable: response.isAvailable,
            total: max(0, total),
            currency: info.currency
        )
    }
}

private struct BalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct BalanceInfo: Decodable {
    let currency: String
    let totalBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
    }
}

private enum BalanceError: Error {
    case missingBalance
}
