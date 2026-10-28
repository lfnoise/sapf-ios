//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// A chunk of code you'd evaluate at once: consecutive non-blank lines, also spanning blank
/// lines that fall inside brackets, so a multi-line ( ... ) or \[ ... ] stays in one piece.
struct CodeBlock: Equatable {
    /// Whole lines, including the final newline.
    var range: NSRange
    /// Where the first code that isn't a comment starts. nil for a block of only comments.
    var codeStart: Int?
}

/// Blocks and matching brackets, worked out from the lexer's tokens so that brackets
/// inside comments and strings don't count.
struct CodeStructure {
    private(set) var blocks: [CodeBlock] = []
    /// Matched bracket pairs, each from the opening bracket through the closing one, sorted by start.
    private(set) var pairs: [NSRange] = []
    private var text: NSString = ""

    init() {}

    init(text: NSString, tokens: [Token]) {
        self.text = text
        pairs = Self.findPairs(text: text, tokens: tokens)
        blocks = Self.findBlocks(text: text, tokens: tokens)
    }

    private static func isOpen(_ text: NSString, _ token: Token) -> Bool {
        let c = text.character(at: token.range.location)
        return c == 0x28 || c == 0x5B || c == 0x7B || c == 0x23 // ( [ { #[
    }

    private static func findPairs(text: NSString, tokens: [Token]) -> [NSRange] {
        var stack: [Int] = []
        var pairs: [NSRange] = []
        for token in tokens where token.kind == .bracket {
            if isOpen(text, token) {
                stack.append(token.range.location)
            } else if let open = stack.popLast() {
                pairs.append(NSRange(location: open, length: NSMaxRange(token.range) - open))
            }
        }
        return pairs.sorted { $0.location < $1.location }
    }

    private static func findBlocks(text: NSString, tokens: [Token]) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        var current: CodeBlock?
        var depth = 0
        var t = 0
        var lineStart = 0
        let length = text.length

        while lineStart < length {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let insideBrackets = depth > 0
            var firstCode: Int?
            var hasTokens = false
            while t < tokens.count && tokens[t].range.location < NSMaxRange(line) {
                let token = tokens[t]
                hasTokens = true
                if token.kind != .comment && firstCode == nil { firstCode = token.range.location }
                if token.kind == .bracket { depth = max(0, depth + (isOpen(text, token) ? 1 : -1)) }
                t += 1
            }

            if !hasTokens && !insideBrackets {
                // A blank line (or the inside of a multi-line string, which we don't split).
                if let block = current, !isInsideString(line, tokens: tokens, before: t) {
                    blocks.append(block)
                    current = nil
                } else if current != nil {
                    current!.range = NSUnionRange(current!.range, line)
                }
            } else if current == nil {
                current = CodeBlock(range: line, codeStart: firstCode)
            } else {
                current!.range = NSUnionRange(current!.range, line)
                if current!.codeStart == nil { current!.codeStart = firstCode }
            }
            lineStart = NSMaxRange(line)
        }
        if let block = current { blocks.append(block) }
        return blocks
    }

    private static func isInsideString(_ line: NSRange, tokens: [Token], before t: Int) -> Bool {
        guard t > 0 else { return false }
        let previous = tokens[t - 1]
        return previous.kind == .string && NSMaxRange(previous.range) > line.location
    }

    /// The block containing a location. On a blank line just after a block, that block.
    func block(at location: Int) -> CodeBlock? {
        if let block = blocks.last(where: { $0.range.location <= location }) {
            if location < NSMaxRange(block.range) { return block }
            // Right after the block's last newline, or on the blank line below it.
            if location <= NSMaxRange(block.range) + 1 { return block }
        }
        return nil
    }

    /// The bracket pair whose opening or closing bracket is at a location.
    func pair(withBracketAt location: Int) -> NSRange? {
        pairs.first { $0.location == location || NSMaxRange($0) - 1 == location }
    }

    /// The next larger thing to select around a range: the contents of the innermost enclosing
    /// brackets, then the brackets themselves, then the next pair out, and finally the whole block.
    func expand(_ range: NSRange) -> NSRange? {
        var best: NSRange?
        func consider(_ candidate: NSRange) {
            guard candidate.location <= range.location, NSMaxRange(candidate) >= NSMaxRange(range),
                  candidate.length > range.length else { return }
            if best == nil || candidate.length < best!.length { best = candidate }
        }
        for pair in pairs where pair.location <= range.location && NSMaxRange(pair) >= NSMaxRange(range) {
            consider(NSRange(location: pair.location + 1, length: pair.length - 2)) // inside
            consider(pair)
        }
        if let block = block(at: range.location) {
            consider(trimmed(block.range))
        }
        return best
    }

    /// A block's range without its final newline, which is nicer to select.
    func trimmed(_ range: NSRange) -> NSRange {
        guard range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A else { return range }
        return NSRange(location: range.location, length: range.length - 1)
    }
}
