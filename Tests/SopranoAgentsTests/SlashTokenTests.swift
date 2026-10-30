import AppKit
import Testing
@testable import SopranoAgents

struct SlashTokenTests {
    private let slash: Set<Character> = ["/"]

    @Test func aSlashWordAtTheStartOfALineIsATokenWhileTheCaretIsInsideIt() throws {
        let token = try #require(SlashToken.at("/rev", caret: 4, sigils: slash))
        #expect(token.sigil == "/")
        #expect(token.range == NSRange(location: 0, length: 4))
        #expect(token.query == "rev")

        let second = try #require(SlashToken.at("Look at this\n/skill:pr now", caret: 18, sigils: slash))
        #expect(second.range == NSRange(location: 13, length: 9))
        #expect(second.query == "skil")
    }

    @Test func theQueryStopsAtTheCaretButTheTokenRunsToItsEnd() throws {
        let token = try #require(SlashToken.at("/review src", caret: 3, sigils: slash))
        #expect(token.query == "re")
        #expect(token.range == NSRange(location: 0, length: 7))
    }

    @Test func noTokenMidLineBeforeTheSigilAfterTheWordOrForOtherSigils() {
        #expect(SlashToken.at("see /review", caret: 11, sigils: slash) == nil)
        #expect(SlashToken.at("/review", caret: 0, sigils: slash) == nil)
        #expect(SlashToken.at("/review ", caret: 8, sigils: slash) == nil)
        #expect(SlashToken.at("$pdf", caret: 4, sigils: slash) == nil)
        #expect(SlashToken.at("$pdf", caret: 4, sigils: ["/", "$"])?.query == "pdf")
        #expect(SlashToken.at("path/to", caret: 7, sigils: slash) == nil)
    }

    @Test func aLoneSigilOpensAnEmptyQuery() throws {
        let token = try #require(SlashToken.at("/", caret: 1, sigils: slash))
        #expect(token.query.isEmpty)
        #expect(token.range == NSRange(location: 0, length: 1))
    }

    @Test func insertingReplacesTheWholeTokenAndKeepsWhatFollowsWithoutDoublingTheSpace() throws {
        let text = "/rev src/app"
        let token = try #require(SlashToken.at(text, caret: 4, sigils: slash))
        let edit = token.replacement(inserting: "/review ", in: text)
        #expect(edit.range == NSRange(location: 0, length: 5))
        #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.text) == "/review src/app")

        let bare = try #require(SlashToken.at("/mo", caret: 3, sigils: slash))
        let insert = bare.replacement(inserting: "/model ", in: "/mo")
        #expect(insert.range == NSRange(location: 0, length: 3))
        #expect(insert.text == "/model ")
    }
}
