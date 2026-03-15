import XCTest
@testable import VoxPopuli

final class VoiceCommandProcessorTests: XCTestCase {

    let processor = VoiceCommandProcessor()

    func testNewLine() {
        XCTAssertEqual(processor.apply("Hello new line world"), "Hello\nworld")
    }

    func testNewParagraph() {
        XCTAssertEqual(processor.apply("First new paragraph second"), "First\n\nsecond")
    }

    func testPeriod() {
        XCTAssertEqual(processor.apply("End of sentence period"), "End of sentence.")
    }

    func testComma() {
        XCTAssertEqual(processor.apply("Hello comma world"), "Hello, world")
    }

    func testQuestionMark() {
        XCTAssertEqual(processor.apply("How are you question mark"), "How are you?")
    }

    func testExclamationMark() {
        XCTAssertEqual(processor.apply("Wow exclamation mark"), "Wow!")
        XCTAssertEqual(processor.apply("Wow exclamation point"), "Wow!")
    }

    func testColonAndSemicolon() {
        XCTAssertEqual(processor.apply("Dear sir colon"), "Dear sir:")
        XCTAssertEqual(processor.apply("First part semicolon second part"), "First part; second part")
    }

    func testQuotes() {
        XCTAssertEqual(processor.apply("He said open quote hello close quote"), "He said \"hello\"")
    }

    func testParens() {
        XCTAssertEqual(processor.apply("see appendix open paren page 5 close paren"), "see appendix (page 5)")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(processor.apply("Hello New Line world"), "Hello\nworld")
        XCTAssertEqual(processor.apply("Hello NEW LINE world"), "Hello\nworld")
    }

    func testMultipleCommands() {
        let input = "Hello comma how are you question mark new line I am fine period"
        let expected = "Hello, how are you?\nI am fine."
        XCTAssertEqual(processor.apply(input), expected)
    }

    func testNoCommandsPassthrough() {
        XCTAssertEqual(processor.apply("Just a normal sentence"), "Just a normal sentence")
    }

    func testConvertToTokens() {
        XCTAssertEqual(processor.convertToTokens("Hello new line world"), "Hello <NEWLINE> world")
        XCTAssertEqual(processor.convertToTokens("First new paragraph second"), "First <PARAGRAPH> second")
    }

    func testRestoreTokens() {
        XCTAssertEqual(processor.restoreTokens("Hello <NEWLINE> world"), "Hello\nworld")
        XCTAssertEqual(processor.restoreTokens("First <PARAGRAPH> second"), "First\n\nsecond")
    }
}
