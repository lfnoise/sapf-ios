//    SAPF - Sound As Pure Form
//    Tests for remembering where you are in a document.

import XCTest
@testable import Sapf

final class EditorPositionTests: XCTestCase {
    private let text = (1...3000).map { "\($0) 0 sinosc .1 * ; line \($0)" }.joined(separator: "\n")

    private func lineStart(_ n: Int) -> Int {
        (text as NSString).range(of: "\(n) 0 sinosc .1 * ; line \(n)\n").location
    }

    private func assertSame(_ restored: CodeTextView.Position, _ saved: CodeTextView.Position,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(restored.top, saved.top, file: file, line: line)
        XCTAssertEqual(restored.selection, saved.selection, file: file, line: line)
        XCTAssertEqual(restored.selectionLength, saved.selectionLength, file: file, line: line)
        XCTAssertEqual(restored.topLineFraction ?? 0, saved.topLineFraction ?? 0, accuracy: 0.02, file: file, line: line)
    }

    func testRestoreScrollsTheLineToTheTop() {
        let editor = CodeTextView()
        editor.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        editor.setText(text)
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.position.top, 0)

        let saved = CodeTextView.Position(top: lineStart(1500), selection: lineStart(1502) + 3, selectionLength: 5,
                                          topLineFraction: 0.5)
        editor.restore(saved)
        assertSame(editor.position, saved)
    }

    func testRestoreWaitsForLayout() {
        let editor = CodeTextView()
        editor.setText(text)
        let saved = CodeTextView.Position(top: lineStart(2000), selection: lineStart(2000), selectionLength: 0,
                                          topLineFraction: 0)
        editor.restore(saved)
        editor.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        editor.layoutIfNeeded()
        assertSame(editor.position, saved)
    }

    func testPositionPastTheEndIsClamped() {
        let editor = CodeTextView()
        editor.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        editor.setText("1 2 +\n3 4 *\n")
        editor.restore(CodeTextView.Position(top: 5000, selection: 5000, selectionLength: 10))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 12, length: 0))
    }
}
