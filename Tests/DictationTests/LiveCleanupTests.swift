import Core
import Foundation
import Testing
@testable import Dictation

/// Opt-in: `ALAUNCHER_LIVE_CLEANUP=1`. Real round trips to the configured cleanup endpoint with
/// the key from secrets.toml (loaded through ConfigLoader, never printed). The texts are made up.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ALAUNCHER_LIVE_CLEANUP"] == "1"), .timeLimit(.minutes(2)))
func liveCleanupRoundTrips() async throws {
    let configText = (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? ""
    let secretsText = try? String(contentsOf: Paths.secretsFile, encoding: .utf8)
    var config = try ConfigLoader.load(configText: configText, secretsText: secretsText)
    try ConfigLoader.resolveSecrets(&config, secretsText: secretsText)
    try #require(config.cleanup.apiKey?.isEmpty == false, "no cleanup key in secrets.toml")

    let client = CleanupClient()
    let samples = [
        "um so i think we should uh ship the fix on monday",
        "can you check the engine x config and restart the server",
        "the meeting is at three thirty tomorrow with twenty five people",
    ]
    for text in samples {
        let start = Date()
        let cleaned = try await client.cleanUp(text, settings: config.cleanup)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "live cleanup (%@, reasoning %@): %.2f s: %@", config.cleanup.model, config.cleanup.reasoning, elapsed, cleaned))
        #expect(!cleaned.isEmpty)
    }
}
