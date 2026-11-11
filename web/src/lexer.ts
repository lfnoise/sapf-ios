//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Tokenizer for coloring and structure. A port of ios/Sapf/Editor/SapfLexer.swift, which follows the rules in
// src/Parser.cpp. Offsets are UTF-16 code unit indexes, as in JavaScript strings.

export type TokenKind =
  | 'comment'       // ; to end of line
  | 'string'        // "..."  ("" is an escaped quote)
  | 'number'        // 1  -2.5  1e3  4c  24k  9/12  2pi  0xff
  | 'builtIn'       // sinosc
  | 'userWord'      // a word defined with help in the workspace
  | 'word'          // any other word
  | 'symbol'        // 'name  `name
  | 'key'           // :name  .name  ,name
  | 'assign'        // =
  | 'assignTarget'  // the name after =
  | 'lambda'        // \
  | 'lambdaArg'     // the argument names after \
  | 'eachOp'        // @  @@  @1  @01
  | 'bracket';      // ( ) [ ] { } #[

export interface Token {
  from: number;
  to: number;
  kind: TokenKind;
}

// Characters that end a word. Same as `nonnamechars` in Parser.cpp, plus whitespace.
const nonName = new Set(';()[]{}.`,:"\n');
const brackets = new Set('()[]{}');
const symbolPrefixes = new Set("'`");
const keyPrefixes = new Set(':,');
const numberStarts = new Set('0123456789+-.p');

function isSpace(c: string): boolean {
  return c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\v' || c === '\f' || c === ' ';
}

function isDigit(c: string | undefined): boolean {
  return c !== undefined && c >= '0' && c <= '9';
}

function isEndOfWord(c: string): boolean {
  return isSpace(c) || nonName.has(c);
}

export function tokenize(text: string, builtIns: ReadonlySet<string>, userWords: ReadonlySet<string>): Token[] {
  const n = text.length;
  const tokens: Token[] = [];
  let pendingAssign = false; // just saw '='
  let multiAssign = false;   // inside '= (a b c)' or '= [a b c]'
  let lambdaArgs = false;    // between '\' and '['

  const add = (from: number, to: number, kind: TokenKind) => { tokens.push({ from, to, kind }); };
  const wordEnd = (start: number) => {
    let j = start;
    while (j < n && !isEndOfWord(text[j])) j += 1;
    return j;
  };

  let i = 0;
  while (i < n) {
    const c = text[i];

    if (isSpace(c)) { i += 1; continue; }

    if (c === ';') {
      let j = i;
      while (j < n && text[j] !== '\n') j += 1;
      add(i, j, 'comment');
      i = j;
      continue;
    }

    if (c === '"') {
      let j = i + 1;
      while (j < n) {
        if (text[j] === '"') {
          if (j + 1 < n && text[j + 1] === '"') { j += 2; continue; }
          j += 1;
          break;
        }
        j += 1;
      }
      add(i, Math.min(j, n), 'string');
      i = j;
      continue;
    }

    if (brackets.has(c)) {
      add(i, i + 1, 'bracket');
      if (lambdaArgs && c === '[') lambdaArgs = false;
      if (pendingAssign && (c === '(' || c === '[')) {
        multiAssign = true;
        pendingAssign = false;
      } else if (multiAssign && (c === ')' || c === ']')) {
        multiAssign = false;
      }
      i += 1;
      continue;
    }

    if (c === '#' && i + 1 < n && text[i + 1] === '[') {
      add(i, i + 2, 'bracket');
      i += 2;
      continue;
    }

    if (c === '\\') {
      add(i, i + 1, 'lambda');
      lambdaArgs = true;
      i += 1;
      continue;
    }

    if (c === '@') {
      let j = i + 1;
      while (j < n && text[j] === '@') j += 1;
      while (j < n && isDigit(text[j])) j += 1;
      add(i, j, 'eachOp');
      i = j;
      continue;
    }

    if (symbolPrefixes.has(c) || keyPrefixes.has(c)) {
      const j = wordEnd(i + 1);
      add(i, j, symbolPrefixes.has(c) ? 'symbol' : 'key');
      i = j;
      continue;
    }

    if (numberStarts.has(c)) {
      // Numbers may contain '.', so scan with a looser terminator than words.
      let j = i;
      while (j < n && !isSpace(text[j]) && (text[j] === '.' || !nonName.has(text[j]))) j += 1;
      if (isNumber(text.slice(i, j))) {
        add(i, j, 'number');
        i = j;
        continue;
      }
      if (c === '.') {
        const k = wordEnd(i + 1);
        add(i, k, 'key');
        i = k;
        continue;
      }
    }

    let j = wordEnd(i);
    if (j === i) j = i + 1;
    const word = text.slice(i, j);
    let kind: TokenKind;
    if (word === '=') {
      kind = 'assign';
      pendingAssign = true;
    } else if (pendingAssign || multiAssign) {
      kind = 'assignTarget';
      pendingAssign = false;
    } else if (lambdaArgs) {
      kind = 'lambdaArg';
    } else if (builtIns.has(word)) {
      kind = 'builtIn';
    } else if (userWords.has(word)) {
      kind = 'userWord';
    } else {
      kind = 'word';
    }
    add(i, j, kind);
    i = j;
  }
  return tokens;
}

/** Mirrors parseNumber / parseFloat / parseHexNumber in Parser.cpp. */
export function isNumber(s: string): boolean {
  let i = 0;
  const end = s.length;
  const peek = (offset = 0) => (i + offset < end ? s[i + offset] : undefined);

  if (peek() === '0' && peek(1) === 'x') {
    i += 2;
    const start = i;
    for (let c = peek(); c !== undefined && (isDigit(c) || /[a-fA-F]/.test(c)); c = peek()) i += 1;
    return i > start && i === end;
  }

  if (peek() === '+' || peek() === '-') i += 1;

  let digits = 0;
  while (isDigit(peek())) { i += 1; digits += 1; }
  if (peek() === '.') {
    i += 1;
    while (isDigit(peek())) { i += 1; digits += 1; }
  }
  if (digits > 0 && (peek() === 'e' || peek() === 'E')) {
    let k = 1;
    if (peek(k) === '+' || peek(k) === '-') k += 1;
    if (isDigit(peek(k))) {
      i += k;
      while (isDigit(peek())) i += 1;
    }
  }
  if (peek() === 'p' && peek(1) === 'i') {
    i += 2;
    digits += 1;
  }
  if (digits === 0) return false;

  const suffix = peek();
  if (suffix !== undefined && 'Mkhcmu'.includes(suffix)) i += 1;

  if (peek() === '/') {
    i += 1;
    let denomDigits = 0;
    for (let c = peek(); c !== undefined && (isDigit(c) || c === '.'); c = peek()) { i += 1; denomDigits += 1; }
    if (denomDigits === 0) return false;
  }
  return i === end;
}
