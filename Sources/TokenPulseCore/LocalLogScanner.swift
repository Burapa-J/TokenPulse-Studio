import Foundation

public struct FileCursor: Codable, Equatable, Sendable {
    public let path: String
    public let byteOffset: UInt64
    public let lastModifiedTimeInterval: TimeInterval

    public init(path: String, byteOffset: UInt64, lastModifiedTimeInterval: TimeInterval) {
        self.path = path
        self.byteOffset = byteOffset
        self.lastModifiedTimeInterval = lastModifiedTimeInterval
    }
}

public struct DirectoryScanReport: Equatable, Sendable {
    public let scannedFilesCount: Int
    public let ingestedEventsCount: Int
    public let duplicateIgnoredCount: Int
    public let skippedMalformedLinesCount: Int
    public let updatedCursors: [String: FileCursor]

    public init(
        scannedFilesCount: Int,
        ingestedEventsCount: Int,
        duplicateIgnoredCount: Int,
        skippedMalformedLinesCount: Int,
        updatedCursors: [String: FileCursor]
    ) {
        self.scannedFilesCount = scannedFilesCount
        self.ingestedEventsCount = ingestedEventsCount
        self.duplicateIgnoredCount = duplicateIgnoredCount
        self.skippedMalformedLinesCount = skippedMalformedLinesCount
        self.updatedCursors = updatedCursors
    }
}

public enum LocalLogScanner {
    /// Default local AI tool directories on macOS (Claude Code, Codex, TokenPulse custom drop-folder).
    public static func defaultWatchDirectories(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        return [
            homeDirectory.appendingPathComponent(".claude/projects"),
            homeDirectory.appendingPathComponent(".codex"),
            homeDirectory.appendingPathComponent(".config/tokenpulse/logs")
        ]
    }

    /// Incrementally reads newly appended complete lines (`\n`-terminated) from a single `.jsonl` file.
    /// If the file was truncated or rotated (`fileSize < previousOffset`), resets offset to `0`.
    /// If the trailing line has no `\n` yet (mid-write), leaves those trailing bytes for the next poll.
    public static func readCompleteAppendedLines(
        fileURL: URL,
        previousCursor: FileCursor?
    ) throws -> (completeLinesText: String, newCursor: FileCursor) {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let startOffset: UInt64
        if let prev = previousCursor {
            startOffset = (fileSize < prev.byteOffset) ? 0 : prev.byteOffset
        } else {
            startOffset = 0
        }

        guard fileSize > startOffset else {
            return (
                "",
                FileCursor(path: fileURL.path, byteOffset: startOffset, lastModifiedTimeInterval: modDate)
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        guard let newData = try handle.readToEnd(), !newData.isEmpty else {
            return (
                "",
                FileCursor(path: fileURL.path, byteOffset: startOffset, lastModifiedTimeInterval: modDate)
            )
        }

        // Only advance up to the last newline byte (0x0A) so a half-written trailing line is not lost.
        let newlineByte: UInt8 = 0x0A
        guard let lastNewlineIdx = newData.lastIndex(of: newlineByte) else {
            // No complete line flushed yet; keep cursor at startOffset
            return (
                "",
                FileCursor(path: fileURL.path, byteOffset: startOffset, lastModifiedTimeInterval: modDate)
            )
        }

        let completeSlice = newData[newData.startIndex...lastNewlineIdx]
        let consumedBytes = UInt64(completeSlice.count)
        let updatedOffset = startOffset + consumedBytes
        let decodedText = String(decoding: completeSlice, as: UTF8.self)

        return (
            decodedText,
            FileCursor(path: fileURL.path, byteOffset: updatedOffset, lastModifiedTimeInterval: modDate)
        )
    }

    /// Recursively scans directories for `.jsonl` files, reads appended complete lines, and records them into `ledger`.
    public static func scanDirectories(
        _ directories: [URL],
        into ledger: UsageLedger,
        cursors: [String: FileCursor] = [:]
    ) async -> DirectoryScanReport {
        var updatedCursors = cursors
        var scannedFiles = 0
        var totalIngested = 0
        var totalDuplicates = 0
        var totalSkipped = 0

        let fm = FileManager.default
        for rootDir in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let enumerator = fm.enumerator(
                at: rootDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
            for fileURL in allURLs where fileURL.pathExtension.lowercased() == "jsonl" {
                let prevCursor = updatedCursors[fileURL.path]
                guard let (chunkText, nextCursor) = try? readCompleteAppendedLines(
                    fileURL: fileURL,
                    previousCursor: prevCursor
                ) else {
                    continue
                }
                scannedFiles += 1
                updatedCursors[fileURL.path] = nextCursor

                if !chunkText.isEmpty {
                    let projectHint = fileURL.deletingLastPathComponent().lastPathComponent
                    let report = await ledger.ingestJSONL(
                        chunkText,
                        defaultProvider: .anthropic,
                        defaultProject: projectHint
                    )
                    totalIngested += report.ingestedEventCount
                    totalDuplicates += report.duplicateIgnoredCount
                    totalSkipped += report.skippedMalformedLineCount
                }
            }
        }

        return DirectoryScanReport(
            scannedFilesCount: scannedFiles,
            ingestedEventsCount: totalIngested,
            duplicateIgnoredCount: totalDuplicates,
            skippedMalformedLinesCount: totalSkipped,
            updatedCursors: updatedCursors
        )
    }
}
