import Foundation
import TokenPulseCore

@main
struct TokenPulseCLI {
    static func main() async throws {
        let args = CommandLine.arguments
        let sampleJSONL = """
        {"id":"req-101","provider":"anthropic","model":"claude-sonnet-4","project":"SaaS-Backend","timestamp":"2026-11-02T08:15:00Z","usage":{"input_tokens":200000,"output_tokens":50000,"cache_read_input_tokens":100000}}
        {"id":"req-102","provider":"openai","model":"gpt-4.1","project":"iOS-Client","timestamp":"2026-11-02T09:30:00Z","usage":{"prompt_tokens":400000,"completion_tokens":100000}}
        {"id":"req-103","provider":"gemini","model":"gemini-3-pro","project":"Analytics-Worker","timestamp":"2026-11-02T10:45:00Z","usage":{"input_tokens":500000,"output_tokens":200000}}
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenpulse-cli-ledger.json")
        let policy = BudgetPolicy(dailyLimitMicroUSD: 5_000_000, monthlyLimitMicroUSD: 100_000_000, warningThresholdRatio: 0.80)
        let ledger = UsageLedger(policy: policy, storageURL: tempURL)

        let report = await ledger.ingestJSONL(sampleJSONL)
        let refDate = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z") ?? Date()
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let summary = await ledger.summary(referenceDate: refDate, calendar: utcCalendar)

        let rawSnippet = """
        export ANTHROPIC_API_KEY="sk-ant-api03-abcdef1234567890abcdef123456"
        export OPENAI_API_KEY="sk-proj-9876543210fedcba9876543210fedcba"
        """
        let redacted = SecretRedactor.sanitize(rawSnippet)
        let sampleLicense = LicenseValidator.generateKey(forEmail: "founder@tokenpulse.app")
        let licenseValid = LicenseValidator.verifyKey(sampleLicense, email: "founder@tokenpulse.app")

        if args.contains("--json") {
            print("""
            {"ingested":\(report.ingestedEventCount),"todayUSD":"\(CurrencyFormatter.formatMicroUSD(summary.todaySpentMicroUSD))","alert":"\(summary.dailyAlertState.badgeTitle)","redactedSecrets":\(redacted.redactedCount),"licenseVerified":\(licenseValid)}
            """)
        } else {
            print("=== TokenPulse CLI Verification Probe ===")
            print("Ingested Events: \(report.ingestedEventCount) (Duplicates ignored: \(report.duplicateIgnoredCount), Malformed skipped: \(report.skippedMalformedLineCount))")
            print("Today Spend: \(CurrencyFormatter.formatMicroUSD(summary.todaySpentMicroUSD)) (\(summary.todayTokens) tokens)")
            print("Daily Budget Status: \(summary.dailyAlertState.badgeTitle)")
            print("Redacted Secrets: \(redacted.redactedCount) -> \(redacted.detectedKinds.map(\.rawValue).joined(separator: ", "))")
            print("Sanitized Output:\n\(redacted.sanitizedText)")
            print("Sample Pro License Key: \(sampleLicense) (Verified: \(licenseValid))")
        }
    }
}
