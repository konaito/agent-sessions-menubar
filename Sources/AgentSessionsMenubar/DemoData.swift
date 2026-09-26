import Foundation

/// README のスクショ用の架空データ（--render ... --demo）。実在のセッションは含めない
enum DemoData {
    static let claude: [SessionSummary] = make(prefix: "claude", tool: "claude -r", [
        ("web-dashboard", "Fix flaky login test", "Login test was racing the session cookie. Fixed with an explicit wait; next is the full e2e run in CI."),
        ("api-server", "Add rate limiting", "Token bucket middleware is in and unit tests pass. Waiting for you to pick 100 or 300 req/min for the free tier."),
        ("docs", "Rewrite onboarding guide", "Draft of all 5 chapters is done. Chapter 3 still needs real screenshots from the new setup wizard."),
        ("ios-app", "Crash on iPad split view", "Reproduced on iPadOS simulator. The layout code assumes a full-width window; fixing the constraints now."),
        ("infra", "Migrate CI to arm64 runners", "Build time went from 14 to 6 minutes. Two jobs still fail because a Docker image has no arm64 variant."),
        ("design-system", "Dark mode tokens", "Added 42 color tokens and replaced hard-coded hex values in 18 components. Contrast check is next."),
        ("data-pipeline", "Deduplicate events", "Found 3.2% duplicate events from client retries. Proposed an idempotency key; not applied yet."),
        ("blog", "Post: shipping on Fridays", "Outline approved. Writing section 2 about feature flags and rollback plans."),
        ("cli-tool", "Release v0.9.0", "Changelog and tag are ready. Homebrew formula PR is open and waiting for review."),
        ("landing-page", "Pricing section A/B test", "Variant B is live for 50% of visitors. Results after 2,000 visits will decide the default."),
    ])

    static let codex: [SessionSummary] = make(prefix: "codex", tool: "codex resume", [
        ("payments", "Handle webhook retries", "Webhook handler now ignores already-processed event IDs. Added a test for the retry storm case."),
        ("mobile-api", "Pagination for /feed", "Switched /feed to cursor pagination. Old offset clients still work behind a compatibility shim."),
        ("search", "Tune ranking weights", "Recency weight 0.3 → 0.2 improved click-through in offline eval by 4%. Want me to ship it?"),
        ("auth", "Passkey sign-in", "Registration and sign-in flows work on Safari and Chrome. Firefox needs a polyfill check."),
        ("analytics", "Weekly retention chart", "Chart renders from the new cohort table. Numbers match the SQL spot check for the last 4 weeks."),
        ("notifications", "Quiet hours setting", "Settings UI and API are done. Scheduler still sends during quiet hours; tracing the timezone bug."),
        ("monorepo", "Upgrade TypeScript to 5.x", "212 type errors down to 9. The rest are in generated code; regenerating clients next."),
        ("support-bot", "Escalation rules", "Bot now hands off billing questions to a human after one failed answer. Needs copy review."),
        ("maps", "Offline tile cache", "Tiles are cached for the last 3 viewed regions. Cache eviction is based on size, 200 MB max."),
        ("admin-panel", "Bulk user export", "CSV export streams in chunks, so 1M users no longer time out. Added a progress indicator."),
    ])

    static let claudeUsage = Usage(weekly: 42, session: 17)
    static let codexUsage = Usage(weekly: 23, session: nil)

    private static func make(prefix: String, tool: String, _ rows: [(String, String, String)]) -> [SessionSummary] {
        rows.enumerated().map { i, row in
            SessionSummary(
                id: "\(prefix)-\(i)",
                directory: row.0,
                title: row.1,
                snippet: SessionStore.truncate(row.2),
                isRecap: false,
                updatedAt: Date(),
                resumeCommand: "cd ~/src/\(row.0) && \(tool) <id>"
            )
        }
    }
}
