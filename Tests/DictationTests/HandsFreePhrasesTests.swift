import Testing
@testable import Dictation

@Test(arguments: [
    ("Hey, launcher, write a test", "write a test"),
    ("HEY LAUNCHER: Write a test", "Write a test"),
    ("goodbye launcher, write a test", nil),
    ("hey launchership write a test", nil),
])
func wakePhraseRemainder(text: String, expected: String?) {
    #expect(HandsFreePhrases.afterWakePhrase(in: text, wakePhrases: ["hey launcher"]) == expected)
}

@Test(arguments: [
    "Goodbye, launcher!",
    "good bye launcher",
    "GOODBYE-launcher",
])
func offPhraseMatchesPunctuationAndSplitWords(text: String) {
    #expect(HandsFreePhrases.isOnly(text, phrases: ["goodbye launcher"]))
}

@Test func offPhraseRejectsExtraWords() {
    #expect(!HandsFreePhrases.isOnly("goodbye launcher now", phrases: ["goodbye launcher"]))
}

@Test(arguments: [
    ("Write the tests, send it.", "Write the tests,", true),
    ("Write the tests. Send it", "Write the tests.", true),
    ("Write the tests", "Write the tests", false),
    ("resend it", "resend it", false),
    ("Write the tests. Send it now", "Write the tests. Send it now", false),
])
func sendPhraseIsStrippedOnlyAtTheEnd(text: String, expected: String, sendIt: Bool) {
    let result = HandsFreePhrases.strippingSendPhrase(from: text, sendPhrases: ["send it"])
    #expect(result.text == expected)
    #expect(result.sendIt == sendIt)
}
