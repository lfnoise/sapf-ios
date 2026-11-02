//    SAPF - Sound As Pure Form
//    Tests for the All Functions page.

import XCTest
@testable import Sapf

final class FunctionListTests: XCTestCase {
    func testEntryWithMaskAndEffect() {
        XCTAssertEqual(FunctionList.entry("sinosc @kk (freq phase --> out) a sine wave oscillator."),
                       .init(name: "sinosc", mask: "kk", effect: "(freq phase --> out)", description: "a sine wave oscillator."))
    }

    func testEffectWithParenthesesInside() {
        XCTAssertEqual(FunctionList.entry("do (list \\item[..] -->) applies the function (once) to each item.")?.effect,
                       "(list \\item[..] -->)")
    }

    func testNamesCanStartWithAStar() {
        XCTAssertEqual(FunctionList.entry("*+ @zzz (a b c --> out) multiply add. a b * c +")?.name, "*+")
    }

    func testHeadingsAndLegendAreNotEntries() {
        XCTAssertNil(FunctionList.entry("*** stack ops ***"))
        XCTAssertNil(FunctionList.entry("Argument Automapping legend:"))
        XCTAssertNil(FunctionList.entry("   a - as is. argument is not automapped."))
    }

    func testStyledTextBoldsNames() {
        let text = FunctionList.attributedText(from: "BUILT IN FUNCTIONS\n\n*** math ***\nsinosc @kk (freq phase --> out) a sine wave.\n")
        XCTAssertEqual(text.string, "Built In Functions\nmath\nsinosc  @kk  (freq phase --> out)  a sine wave.\n")
        let nameRange = (text.string as NSString).range(of: "sinosc")
        let font = text.attribute(.font, at: nameRange.location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        let style = text.attribute(.paragraphStyle, at: nameRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0, "wrapped lines are indented")
    }
}
