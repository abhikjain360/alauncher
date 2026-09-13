import Core
import Testing
@testable import Dictation

private let prefixes = AskSettings().prefixes

@Test(arguments: [
    ("My Lord, what is the time?", "what is the time?"),
    ("my lord. How far is the moon", "How far is the moon"),
    ("Milord what's the weather", "what's the weather"),
    ("My-lord — tell me a joke", "tell me a joke"),
    ("MY LORD: define entropy", "define entropy"),
    ("Mylord, is it raining", "is it raining"),
    ("  …My Lord, spaces first", "spaces first"),
    ("My Lord, $5 in euros?", "$5 in euros?"),
    ("My Lord.", ""),
])
func askPrefixVariantsMatch(text: String, question: String) {
    #expect(TextProcessing.askQuestion(in: text, prefixes: prefixes) == question)
}

@Test(arguments: [
    "My lordship is here",
    "Oh my lord, that hurt",
    "Hello there",
    "My",
    "",
])
func askPrefixMissesAreNil(text: String) {
    #expect(TextProcessing.askQuestion(in: text, prefixes: prefixes) == nil)
}

@Test func askPrefixesFromConfigMayContainHyphensAndSpaces() {
    #expect(TextProcessing.askQuestion(in: "my lord, x", prefixes: ["my-lord"]) == "x")
    #expect(TextProcessing.askQuestion(in: "Hey, computer! Open the pod bay doors", prefixes: ["hey computer"]) == "Open the pod bay doors")
    #expect(TextProcessing.askQuestion(in: "anything", prefixes: ["", "  "]) == nil)
}

@Test(arguments: [
    ("um, so", "so"),
    ("Um, so I think", "So I think"),
    ("So, um, I think", "So, I think"),
    ("I think uh we should", "I think we should"),
    ("we should, um.", "we should."),
    ("Uh. Okay.", "Okay."),
    ("UM, HMM, yes", "Yes"),
    ("Mhm.", ""),
    ("I said um 3 times", "I said 3 times"),
    ("umbrella and her era", "umbrella and her era"),
    ("No fillers here.", "No fillers here."),
])
func fillersAreRemovedAsWholeWords(text: String, expected: String) {
    #expect(TextProcessing.removeFillers(text, fillers: DictationSettings().fillerWords) == expected)
}

@Test func noFillerWordsLeavesTextAlone() {
    #expect(TextProcessing.removeFillers("um,  so", fillers: []) == "um,  so")
}

@Test func promptFillingReplacesEveryPlaceholder() {
    #expect(TextProcessing.fillPrompt("Clean: ${output}.", transcript: "hello") == "Clean: hello.")
    #expect(TextProcessing.fillPrompt("${output} / ${output}", transcript: "a") == "a / a")
    #expect(TextProcessing.fillPrompt("Keep $ signs: ${output}", transcript: "x ${output} y") == "Keep $ signs: x ${output} y")
}

@Test func promptWithoutPlaceholderGetsTheTranscriptAfterABlankLine() {
    #expect(TextProcessing.fillPrompt("Fix this", transcript: "hello") == "Fix this\n\nhello")
    #expect(TextProcessing.fillPrompt("Fix this\n\n", transcript: "hello") == "Fix this\n\nhello")
    #expect(TextProcessing.fillPrompt("", transcript: "hello") == "hello")
}

@Test func defaultPromptHasOnePlaceholder() {
    let filled = TextProcessing.fillPrompt(CleanupSettings.defaultPrompt, transcript: "TRANSCRIPT")
    #expect(filled.contains("<transcript>\nTRANSCRIPT\n</transcript>"))
    #expect(!filled.contains("${output}"))
}

@Test func blankText() {
    #expect(TextProcessing.isBlank(""))
    #expect(TextProcessing.isBlank("  \n"))
    #expect(TextProcessing.isBlank("... —"))
    #expect(!TextProcessing.isBlank("a"))
    #expect(!TextProcessing.isBlank("5"))
}
