import Core
import Testing

@Test func emptyConfigTakesDefaults() throws {
    let config = try ConfigLoader.load(configText: "", secretsText: nil)
    #expect(config == Config())
}
