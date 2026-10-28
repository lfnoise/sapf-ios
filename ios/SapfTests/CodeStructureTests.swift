//    SAPF - Sound As Pure Form
//    Tests for finding evaluable blocks and matching brackets.

import XCTest
@testable import Sapf

final class CodeStructureTests: XCTestCase {
    private func structure(_ code: String) -> (NSString, CodeStructure) {
        let text = code as NSString
        let tokens = SapfLexer(builtIns: [], userWords: []).tokenize(text)
        return (text, CodeStructure(text: text, tokens: tokens))
    }

    private func blockTexts(_ code: String) -> [String] {
        let (text, s) = structure(code)
        return s.blocks.map { text.substring(with: s.trimmed($0.range)) }
    }

    func testBlankLinesSeparateBlocks() {
        XCTAssertEqual(blockTexts("1 2 +\n3 4 +\n\n440 0 sinosc\n"), ["1 2 +\n3 4 +", "440 0 sinosc"])
    }

    func testBlankLinesInsideBracketsDoNotSplit() {
        let code = "\\[\n\t4 = a\n\n\ta 2 *\n] play\n\nnext"
        XCTAssertEqual(blockTexts(code), ["\\[\n\t4 = a\n\n\ta 2 *\n] play", "next"])
    }

    func testBracketsInCommentsAndStringsAreIgnored() {
        XCTAssertEqual(blockTexts("1 ; (\n\n\"[\" 2\n\n3"), ["1 ; (", "\"[\" 2", "3"])
    }

    func testCommentOnlyBlockIsNotRunnable() {
        let (_, s) = structure(";; title\n\n;; heading\n1 2 +\n")
        XCTAssertEqual(s.blocks.count, 2)
        XCTAssertNil(s.blocks[0].codeStart)
        XCTAssertEqual(s.blocks[1].codeStart, 21)
    }

    func testBlockAtCursorIncludesBlankLineBelow() {
        let (text, s) = structure("1 2 +\n\n3 4 +\n")
        XCTAssertEqual(s.block(at: 6).map { text.substring(with: $0.range) }, "1 2 +\n")
        XCTAssertEqual(s.block(at: 9).map { text.substring(with: $0.range) }, "3 4 +\n")
    }

    func testMatchingBracket() {
        let (text, s) = structure("(1 [2 3] +)")
        XCTAssertEqual(s.pair(withBracketAt: 0).map { text.substring(with: $0) }, "(1 [2 3] +)")
        XCTAssertEqual(s.pair(withBracketAt: 7).map { text.substring(with: $0) }, "[2 3]")
        XCTAssertNil(s.pair(withBracketAt: 1))
    }

    func testExpandSelection() {
        let (text, s) = structure("x (1 [2 3] +) play\ny\n\nz")
        var r = NSRange(location: 6, length: 0) // between 2 and space
        var steps: [String] = []
        while let next = s.expand(r) {
            steps.append(text.substring(with: next))
            r = next
        }
        XCTAssertEqual(steps, ["2 3", "[2 3]", "1 [2 3] +", "(1 [2 3] +)", "x (1 [2 3] +) play\ny"])
    }

    func testExamplesFile() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sapf-examples", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let (ns, s) = structure(text)
        XCTAssertGreaterThan(s.blocks.count, 100)
        // Every runnable block has balanced brackets.
        for block in s.blocks where block.codeStart != nil {
            let pairsInside = s.pairs.filter { NSIntersectionRange($0, block.range).length > 0 }
            for pair in pairsInside {
                XCTAssertTrue(NSIntersectionRange(pair, block.range) == pair,
                              "bracket pair crosses a block boundary: \(ns.substring(with: block.range))")
            }
        }
    }
}
