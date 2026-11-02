import Foundation
import CryptoKit

public enum ProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openAI
    case gemini
    case cursor
    case localOllama

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI (GPT / Codex)"
        case .gemini: return "Google Gemini"
        case .cursor: return "Cursor IDE"
        case .localOllama: return "Ollama (Local)"
        }
    }
}

public struct ModelPricingRate: Sendable, Equatable {
    public let inputMicroUSDPerMillion: Int64
    public let outputMicroUSDPerMillion: Int64
    public let cachedInputMicroUSDPerMillion: Int64

    public init(
        inputMicroUSDPerMillion: Int64,
        outputMicroUSDPerMillion: Int64,
        cachedInputMicroUSDPerMillion: Int64
    ) {
        self.inputMicroUSDPerMillion = inputMicroUSDPerMillion
        self.outputMicroUSDPerMillion = outputMicroUSDPerMillion
        self.cachedInputMicroUSDPerMillion = cachedInputMicroUSDPerMillion
    }

    public func calculateCostMicroUSD(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int
    ) -> Int64 {
        let clampedInput = Int64(max(0, inputTokens))
        let clampedOutput = Int64(max(0, outputTokens))
        let clampedCached = Int64(max(0, cachedInputTokens))

        let inputCost = (clampedInput * inputMicroUSDPerMillion) / 1_000_000
        let outputCost = (clampedOutput * outputMicroUSDPerMillion) / 1_000_000
        let cachedCost = (clampedCached * cachedInputMicroUSDPerMillion) / 1_000_000
        return inputCost + outputCost + cachedCost
    }
}

public enum ModelPricingCatalog {
    // 1 USD = 1_000_000 microUSD. Example: $3.00 / 1M tokens = 3_000_000 microUSD per 1M tokens.
    public static func rate(for model: String, provider: ProviderID) -> ModelPricingRate {
        let lower = model.lowercased()
        if provider == .localOllama || lower.contains("llama") || lower.contains("qwen") {
            return ModelPricingRate(
                inputMicroUSDPerMillion: 0,
                outputMicroUSDPerMillion: 0,
                cachedInputMicroUSDPerMillion: 0
            )
        }
        if lower.contains("opus") {
            return ModelPricingRate(
                inputMicroUSDPerMillion: 15_000_000,
                outputMicroUSDPerMillion: 75_000_000,
                cachedInputMicroUSDPerMillion: 1_500_000
            )
        }
        if lower.contains("sonnet") || lower.contains("claude") {
            return ModelPricingRate(
                inputMicroUSDPerMillion: 3_000_000,
                outputMicroUSDPerMillion: 15_000_000,
                cachedInputMicroUSDPerMillion: 300_000
            )
        }
        if lower.contains("haiku") || lower.contains("flash") || lower.contains("-mini") {
            return ModelPricingRate(
                inputMicroUSDPerMillion: 800_000,
                outputMicroUSDPerMillion: 4_000_000,
                cachedInputMicroUSDPerMillion: 80_000
            )
        }
        if lower.contains("gpt-4") || lower.contains("o3") || lower.contains("gemini") {
            return ModelPricingRate(
                inputMicroUSDPerMillion: 2_500_000,
                outputMicroUSDPerMillion: 10_000_000,
                cachedInputMicroUSDPerMillion: 250_000
            )
        }
        return ModelPricingRate(
            inputMicroUSDPerMillion: 3_000_000,
            outputMicroUSDPerMillion: 12_000_000,
            cachedInputMicroUSDPerMillion: 300_000
        )
    }
}

public struct TokenUsageEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: ProviderID
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let costMicroUSD: Int64
    public let timestamp: Date
    public let projectName: String

    public init(
        id: String,
        provider: ProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        costMicroUSD: Int64? = nil,
        timestamp: Date,
        projectName: String
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        if let explicitCost = costMicroUSD {
            self.costMicroUSD = max(0, explicitCost)
        } else {
            let rate = ModelPricingCatalog.rate(for: model, provider: provider)
            self.costMicroUSD = rate.calculateCostMicroUSD(
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cachedInputTokens: self.cachedInputTokens
            )
        }
        self.timestamp = timestamp
        self.projectName = projectName.isEmpty ? "Default Workspace" : projectName
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cachedInputTokens
    }

    public var formattedUSD: String {
        CurrencyFormatter.formatMicroUSD(costMicroUSD)
    }
}

public enum CurrencyFormatter {
    public static func formatMicroUSD(_ microUSD: Int64) -> String {
        let dollars = Double(microUSD) / 1_000_000.0
        return String(format: "$%.2f", dollars)
    }
}

