import XCTest
@testable import TokenPulseCore

final class TokenPulseCoreTests: XCTestCase {

    // MARK: - Pre-Mortem #1: Concurrent Ingestion Idempotency & Deduplication
    func testConcurrentIngestionDeduplicatesIdempotently() async {
        let ledger = UsageLedger()
        let jsonlBatch = """
        {"id":"sess-01","provider":"anthropic","model":"claude-sonnet-4","project":"Alpha","timestamp":"2026-11-02T10:00:00Z","usage":{"input_tokens":100000,"output_tokens":20000}}
        {"id":"sess-02","provider":"openai","model":"gpt-4.1","project":"Beta","timestamp":"2026-11-02T10:05:00Z","usage":{"prompt_tokens":200000,"completion_tokens":50000}}
        """

        await withTaskGroup(of: IngestionReport.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await ledger.ingestJSONL(jsonlBatch)
                }
            }
        }

        let refDate = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        let summary = await ledger.summary(referenceDate: refDate, calendar: utcCal)

        XCTAssertEqual(summary.totalEvents, 2, "Concurrent ingestion of identical JSONL batches must deduplicate to exactly 2 events")
        // sess-01 cost: 100k * $3/1M ($0.30 = 300,000) + 20k * $15/1M ($0.30 = 300,000) = 600,000 microUSD
        // sess-02 cost: 200k * $2.50/1M ($0.50 = 500,000) + 50k * $10/1M ($0.50 = 500,000) = 1,000,000 microUSD
        XCTAssertEqual(summary.todaySpentMicroUSD, 1_600_000)
    }

    // MARK: - Pre-Mortem #2: Partial Failure & Truncated/Corrupt JSONL Lines
    func testPartialOrCorruptJSONLLinesDoNotLoseValidEvents() async {
        let ledger = UsageLedger()
        let mixedJSONL = """
        {"id":"valid-1","provider":"anthropic","model":"claude-sonnet-4","timestamp":"2026-11-02T10:00:00Z","usage":{"input_tokens":1000000,"output_tokens":0}}
        {"id":"corrupt-half-written-line","provider":"anthropic","usage":{"input_tokens":
        NOT_EVEN_JSON_LINE
        {"id":"invalid-negative","provider":"anthropic","timestamp":"2026-11-02T10:01:00Z","usage":{"input_tokens":-500,"output_tokens":100}}
        {"id":"valid-2","provider":"anthropic","model":"claude-opus-4","timestamp":"2026-11-02T10:02:00Z","usage":{"input_tokens":100000,"output_tokens":10000}}
        """

        let report = await ledger.ingestJSONL(mixedJSONL)
        XCTAssertEqual(report.ingestedEventCount, 2)
        XCTAssertEqual(report.skippedMalformedLineCount, 3)

        let events = await ledger.allEventsSorted()
        XCTAssertEqual(events.count, 2)
    }

    // MARK: - Pre-Mortem #3: Schema Upgrade / Rollback & Budget Circuit Breaker
    func testSnapshotRoundTripAndBackwardCompatibleDecode() throws {
        // Legacy JSON missing `schemaVersion` and `policy` fields
        let legacyJSON = """
        {
          "events": [
            {
              "id": "legacy-1",
              "provider": "anthropic",
              "model": "claude-sonnet-4",
              "inputTokens": 500000,
              "outputTokens": 100000,
              "cachedInputTokens": 0,
              "costMicroUSD": 3000000,
              "timestamp": "2026-11-02T08:00:00Z",
              "projectName": "LegacyProj"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LedgerSnapshotV1.self, from: legacyJSON)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events.first?.costMicroUSD, 3_000_000)

        let strictPolicy = BudgetPolicy(dailyLimitMicroUSD: 2_500_000, monthlyLimitMicroUSD: 50_000_000, warningThresholdRatio: 0.80)
        let alert = strictPolicy.evaluate(spentMicroUSD: 3_000_000, isDaily: true)
        XCTAssertEqual(alert, .circuitBroken(spentMicroUSD: 3_000_000, limitMicroUSD: 2_500_000, overageMicroUSD: 500_000))
    }

    // MARK: - Pre-Mortem #4: Atomic Persistence & Multi-Secret Same-Line Redaction
    func testAtomicPersistenceRoundTripAndSecretRedactorMultipleSecretsSameLine() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let policy = BudgetPolicy(dailyLimitMicroUSD: 8_000_000, monthlyLimitMicroUSD: 120_000_000, warningThresholdRatio: 0.75)
        let writerLedger = UsageLedger(policy: policy, storageURL: ledgerURL)
        _ = await writerLedger.ingestJSONL("""
        {"id":"persist-1","provider":"gemini","model":"gemini-3-pro","timestamp":"2026-11-02T11:00:00Z","usage":{"input_tokens":400000,"output_tokens":100000}}
        """)
        try await writerLedger.saveAtomically()

        let readerLedger = UsageLedger(storageURL: ledgerURL)
        try await readerLedger.loadFromDisk()
        let loadedEvents = await readerLedger.allEventsSorted()
        let loadedPolicy = await readerLedger.currentPolicy()
        XCTAssertEqual(loadedEvents.count, 1)
        XCTAssertEqual(loadedEvents.first?.costMicroUSD, 2_000_000)
        XCTAssertEqual(loadedPolicy.dailyLimitMicroUSD, 8_000_000)

        // Two secrets on the SAME line plus an AWS key and GitHub PAT on the next line
        let multiSecretInput = "curl -H 'x-api-key: sk-ant-api03-111122223333444455556666' -H 'Authorization: sk-proj-aaaabbbbccccddddeeeeffff0000'\nAWS=AKIA1234567890ABCDEF GH=ghp_1234567890abcdefghijklmnopqrstuv"
        let redaction = SecretRedactor.sanitize(multiSecretInput)

        XCTAssertEqual(redaction.redactedCount, 4)
        XCTAssertFalse(redaction.sanitizedText.contains("sk-ant-api03"))
        XCTAssertFalse(redaction.sanitizedText.contains("sk-proj-"))
        XCTAssertFalse(redaction.sanitizedText.contains("AKIA1234567890ABCDEF"))
        XCTAssertFalse(redaction.sanitizedText.contains("ghp_1234567890"))
        XCTAssertTrue(redaction.sanitizedText.contains("[REDACTED:ANTHROPIC_KEY#1]"))
        XCTAssertTrue(redaction.sanitizedText.contains("[REDACTED:OPENAI_KEY#1]"))
        XCTAssertTrue(redaction.sanitizedText.contains("[REDACTED:AWS_ACCESS_KEY#1]"))
        XCTAssertTrue(redaction.sanitizedText.contains("[REDACTED:GITHUB_TOKEN#1]"))
    }

    // MARK: - License Key Verification (Polar.sh / Lemon Squeezy Offline HMAC)
    func testLicenseKeyGenerationAndTamperRejection() {
        let email = "customer@indiehackers.com"
        let validKey = LicenseValidator.generateKey(forEmail: email)
        XCTAssertTrue(LicenseValidator.verifyKey(validKey, email: email))
        XCTAssertTrue(LicenseValidator.verifyKey(validKey.lowercased(), email: "  CUSTOMER@indiehackers.com "))
        XCTAssertFalse(LicenseValidator.verifyKey(validKey, email: "other@indiehackers.com"))
        XCTAssertFalse(LicenseValidator.verifyKey("TPPRO-DEADBEEF-00000000", email: email))
    }

    // MARK: - Phase 2 Pre-Mortem #1: Incremental Byte-Offset & Incomplete Trailing Line Recovery
    func testIncrementalAppendAndIncompleteTrailingLineRecovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = tempDir.appendingPathComponent("session.jsonl")
        let line1 = #"{"id":"inc-1","provider":"anthropic","model":"claude-sonnet-4","timestamp":"2026-11-02T12:00:00Z","usage":{"input_tokens":100000,"output_tokens":10000}}"# + "\n"
        let halfLine2PartA = #"{"id":"inc-2","provider":"openai","model":"gpt-4.1","timestamp":"2026-11-02T12:01:00Z","#
        let halfLine2PartB = #""usage":{"prompt_tokens":200000,"completion_tokens":20000}}"# + "\n"

        // Write complete line 1 + half-written line 2 (no trailing newline yet)
        try Data((line1 + halfLine2PartA).utf8).write(to: logFile)

        let ledger = UsageLedger()
        let firstScan = await LocalLogScanner.scanDirectories([tempDir], into: ledger, cursors: [:])
        XCTAssertEqual(firstScan.scannedFilesCount, 1)
        XCTAssertEqual(firstScan.ingestedEventsCount, 1, "Only the complete newline-terminated line 1 should be ingested")
        XCTAssertEqual(firstScan.skippedMalformedLinesCount, 0, "Half-written trailing line must remain buffered at byte offset, not skipped as malformed")

        // Now flush the second half of line 2 with its trailing newline
        let handle = try FileHandle(forWritingTo: logFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(halfLine2PartB.utf8))
        try handle.close()

        let secondScan = await LocalLogScanner.scanDirectories([tempDir], into: ledger, cursors: firstScan.updatedCursors)
        XCTAssertEqual(secondScan.ingestedEventsCount, 1, "Completed line 2 should be ingested cleanly on next poll")
        let allEvents = await ledger.allEventsSorted()
        XCTAssertEqual(allEvents.count, 2)
    }

    // MARK: - Phase 2 Pre-Mortem #2: Log Rotation / Truncation Resets Byte Offset Safely
    func testLogRotationOrTruncationResetsCursorSafely() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = tempDir.appendingPathComponent("rotated.jsonl")
        let initialLines = """
        {"id":"rot-1","provider":"anthropic","model":"claude-sonnet-4","timestamp":"2026-11-02T12:00:00Z","usage":{"input_tokens":100000,"output_tokens":10000}}
        {"id":"rot-2","provider":"anthropic","model":"claude-sonnet-4","timestamp":"2026-11-02T12:05:00Z","usage":{"input_tokens":100000,"output_tokens":10000}}
        """ + "\n"
        try Data(initialLines.utf8).write(to: logFile)

        let ledger = UsageLedger()
        let scan1 = await LocalLogScanner.scanDirectories([tempDir], into: ledger, cursors: [:])
        XCTAssertEqual(scan1.ingestedEventsCount, 2)

        // Simulate log rotation: overwrite file with a shorter single-line file
        let shorterRotatedLine = #"{"id":"rot-3","provider":"gemini","model":"gemini-3-pro","timestamp":"2026-11-02T12:10:00Z","usage":{"input_tokens":50000,"output_tokens":5000}}"# + "\n"
        try Data(shorterRotatedLine.utf8).write(to: logFile, options: .atomic)

        let scan2 = await LocalLogScanner.scanDirectories([tempDir], into: ledger, cursors: scan1.updatedCursors)
        XCTAssertEqual(scan2.ingestedEventsCount, 1, "Truncated/rotated file must reset cursor to 0 and ingest rot-3")
        let totalEvents = await ledger.allEventsSorted().count
        XCTAssertEqual(totalEvents, 3)
    }

    // MARK: - Phase 2 Pre-Mortem #3: Nested Directory Traversal & Non-JSONL Filtering
    func testDirectoryScannerFindsNestedJSONLAndIgnoresOtherFiles() async throws {
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nestedDir = rootDir.appendingPathComponent("workspace-a/logs")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let validJSONL = nestedDir.appendingPathComponent("claude.jsonl")
        let ignoredTxt = nestedDir.appendingPathComponent("notes.txt")
        try Data((#"{"id":"nest-1","provider":"anthropic","model":"claude-sonnet-4","timestamp":"2026-11-02T12:20:00Z","usage":{"input_tokens":100000,"output_tokens":20000}}"# + "\n").utf8).write(to: validJSONL)
        try Data("not jsonl".utf8).write(to: ignoredTxt)

        let ledger = UsageLedger()
        let report = await LocalLogScanner.scanDirectories([rootDir], into: ledger)
        XCTAssertEqual(report.scannedFilesCount, 1)
        XCTAssertEqual(report.ingestedEventsCount, 1)
    }
}
