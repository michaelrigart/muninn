import Testing
@testable import MuninnCore

struct InlineCodeTests {
    @Test func plainTextIsOnePlainRun() {
        #expect(InlineCode.runs("Try again") == [.init(text: "Try again", isCode: false)])
    }

    @Test func backtickSpanIsACodeRun() {
        #expect(InlineCode.runs("a `b` c") == [
            .init(text: "a ", isCode: false),
            .init(text: "b", isCode: true),
            .init(text: " c", isCode: false),
        ])
    }

    @Test func unpairedTrailingBacktickStaysLiteral() {
        #expect(InlineCode.runs("c `d") == [.init(text: "c `d", isCode: false)])
    }

    @Test func emptySpanGivesNoCodeRunAndNoBackticks() {
        #expect(InlineCode.runs("``").isEmpty)
    }

    @Test func asterisksAndUnderscoresStayPlain() {
        #expect(InlineCode.runs("qwen_3*b") == [.init(text: "qwen_3*b", isCode: false)])
    }
}
