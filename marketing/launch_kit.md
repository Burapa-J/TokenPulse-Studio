# TokenPulse Studio — Monetization Setup & Global Launch Kit

## 1. Polar.sh / Lemon Squeezy Product Tiers (Copy-Paste Setup)

| Tier Name | Billing Type | Price (USD) | Target Buyer | License Fulfillment |
|---|---|---|---|---|
| **TokenPulse Studio — Solo Pro** | One-Time Purchase | **$39.00** | Individual macOS developers using Claude Code, Cursor, OpenAI, Gemini | Generates `TPPRO-<HEX>-<HMAC>` key via `LicenseValidator.generateKey(forEmail:)` |
| **TokenPulse Studio — Team Pack (3 Macs)** | One-Time Purchase | **$99.00** | Startup engineering teams & agencies | 3 activations per work domain |
| **TokenPulse Cloud Team Sync** | Monthly Subscription | **$12.00 / mo** | Teams wanting centralized monthly invoice & budget alerts | Recurring MRR tier |

### Revenue Math to 100,000 THB/Month (~$2,950 USD/Month)
- **45 Solo Pro sales/month** (`45 × $39 = $1,755`)
- **8 Team Pack sales/month** (`8 × $99 = $792`)
- **35 Cloud Sync subscribers** (`35 × $12 = $420`)
- **Total Monthly Gross:** **$2,967 USD (~100,800 THB/month)**

---

## 2. Copy-Paste Launch Posts (Ready for Gate #4 Approval)

### A. Hacker News (`Show HN`)
**Title:**
`Show HN: TokenPulse – Native Swift 6 macOS menu bar AI spend radar and local secret redactor`

**Text:**
```text
Hi HN,

After accidentally burning $48 in a single afternoon of multi-agent Claude Code + GPT-4.1 runs—and catching myself nearly pasting a config snippet containing a live AWS key into a prompt—I built TokenPulse Studio for macOS.

What it does:
1. Real-Time AI Spend Radar: Tails local JSONL usage logs (Claude Code, OpenAI/Codex, Gemini CLI, Cursor, Ollama) with zero proxy middleman. Uses exact integer micro-dollar accounting and trips a visual budget circuit breaker before daily/monthly spend spirals.
2. 100% On-Device Secret Redactor: Scans code/configs in memory and scrubs Anthropic, OpenAI, Gemini, AWS, GitHub PAT, Slack, JWT Bearer, and PEM private keys into [REDACTED:KIND#N] placeholders before copying to your clipboard.
3. Native Swift 6 + SwiftUI MenuBarExtra: <18 MB RAM footprint, zero Electron, strict actor isolation, offline HMAC license key verification.

There's a 7-day full-featured trial and a $39 one-time license (no mandatory subscription for local features). Happy to answer any questions about the Swift 6 actor ledger or log parsing architecture!
```

### B. Reddit (`r/macapps` & `r/ClaudeAI`)
**Title:**
`[Launch] TokenPulse Studio — Lightweight native SwiftUI menu bar app to track Claude/OpenAI/Gemini spend & auto-scrub API keys from prompts`

**Body:**
```markdown
Hey r/macapps!

I built **TokenPulse Studio**, a pure native macOS menu bar utility (Swift 6, ~15MB RAM, no Electron) designed for developers and power users who live in Claude Code, Cursor, ChatGPT, and Gemini.

**Why I built it:**
- **Stop surprise API bills:** Tracks real-time token consumption and exact dollar cost across Anthropic, OpenAI, Gemini, and Ollama right in your menu bar, with a configurable daily/monthly Budget Circuit Breaker.
- **Never leak an API key into an LLM again:** Includes a 1-click **On-Device Secret Redactor** that strips `sk-ant-*`, `sk-proj-*`, `AIzaSy*`, `AKIA*`, `ghp_*`, and PEM private keys locally before they touch your clipboard.
- **No subscription fatigue:** 7-day free trial, then a simple **$39 one-time lifetime license** (signed with Apple Developer ID).
```

### C. Product Hunt Launch Copy
- **Name:** TokenPulse Studio
- **Tagline:** Native macOS menu bar AI spend guard & local secret redactor
- **First Comment:**
  > "Hi Product Hunt! 👋 We built TokenPulse Studio for every developer and founder running multi-model AI workflows on macOS. Instead of routing your traffic through a third-party cloud proxy, TokenPulse reads local usage logs directly on your Mac and scrubs API keys/secrets on-device before they ever leave your clipboard."