public struct BudgetPolicy: Codable, Equatable, Sendable {
    public var dailyLimitMicroUSD: Int64
    public var monthlyLimitMicroUSD: Int64
    public var warningThresholdRatio: Double

    public init(
        dailyLimitMicroUSD: Int64 = 10_000_000,   // $10.00/day default
        monthlyLimitMicroUSD: Int64 = 150_000_000, // $150.00/month default
        warningThresholdRatio: Double = 0.80
    ) {
        self.dailyLimitMicroUSD = max(100_000, dailyLimitMicroUSD)
        self.monthlyLimitMicroUSD = max(1_000_000, monthlyLimitMicroUSD)
        self.warningThresholdRatio = min(max(warningThresholdRatio, 0.10), 0.99)
    }

    public func evaluate(spentMicroUSD: Int64, isDaily: Bool = true) -> BudgetAlertState {
        let limit = isDaily ? dailyLimitMicroUSD : monthlyLimitMicroUSD
        if spentMicroUSD >= limit {
            return .circuitBroken(
                spentMicroUSD: spentMicroUSD,
                limitMicroUSD: limit,
                overageMicroUSD: spentMicroUSD - limit
            )
        }
        let ratio = Double(spentMicroUSD) / Double(limit)
        if ratio >= warningThresholdRatio {
            return .warningApproaching(
                spentMicroUSD: spentMicroUSD,
                limitMicroUSD: limit,
                ratio: ratio
            )
        }
        return .withinBudget(spentMicroUSD: spentMicroUSD, limitMicroUSD: limit)
    }
}

public enum BudgetAlertState: Equatable, Sendable {
    case withinBudget(spentMicroUSD: Int64, limitMicroUSD: Int64)
    case warningApproaching(spentMicroUSD: Int64, limitMicroUSD: Int64, ratio: Double)
    case circuitBroken(spentMicroUSD: Int64, limitMicroUSD: Int64, overageMicroUSD: Int64)

    public var badgeTitle: String {
        switch self {
        case .withinBudget:
            return "HEALTHY"
        case .warningApproaching:
            return "BUDGET WARNING"
        case .circuitBroken:
            return "CIRCUIT BROKEN"
        }
    }
}

public struct LedgerSnapshotV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let savedAt: Date
    public let policy: BudgetPolicy
    public let events: [TokenUsageEvent]

    public init(
        schemaVersion: Int = LedgerSnapshotV1.currentSchemaVersion,
        savedAt: Date = Date(),
        policy: BudgetPolicy,
        events: [TokenUsageEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.policy = policy
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case savedAt
        case policy
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        self.policy = try container.decodeIfPresent(BudgetPolicy.self, forKey: .policy) ?? BudgetPolicy()
        self.events = try container.decodeIfPresent([TokenUsageEvent].self, forKey: .events) ?? []
    }
}

public enum LicenseState: Codable, Equatable, Sendable {
    case trial(daysRemaining: Int, expiresAt: Date)
    case activePro(licenseKey: String, email: String, activatedAt: Date)
    case expired(expiredAt: Date)

    public var isEntitledToProFeatures: Bool {
        switch self {
        case .trial(let days, _): return days > 0
        case .activePro: return true
        case .expired: return false
        }
    }
}

public enum LicenseValidator {
    private static let signingSalt = "TokenPulse-PolarMoR-2026-v1"

    /// Generates a deterministic offline-verifiable Pro license key for Polar.sh / Lemon Squeezy webhook fulfillment.
    /// Format: `TPPRO-<8-HEX-PAYLOAD>-<8-HEX-HMAC>`
    public static func generateKey(forEmail email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let emailDigest = SHA256.hash(data: Data(normalized.utf8))
        let payloadHex = emailDigest.prefix(4).map { String(format: "%02X", $0) }.joined()
        let sigHex = computeSignaturePrefix(payloadHex: payloadHex, email: normalized)
        return "TPPRO-\(payloadHex)-\(sigHex)"
    }

    public static func verifyKey(_ key: String, email: String) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, normalizedEmail.contains("@") else { return false }

        let parts = trimmedKey.split(separator: "-")
        guard parts.count == 3, parts[0] == "TPPRO" else { return false }
        let payloadHex = String(parts[1])
        let providedSig = String(parts[2])
        guard payloadHex.count == 8, providedSig.count == 8 else { return false }

        let expectedKey = generateKey(forEmail: normalizedEmail)
        return trimmedKey == expectedKey
    }

    private static func computeSignaturePrefix(payloadHex: String, email: String) -> String {
        let keyData = Data(signingSalt.utf8)
        let symmetricKey = SymmetricKey(data: keyData)
        let message = Data("\(payloadHex):\(email)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
        return mac.prefix(4).map { String(format: "%02X", $0) }.joined()
    }
}
