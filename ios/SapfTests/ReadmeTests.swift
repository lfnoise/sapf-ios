//    SAPF - Sound As Pure Form
//    Tests for the README shown in the app.

import XCTest
@testable import Sapf

final class ReadmeTests: XCTestCase {
    func testAppReadmeLeavesOutCommandLineSections() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "README", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let readme = DocumentStore.appReadme(from: text)
        for gone in ["QUICK SET-UP", "IPHONE AND IPAD", "COMMAND LINE", "ENVIRONMENT VARIABLES", "xattr"] {
            XCTAssertFalse(readme.contains(gone), gone)
        }
        for kept in ["WHAT", "WHY", "BUILT IN FUNCTION HELP", "AUTO-MAPPING", "REFERENCES"] {
            XCTAssertTrue(readme.contains(kept), kept)
        }
    }

    func testAppReadmeIsUnchangedWithoutTheHeadings() {
        XCTAssertEqual(DocumentStore.appReadme(from: "WHAT\nsomething\n"), "WHAT\nsomething\n")
    }

    func testReflowJoinsWrappedProse() {
        let text = """
            Expressions are sequences of words (or other syntactic elements) written
            in postfix form, and run from left to right.
        """
        XCTAssertEqual(DocumentStore.reflow(text),
                       "    Expressions are sequences of words (or other syntactic elements) written in postfix form, and run from left to right.")
    }

    func testReflowKeepsListItemsAndCode() {
        let text = """
            Functions are applied from left to right instead of inside out.
            Support for multiple return values comes for free.

                [1 2] @ [10 20] +  -->  [[11 21] [12 22]] and a long line of code here
                [1 2] [10 20] @ +  -->  [[11 12] [21 22]]
            { :a 1 :b 2 } = x    ; the value 1 is bound to the key a, and the value 2 is
                                 ; bound to the key b.
        """
        XCTAssertEqual(DocumentStore.reflow(text), text)
    }
}
