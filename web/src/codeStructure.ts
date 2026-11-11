//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Blocks and matching brackets. A port of ios/Sapf/Editor/CodeStructure.swift.
//
// A block is a chunk of code you'd evaluate at once: consecutive non-blank lines, also spanning blank lines that
// fall inside brackets, so a multi-line ( ... ) or \[ ... ] stays in one piece. Worked out from the lexer's
// tokens, so brackets inside comments and strings don't count.

import type { Token } from './lexer.ts';

export interface Range {
  from: number;
  to: number;
}

export interface CodeBlock {
  /** whole lines, including the final newline. */
  range: Range;
  /** where the first code that isn't a comment starts. null for a block of only comments. */
  codeStart: number | null;
}

function isOpen(text: string, token: Token): boolean {
  const c = text[token.from];
  return c === '(' || c === '[' || c === '{' || c === '#'; // ( [ { #[
}

/** the line containing location, including its newline. */
function lineRange(text: string, location: number): Range {
  const from = text.lastIndexOf('\n', location - 1) + 1;
  const nl = text.indexOf('\n', location);
  return { from, to: nl < 0 ? text.length : nl + 1 };
}

const union = (a: Range, b: Range): Range => ({ from: Math.min(a.from, b.from), to: Math.max(a.to, b.to) });

export class CodeStructure {
  readonly blocks: CodeBlock[];
  /** matched bracket pairs, each from the opening bracket through the closing one, sorted by start. */
  readonly pairs: Range[];

  private readonly text: string;
  constructor(text: string, tokens: Token[]) {
    this.text = text;
    this.pairs = CodeStructure.findPairs(text, tokens);
    this.blocks = CodeStructure.findBlocks(text, tokens);
  }

  private static findPairs(text: string, tokens: Token[]): Range[] {
    const stack: number[] = [];
    const pairs: Range[] = [];
    for (const token of tokens) {
      if (token.kind !== 'bracket') continue;
      if (isOpen(text, token)) {
        stack.push(token.from);
      } else {
        const open = stack.pop();
        if (open !== undefined) pairs.push({ from: open, to: token.to });
      }
    }
    return pairs.sort((a, b) => a.from - b.from);
  }

  private static findBlocks(text: string, tokens: Token[]): CodeBlock[] {
    const blocks: CodeBlock[] = [];
    let current: CodeBlock | null = null;
    let depth = 0;
    let t = 0;
    let lineStart = 0;
    const length = text.length;

    while (lineStart < length) {
      const line = lineRange(text, lineStart);
      const insideBrackets = depth > 0;
      let firstCode: number | null = null;
      let hasTokens = false;
      while (t < tokens.length && tokens[t].from < line.to) {
        const token = tokens[t];
        hasTokens = true;
        if (token.kind !== 'comment' && firstCode === null) firstCode = token.from;
        if (token.kind === 'bracket') depth = Math.max(0, depth + (isOpen(text, token) ? 1 : -1));
        t += 1;
      }

      if (!hasTokens && !insideBrackets) {
        // A blank line (or the inside of a multi-line string, which we don't split).
        if (current && !CodeStructure.isInsideString(line, tokens, t)) {
          blocks.push(current);
          current = null;
        } else if (current) {
          current.range = union(current.range, line);
        }
      } else if (!current) {
        current = { range: line, codeStart: firstCode };
      } else {
        current.range = union(current.range, line);
        if (current.codeStart === null) current.codeStart = firstCode;
      }
      lineStart = line.to;
    }
    if (current) blocks.push(current);
    return blocks;
  }

  private static isInsideString(line: Range, tokens: Token[], t: number): boolean {
    if (t <= 0) return false;
    const previous = tokens[t - 1];
    return previous.kind === 'string' && previous.to > line.from;
  }

  /** the block containing a location. On a blank line just after a block, that block. */
  blockAt(location: number): CodeBlock | null {
    let block: CodeBlock | null = null;
    for (const b of this.blocks) if (b.range.from <= location) block = b; else break;
    if (block) {
      if (location < block.range.to) return block;
      // right after the block's last newline, or on the blank line below it.
      if (location <= block.range.to + 1) return block;
    }
    return null;
  }

  /** the bracket pair whose opening or closing bracket is at a location. */
  pairWithBracketAt(location: number): Range | null {
    return this.pairs.find(p => p.from === location || p.to - 1 === location) ?? null;
  }

  /**
   * The next larger thing to select around a range: the contents of the innermost enclosing brackets, then the
   * brackets themselves, then the next pair out, and finally the whole block.
   */
  expand(range: Range): Range | null {
    let best: Range | null = null;
    const len = (r: Range) => r.to - r.from;
    const consider = (candidate: Range) => {
      if (!(candidate.from <= range.from && candidate.to >= range.to && len(candidate) > len(range))) return;
      if (!best || len(candidate) < len(best)) best = candidate;
    };
    for (const pair of this.pairs) {
      if (pair.from <= range.from && pair.to >= range.to) {
        consider({ from: pair.from + 1, to: pair.to - 1 }); // inside
        consider(pair);
      }
    }
    const block = this.blockAt(range.from);
    if (block) consider(this.trimmed(block.range));
    return best;
  }

  /** a block's range without its final newline, which is nicer to select. */
  trimmed(range: Range): Range {
    if (range.to - range.from <= 0 || this.text[range.to - 1] !== '\n') return range;
    return { from: range.from, to: range.to - 1 };
  }
}
