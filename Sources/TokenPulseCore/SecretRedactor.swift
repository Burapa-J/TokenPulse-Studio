import Foundation

public enum SecretKind: String, Codable, Sendable, CaseIterable {
    case anthropicKey = "ANTHROPIC_KEY"
    case openAIKey = "OPENAI_KEY"
    case geminiKey = "GEMINI_KEY"
    case awsAccessKey = "AWS_ACCESS_KEY"
    case githubToken = "GITHUB_TOKEN"
    case slackToken = "SLACK_TOKEN"
    case privateKeyPEM = "PRIVATE_KEY_PEM"
    case bearerToken = "BEARER_TOKEN"
}

public struct RedactionResult: Equatable, Sendable {
    public let sanitizedText: String
    public let redactedCount: Int
    public let detectedKinds: [SecretKind]
    public let estimatedTokens: Int

    public init(
        sanitizedText: String,
        redactedCount: Int,
        detectedKinds: [SecretKind],
        estimatedTokens: Int
    ) {
        self.sanitizedText = sanitizedText
        self.redactedCount = redactedCount
        self.detectedKinds = detectedKinds
        self.estimatedTokens = estimatedTokens
    }
}

public enum SecretRedactor {
    private struct Rule {
        let kind: SecretKind
        let pattern: String
    }

    // Ordered from most specific to broadest token patterns; non-greedy / token-bounded so multiple secrets on the same line are caught independently.
    private static let rules: [Rule] = [
        Rule(
            kind: .privateKeyPEM,
            pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        ),
        Rule(
            kind: .anthropicKey,
            pattern: #"sk-ant-[a-zA-Z0-9\-_]{16,128}"#
        ),
        Rule(
            kind: .openAIKey,
            pattern: #"sk-(?:proj-|live-|test-)?[a-zA-Z0-9\-_]{20,128}"#
        ),
        Rule(
            kind: .geminiKey,
            pattern: #"AIzaSy[a-zA-Z0-9\-_]{33}"#
        ),
        Rule(
            kind: .awsAccessKey,
            pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#
        ),
        Rule(
            kind: .githubToken,
            pattern: #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,100}\b|\bgithub_pat_[A-Za-z0-9_]{22,120}\b"#
        ),
        Rule(
            kind: .slackToken,
            pattern: #"\bxox[baprs]-[0-9A-Za-z\-]{16,100}\b"#
        ),
        Rule(
            kind: .bearerToken,
            pattern: #"Bearer\s+eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+"#
        )
    ]

    public static func sanitize(_ input: String) -> RedactionResult {
        var working = input
        var totalRedacted = 0
        var detectedKinds: [SecretKind] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else {
                continue
            }
            let matches = regex.matches(
                in: working,
                options: [],
                range: NSRange(working.startIndex..<working.endIndex, in: working)
            )
            guard !matches.isEmpty else { continue }

            detectedKinds.append(rule.kind)
            // Replace from back to front so NSRange offsets remain valid for multiple secrets on the same line.
            for (reverseIdx, match) in matches.enumerated().reversed() {
                guard let range = Range(match.range, in: working) else { continue }
                let ordinal = reverseIdx + 1
                let replacement = "[REDACTED:\(rule.kind.rawValue)#\(ordinal)]"
                working.replaceSubrange(range, with: replacement)
                totalRedacted += 1
            }
        }

        // Standard ~4 chars/token heuristic for developer prompts
        let charCount = working.utf8.count
        let estimatedTokens = max(1, (charCount + 3) / 4)

        return RedactionResult(
            sanitizedText: working,
            redactedCount: totalRedacted,
            detectedKinds: detectedKinds,
            estimatedTokens: estimatedTokens
        )
    }
}
