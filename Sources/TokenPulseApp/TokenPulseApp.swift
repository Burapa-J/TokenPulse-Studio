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
    @Published var scannedFileCount: Int = 0

    private let ledger: UsageLedger
    private var fileCursors: [String: FileCursor] = [:]

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
        let watchDirs = LocalLogScanner.defaultWatchDirectories()
        let scanReport = await LocalLogScanner.scanDirectories(watchDirs, into: ledger, cursors: fileCursors)
        self.fileCursors = scanReport.updatedCursors
        self.scannedFileCount = scanReport.scannedFilesCount

        let currentEvents = await ledger.allEventsSorted()
        if currentEvents.isEmpty {
            let nowISO = ISO8601DateFormatter().string(from: Date())
            let demoJSONL = """
            {"id":"init-1","provider":"anthropic","model":"claude-sonnet-4","project":"SaaS-Core","timestamp":"\(nowISO)","usage":{"input_tokens":320000,"output_tokens":64000,"cache_read_input_tokens":150000}}
            {"id":"init-2","provider":"openai","model":"gpt-4.1","project":"Landing-Web","timestamp":"\(nowISO)","usage":{"prompt_tokens":280000,"completion_tokens":45000}}
            {"id":"init-3","provider":"gemini","model":"gemini-3-pro","project":"Data-Pipeline","timestamp":"\(nowISO)","usage":{"input_tokens":410000,"output_tokens":90000}}
            """
            _ = await ledger.ingestJSONL(demoJSONL)
        }
        try? await ledger.saveAtomically()
        await refreshSummary()
    }

    func pollLocalLogsOnce() async {
        let watchDirs = LocalLogScanner.defaultWatchDirectories()
        let scanReport = await LocalLogScanner.scanDirectories(watchDirs, into: ledger, cursors: fileCursors)
        self.fileCursors = scanReport.updatedCursors
        self.scannedFileCount = scanReport.scannedFilesCount
        if scanReport.ingestedEventsCount > 0 {
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
    @State private var selectedTab: Int

    init(viewModel: TokenPulseViewModel, initialTab: Int = 0) {
        self.viewModel = viewModel
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.teal.opacity(0.2))
                        .frame(width: 34, height: 34)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenPulse Studio")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(viewModel.statusBanner)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer()
                Text(viewModel.summary.dailyAlertState.badgeTitle)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor.opacity(0.2))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
            }

            // Custom SwiftUI Pill Tab Switcher
            HStack(spacing: 6) {
                tabPill(title: "AI Spend Radar", index: 0)
                tabPill(title: "Secret Redactor", index: 1)
                tabPill(title: "Pro License", index: 2)
            }
            .padding(4)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if selectedTab == 0 {
                spendRadarSection
            } else if selectedTab == 1 {
                secretRedactorSection
            } else {
                licenseSection
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            HStack {
                Text(licenseStatusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.teal)
                Spacer()
                Text("Quit ⌘Q")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onTapGesture {
                        NSApplication.shared.terminate(nil)
                    }
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(Color(red: 0.08, green: 0.09, blue: 0.13))
    }

    private func tabPill(title: String, index: Int) -> some View {
        let isSelected = (selectedTab == index)
        return Text(title)
            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.teal : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
                selectedTab = index
            }
    }

    private var badgeColor: Color {
        switch viewModel.summary.dailyAlertState {
        case .withinBudget: return Color(red: 0.2, green: 0.9, blue: 0.5)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                metricCard(
                    title: "TODAY SPEND",
                    value: CurrencyFormatter.formatMicroUSD(viewModel.summary.todaySpentMicroUSD),
                    subtitle: "\(viewModel.summary.todayTokens / 1000)k tokens • $10.00 cap"
                )
                metricCard(
                    title: "MONTH SPEND",
                    value: CurrencyFormatter.formatMicroUSD(viewModel.summary.monthSpentMicroUSD),
                    subtitle: "Budget Cap: $150.00"
                )
            }

            Text("REAL-TIME SPEND BY PROVIDER")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))

            VStack(spacing: 8) {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    let micro = viewModel.summary.spendByProvider[provider, default: 0]
                    if micro > 0 {
                        HStack {
                            Circle()
                                .fill(Color.teal)
                                .frame(width: 6, height: 6)
                            Text(provider.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(CurrencyFormatter.formatMicroUSD(micro))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private var secretRedactorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ON-DEVICE API KEY & SECRET GUARD (100% LOCAL)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))

            Text(viewModel.inputPromptText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.65, green: 0.95, blue: 0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.teal.opacity(0.35), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if let res = viewModel.lastRedaction {
                    Text("Shielded \(res.redactedCount) secret(s) • ~\(res.estimatedTokens) tokens")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(res.redactedCount > 0 ? Color.orange : Color.white.opacity(0.6))
                }
                Spacer()
                Text("Scrub & Copy Safe Prompt")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.teal)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        viewModel.runRedactionAndCopy()
                    }
            }
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTIVATE TOKENPULSE STUDIO PRO ($39 LIFETIME)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))
            TextField("Work Email (e.g. you@company.com)", text: $viewModel.licenseEmail)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("License Key (TPPRO-XXXX-XXXX)", text: $viewModel.licenseKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            HStack {
                Text("Activate Pro Key")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.teal)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        viewModel.activateLicense()
                    }
                Spacer()
            }
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@main
struct TokenPulseApp: App {
    @StateObject private var viewModel = TokenPulseViewModel()

    init() {
        let args = CommandLine.arguments
        if let snapIdx = args.firstIndex(of: "--snapshot"), snapIdx + 1 < args.count {
            let outputPath = args[snapIdx + 1]
            let tabIndex = args.contains("--tab1") ? 1 : 0
            Task { @MainActor in
                let vm = TokenPulseViewModel()
                await vm.bootstrapSampleAndLocalLogs()
                if tabIndex == 1 {
                    vm.runRedactionAndCopy()
                }
                let view = TokenPulsePopoverView(viewModel: vm, initialTab: tabIndex)
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
