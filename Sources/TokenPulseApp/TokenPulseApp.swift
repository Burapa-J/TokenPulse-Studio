import SwiftUI
import AppKit
import TokenPulseCore

@MainActor
final class TokenPulseViewModel: ObservableObject {
    @Published var summary: UsageSummary
    @Published var recentEvents: [TokenUsageEvent] = []
    @Published var inputPromptText: String = """
    // Paste code or config before sending to Claude / Cursor / ChatGPT:
    let anthropicKey = "sk-ant-api03-99887766554433221100aabbccddeeff"
    let openAIKey = "sk-proj-11223344556677889900aabbccddeeff"
    """
    @Published var lastRedaction: RedactionResult?
    @Published var licenseEmail: String = ""
    @Published var licenseKeyInput: String = ""
    @Published var licenseState: LicenseState
    @Published var statusBanner: String = "Monitoring local AI logs & clipboard guard"

    private let ledger: UsageLedger

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storageURL = appSupport.appendingPathComponent("TokenPulse/ledger.json")
        let defaultPolicy = BudgetPolicy(
            dailyLimitMicroUSD: 10_000_000,   // $10.00/day
            monthlyLimitMicroUSD: 150_000_000, // $150.00/month
            warningThresholdRatio: 0.80
        )
        self.ledger = UsageLedger(policy: defaultPolicy, storageURL: storageURL)
        self.summary = UsageSummary(
            totalEvents: 0,
            todaySpentMicroUSD: 0,
            monthSpentMicroUSD: 0,
            todayTokens: 0,
            monthTokens: 0,
            spendByProvider: [:],
            spendByProject: [:],
            dailyAlertState: .withinBudget(spentMicroUSD: 0, limitMicroUSD: 10_000_000),
            monthlyAlertState: .withinBudget(spentMicroUSD: 0, limitMicroUSD: 150_000_000)
        )
        self.licenseState = .trial(daysRemaining: 7, expiresAt: Date().addingTimeInterval(7 * 86_400))
        self.lastRedaction = SecretRedactor.sanitize(inputPromptText)

        Task {
            await bootstrapSampleAndLocalLogs()
        }
    }

    func bootstrapSampleAndLocalLogs() async {
        try? await ledger.loadFromDisk()
        let currentEvents = await ledger.allEventsSorted()
        if currentEvents.isEmpty {
            let nowISO = ISO8601DateFormatter().string(from: Date())
            let demoJSONL = """
            {"id":"init-1","provider":"anthropic","model":"claude-sonnet-4","project":"SaaS-Core","timestamp":"\(nowISO)","usage":{"input_tokens":320000,"output_tokens":64000,"cache_read_input_tokens":150000}}
            {"id":"init-2","provider":"openai","model":"gpt-4.1","project":"Landing-Web","timestamp":"\(nowISO)","usage":{"prompt_tokens":280000,"completion_tokens":45000}}
            {"id":"init-3","provider":"gemini","model":"gemini-3-pro","project":"Data-Pipeline","timestamp":"\(nowISO)","usage":{"input_tokens":410000,"output_tokens":90000}}
            """
            _ = await ledger.ingestJSONL(demoJSONL)
            try? await ledger.saveAtomically()
        }
        await refreshSummary()
    }

    func refreshSummary() async {
        let latestSummary = await ledger.summary()
        let events = await ledger.allEventsSorted()
        self.summary = latestSummary
        self.recentEvents = Array(events.prefix(6))
    }

    func runRedactionAndCopy() {
        let result = SecretRedactor.sanitize(inputPromptText)
        self.lastRedaction = result
        self.inputPromptText = result.sanitizedText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.sanitizedText, forType: .string)
        self.statusBanner = "Sanitized \(result.redactedCount) secret(s) & copied to Clipboard!"
    }

    func activateLicense() {
        if LicenseValidator.verifyKey(licenseKeyInput, email: licenseEmail) {
            self.licenseState = .activePro(
                licenseKey: licenseKeyInput.uppercased(),
                email: licenseEmail.lowercased(),
                activatedAt: Date()
            )
            self.statusBanner = "Pro License Activated — Thank you for supporting TokenPulse!"
        } else {
            self.statusBanner = "Invalid License Key for \(licenseEmail)"
        }
    }
}

