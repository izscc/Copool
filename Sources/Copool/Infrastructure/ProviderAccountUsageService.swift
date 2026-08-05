import Foundation

/// One normalized quota/balance fact for a provider account.
struct QuotaMetric: Codable, Equatable, Sendable, Identifiable {
    /// "balance" (currency value) or "quota" (percentage window).
    var kind: String
    var label: String
    var value: Double?
    var currency: String?
    var usedPercent: Double?
    var remainingPercent: Double?
    var detail: String?

    var id: String { label }
}

/// Result of querying one provider's account usage.
struct ProviderAccountUsage: Equatable, Sendable {
    /// available / not-configured / local-only
    var status: String
    var source: String
    var metrics: [QuotaMetric]
    var message: String?
}

/// Queries vendor account usage APIs for the providers icopool knows how to
/// ask (codex-router's `provider-account-usage` adapters, ported).
///
/// Each adapter only runs against the vendor's official endpoint; a custom
/// base URL or missing credential resolves to `local-only`/`not-configured`
/// instead of guessing.
struct ProviderAccountUsageService: Sendable {
    var session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(for provider: ProviderConfig) async -> ProviderAccountUsage {
        let name = provider.name.lowercased()
        let baseURL = provider.baseURL.lowercased()

        if name.contains("deepseek") || baseURL.contains("deepseek") {
            return await fetchDeepSeekBalance(provider)
        }
        if name.contains("grok") || baseURL.contains("x.ai") {
            return await fetchGrokBilling(provider)
        }
        return ProviderAccountUsage(
            status: "local-only",
            source: "local-router",
            metrics: [],
            message: "Account usage is unavailable for this provider"
        )
    }

    // MARK: - DeepSeek

    private func fetchDeepSeekBalance(_ provider: ProviderConfig) async -> ProviderAccountUsage {
        let host = URL(string: provider.baseURL)?.host ?? ""
        guard host == "api.deepseek.com" else {
            return localOnly("Account balance is unavailable for a custom DeepSeek endpoint")
        }
        guard !provider.apiKey.isEmpty else {
            return ProviderAccountUsage(status: "not-configured", source: "official-api", metrics: [])
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = object["balance_infos"] as? [[String: Any]] else {
                return ProviderAccountUsage(status: "unavailable", source: "official-api", metrics: [], message: "Balance response was not usable")
            }
            let preferred = infos.first { ($0["currency"] as? String) == "USD" } ?? infos.first
            guard let preferred,
                  let value = numberValue(preferred["total_balance"]),
                  let currency = preferred["currency"] as? String else {
                return ProviderAccountUsage(status: "unavailable", source: "official-api", metrics: [])
            }
            var detailParts: [String] = []
            if let paid = numberValue(preferred["topped_up_balance"]) {
                detailParts.append(String(format: "Paid %.2f", paid))
            }
            if let granted = numberValue(preferred["granted_balance"]) {
                detailParts.append(String(format: "Granted %.2f", granted))
            }
            return ProviderAccountUsage(
                status: "available",
                source: "official-api",
                metrics: [
                    QuotaMetric(
                        kind: "balance",
                        label: "API balance",
                        value: value,
                        currency: currency,
                        detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
                    )
                ]
            )
        } catch {
            return ProviderAccountUsage(status: "unavailable", source: "official-api", metrics: [], message: error.localizedDescription)
        }
    }

    // MARK: - Grok (x.ai billing)

    private func fetchGrokBilling(_ provider: ProviderConfig) async -> ProviderAccountUsage {
        let host = URL(string: provider.baseURL)?.host ?? ""
        guard host == "api.x.ai" || host == "cli-chat-proxy.grok.com" else {
            return localOnly("Account billing is unavailable for a custom Grok proxy endpoint")
        }
        // Reuse the imported OAuth access token; the CLI proxy is the only
        // surface that answers billing for it.
        let token = provider.refreshToken?.isEmpty == false ? provider.refreshToken : provider.apiKey
        guard let token, !token.isEmpty else {
            return ProviderAccountUsage(status: "not-configured", source: "official-cli", metrics: [])
        }

        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("icopool/2.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = object["config"] as? [String: Any] else {
                return ProviderAccountUsage(status: "unavailable", source: "official-cli", metrics: [], message: "Billing response was incomplete")
            }
            var metrics: [QuotaMetric] = []
            if let usagePct = numberValue(config["creditUsagePercent"] ?? config["credit_usage_percent"]) {
                let used = min(100, max(0, usagePct))
                let period = config["currentPeriod"] as? [String: Any] ?? config["current_period"] as? [String: Any]
                let periodType = String(period?["type"] as? String ?? period?["period_type"] as? String ?? "")
                let label = periodType.contains("WEEKLY") ? "Weekly limit" : (periodType.contains("MONTHLY") ? "Monthly limit" : "Usage limit")
                metrics.append(
                    QuotaMetric(
                        kind: "quota",
                        label: label,
                        usedPercent: used,
                        remainingPercent: 100 - used,
                        detail: String(format: "%.0f%% used", used)
                    )
                )
            }
            if let prepaid = numberValue(config["prepaidCredits"] ?? config["prepaid_credits"]) {
                metrics.append(
                    QuotaMetric(
                        kind: "balance",
                        label: "Prepaid credits",
                        value: prepaid,
                        detail: "Purchased credits remaining"
                    )
                )
            }
            guard !metrics.isEmpty else {
                return ProviderAccountUsage(status: "unavailable", source: "official-cli", metrics: [])
            }
            return ProviderAccountUsage(status: "available", source: "official-cli", metrics: metrics)
        } catch {
            return ProviderAccountUsage(status: "unavailable", source: "official-cli", metrics: [], message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func localOnly(_ message: String) -> ProviderAccountUsage {
        ProviderAccountUsage(status: "local-only", source: "local-router", metrics: [], message: message)
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String, let double = Double(string), double.isFinite {
            return double
        }
        return nil
    }
}
