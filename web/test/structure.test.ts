//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The same cases as ios/SapfTests/CodeStructureTests.swift, plus lexer checks.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { tokenize, isNumber } from '../src/lexer.ts';
import { CodeStructure, type Range } from '../src/codeStructure.ts';

const structure = (code: string) => new CodeStructure(code, tokenize(code, new Set(), new Set()));
const sub = (text: string, r: Range | null) => (r ? text.slice(r.from, r.to) : null);
const blockTexts = (code: string) => {
  const s = structure(code);
  return s.blocks.map(b => sub(code, s.trimmed(b.range)));
};

test('blank lines separate blocks', () => {
  assert.deepEqual(blockTexts('1 2 +\n3 4 +\n\n440 0 sinosc\n'), ['1 2 +\n3 4 +', '440 0 sinosc']);
});

test('blank lines inside brackets do not split a block', () => {
  const code = '\\[\n\t4 = a\n\n\ta 2 *\n] play\n\nnext';
  assert.deepEqual(blockTexts(code), ['\\[\n\t4 = a\n\n\ta 2 *\n] play', 'next']);
});

test('brackets in comments and strings are ignored', () => {
  assert.deepEqual(blockTexts('1 ; (\n\n"[" 2\n\n3'), ['1 ; (', '"[" 2', '3']);
});

test('a comment-only block is not runnable', () => {
  const s = structure(';; title\n\n;; heading\n1 2 +\n');
  assert.equal(s.blocks.length, 2);
  assert.equal(s.blocks[0].codeStart, null);
  assert.equal(s.blocks[1].codeStart, 21);
});

test('the block at the cursor includes the blank line below', () => {
  const text = '1 2 +\n\n3 4 +\n';
  const s = structure(text);
  assert.equal(sub(text, s.blockAt(6)?.range ?? null), '1 2 +\n');
  assert.equal(sub(text, s.blockAt(9)?.range ?? null), '3 4 +\n');
});

test('matching brackets', () => {
  const text = '(1 [2 3] +)';
  const s = structure(text);
  assert.equal(sub(text, s.pairWithBracketAt(0)), '(1 [2 3] +)');
  assert.equal(sub(text, s.pairWithBracketAt(7)), '[2 3]');
  assert.equal(s.pairWithBracketAt(1), null);
});

test('expand selection', () => {
  const text = 'x (1 [2 3] +) play\ny\n\nz';
  const s = structure(text);
  let r: Range = { from: 6, to: 6 }; // between 2 and space
  const steps: string[] = [];
  for (let next = s.expand(r); next; next = s.expand(r)) {
    steps.push(text.slice(next.from, next.to));
    r = next;
  }
  assert.deepEqual(steps, ['2 3', '[2 3]', '1 [2 3] +', '(1 [2 3] +)', 'x (1 [2 3] +) play\ny']);
});

test('examples file: many blocks, and no bracket pair crosses a block boundary', () => {
  const text = readFileSync(new URL('../../sapf-examples.txt', import.meta.url), 'utf8');
  const s = structure(text);
  assert.ok(s.blocks.length > 100);
  for (const block of s.blocks) {
    if (block.codeStart === null) continue;
    for (const pair of s.pairs) {
      const overlaps = pair.from < block.range.to && pair.to > block.range.from;
      if (overlaps) assert.ok(pair.from >= block.range.from && pair.to <= block.range.to, `pair crosses a block: ${text.slice(block.range.from, block.range.to)}`);
    }
  }
});

test('numbers follow the parser', () => {
  for (const n of ['1', '-2.5', '1e3', '4c', '24k', '9/12', '2pi', '0xff', '.5', '+.25', 'pi']) assert.ok(isNumber(n), n);
  for (const n of ['x', '-', '.', '1x', '9/', 'e3', '0x']) assert.ok(!isNumber(n), n);
});

test('token kinds', () => {
  const text = "\\a b [a b +] = f  'sym :key .k \"s \"\" t\" @ @@1 #[1] ; c\n= (x y)";
  const kinds = tokenize(text, new Set(['sinosc']), new Set(['f'])).map(t => [text.slice(t.from, t.to), t.kind]);
  assert.deepEqual(kinds, [
    ['\\', 'lambda'], ['a', 'lambdaArg'], ['b', 'lambdaArg'], ['[', 'bracket'], ['a', 'word'], ['b', 'word'], ['+', 'word'], [']', 'bracket'],
    ['=', 'assign'], ['f', 'assignTarget'], ["'sym", 'symbol'], [':key', 'key'], ['.k', 'key'], ['"s "" t"', 'string'],
    ['@', 'eachOp'], ['@@1', 'eachOp'], ['#[', 'bracket'], ['1', 'number'], [']', 'bracket'], ['; c', 'comment'],
    ['=', 'assign'], ['(', 'bracket'], ['x', 'assignTarget'], ['y', 'assignTarget'], [')', 'bracket'],
  ]);
  assert.equal(tokenize('sinosc f g', new Set(['sinosc']), new Set(['f']))[1].kind, 'userWord');
  assert.equal(tokenize('sinosc', new Set(['sinosc']), new Set())[0].kind, 'builtIn');
});