struct TokenPulsePopoverView: View {
    @ObservedObject var viewModel: TokenPulseViewModel
    @State private var selectedTab: Int = 0

    init(viewModel: TokenPulseViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenPulse Studio")
                        .font(.headline)
                    Text(viewModel.statusBanner)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(viewModel.summary.dailyAlertState.badgeTitle)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor.opacity(0.18))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
            }

            Divider()

            Picker("Mode", selection: $selectedTab) {
                Text("AI Spend Radar").tag(0)
                Text("Secret Redactor").tag(1)
                Text("Pro License").tag(2)
            }
            .pickerStyle(.segmented)

            if selectedTab == 0 {
                spendRadarSection
            } else if selectedTab == 1 {
                secretRedactorSection
            } else {
                licenseSection
            }

            Divider()

            HStack {
                Text(licenseStatusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var badgeColor: Color {
        switch viewModel.summary.dailyAlertState {
        case .withinBudget: return .green
        case .warningApproaching: return .orange
        case .circuitBroken: return .red
        }
    }

    private var licenseStatusLabel: String {
        switch viewModel.licenseState {
        case .trial(let days, _):
            return "Free Trial (\(days)d left) • Upgrade $39 Lifetime"
        case .activePro(_, let email, _):
            return "Pro Licensed: \(email)"
        case .expired:
            return "Trial Expired • Activate Pro ($39)"
        }
    }

    private var spendRadarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                metricCard(
                    title: "TODAY SPEND",
                    value: CurrencyFormatter.formatMicroUSD(viewModel.summary.todaySpentMicroUSD),
                    subtitle: "\(viewModel.summary.todayTokens / 1000)k tokens"
                )
                metricCard(
                    title: "MONTH SPEND",
                    value: CurrencyFormatter.formatMicroUSD(viewModel.summary.monthSpentMicroUSD),
                    subtitle: "Budget: $150.00"
                )
            }

            Text("Spend by Provider")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(ProviderID.allCases, id: \.self) { provider in
                let micro = viewModel.summary.spendByProvider[provider, default: 0]
                if micro > 0 {
                    HStack {
                        Text(provider.displayName)
                            .font(.caption)
                        Spacer()
                        Text(CurrencyFormatter.formatMicroUSD(micro))
                            .font(.caption.monospacedDigit().bold())
                    }
                }
            }
        }
    }

    private var secretRedactorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-Device API Key & Secret Scrubbing (100% Local)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.inputPromptText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

            HStack {
                if let res = viewModel.lastRedaction {
                    Text("Detected: \(res.redactedCount) secret(s) • ~\(res.estimatedTokens) tokens")
                        .font(.caption2)
                        .foregroundStyle(res.redactedCount > 0 ? .orange : .secondary)
                }
                Spacer()
                Button("Scrub & Copy Safe Prompt") {
                    viewModel.runRedactionAndCopy()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activate TokenPulse Studio Pro ($39 One-Time)")
                .font(.caption.bold())
            TextField("Work Email (e.g. you@company.com)", text: $viewModel.licenseEmail)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("License Key (TPPRO-XXXX-XXXX)", text: $viewModel.licenseKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            HStack {
                Button("Activate License") {
                    viewModel.activateLicense()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@main
struct TokenPulseApp: App {
    @StateObject private var viewModel = TokenPulseViewModel()

    init() {
        let args = CommandLine.arguments
        if let snapIdx = args.firstIndex(of: "--snapshot"), snapIdx + 1 < args.count {
            let outputPath = args[snapIdx + 1]
            Task { @MainActor in
                let vm = TokenPulseViewModel()
                await vm.bootstrapSampleAndLocalLogs()
                let view = TokenPulsePopoverView(viewModel: vm)
                    .environment(\.colorScheme, .dark)
                    .background(Color(nsColor: .windowBackgroundColor))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2.0
                if let cgImage = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let pngData = rep.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: URL(fileURLWithPath: outputPath))
                    }
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            TokenPulsePopoverView(viewModel: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text(CurrencyFormatter.formatMicroUSD(viewModel.summary.todaySpentMicroUSD))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
