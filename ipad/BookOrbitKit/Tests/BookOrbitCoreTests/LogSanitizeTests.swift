import BookOrbitCore
import Testing

@Suite struct LogSanitizeTests {
    @Test func quotesBackslashesAndLineBreaksCannotBreakOutOfAQuotedField() {
        #expect(sanitizeLogValue("say \"hi\"\nC:\\books\tnow") == #"say \"hi\" C:\\books now"#)
    }

    @Test func longValuesAreCutBeforeEscaping() {
        #expect(sanitizeLogValue(String(repeating: "a", count: 300)).count == 200)
        #expect(sanitizeLogValue("abc\"", maxLength: 4) == #"abc\""#)
    }
}
