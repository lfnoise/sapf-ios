//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The same cases as ios/SapfTests/FunctionListTests.swift and ReadmeTests.swift, plus the help table.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { functionEntry, parseHelpLine, HelpTable } from '../src/help.ts';
import { appReadme, reflow } from '../src/documents.ts';

test('entry with mask and effect', () => {
  assert.deepEqual(functionEntry('sinosc @kk (freq phase --> out) a sine wave oscillator.'),
    { name: 'sinosc', mask: 'kk', effect: '(freq phase --> out)', description: 'a sine wave oscillator.' });
});

test('effect with parentheses inside', () => {
  assert.equal(functionEntry('do (list \\item[..] -->) applies the function (once) to each item.')?.effect, '(list \\item[..] -->)');
});

test('names can start with a star', () => {
  assert.equal(functionEntry('*+ @zzz (a b c --> out) multiply add. a b * c +')?.name, '*+');
});

test('headings and the legend are not entries', () => {
  assert.equal(functionEntry('*** stack ops ***'), null);
  assert.equal(functionEntry('Argument Automapping legend:'), null);
  assert.equal(functionEntry('   a - as is. argument is not automapped.'), null);
});

test('help lines for tap-for-help', () => {
  assert.deepEqual(parseHelpLine('sinosc @zz (freq phase --> out) sine wave oscillator.', true),
    { name: 'sinosc', mask: 'zz', help: '(freq phase --> out) sine wave oscillator.', builtIn: true });
  assert.deepEqual(parseHelpLine('dup (a --> a a) duplicate.', true), { name: 'dup', mask: null, help: '(a --> a a) duplicate.', builtIn: true });
  assert.equal(parseHelpLine('   a - as is.', true), null);
  const table = new HelpTable();
  table.add(['sinosc @zz (freq phase --> out) sine.'], ['f (x --> y) mine.']);
  assert.ok(table.builtInWords.has('sinosc'));
  assert.ok(table.userWords.has('f'));
  assert.equal(table.get('f')?.builtIn, false);
  assert.match(table.allHelpText(), /^BUILT IN FUNCTIONS\n\nsinosc[^\n]*\n\nUSER DEFINED FUNCTIONS\n\nf /);
});

test('the app README leaves out the command line sections', () => {
  const text = readFileSync(new URL('../../README.txt', import.meta.url), 'utf8');
  const readme = appReadme(text);
  for (const gone of ['QUICK SET-UP', 'IPHONE AND IPAD', 'COMMAND LINE', 'ENVIRONMENT VARIABLES', 'xattr']) assert.ok(!readme.includes(gone), gone);
  for (const kept of ['WHAT', 'WHY', 'BUILT IN FUNCTION HELP', 'AUTO-MAPPING', 'REFERENCES']) assert.ok(readme.includes(kept), kept);
});

test('the app README is unchanged without the headings', () => {
  assert.equal(appReadme('WHAT\nsomething\n'), 'WHAT\nsomething\n');
});

test('reflow joins wrapped prose', () => {
  const text = '    Expressions are sequences of words (or other syntactic elements) written\n    in postfix form, and run from left to right.';
  assert.equal(reflow(text), '    Expressions are sequences of words (or other syntactic elements) written in postfix form, and run from left to right.');
});

test('reflow keeps list items and code', () => {
  const text = [
    '    Functions are applied from left to right instead of inside out.',
    '    Support for multiple return values comes for free.',
    '',
    '        [1 2] @ [10 20] +  -->  [[11 21] [12 22]] and a long line of code here',
    '        [1 2] [10 20] @ +  -->  [[11 12] [21 22]]',
    '    { :a 1 :b 2 } = x    ; the value 1 is bound to the key a, and the value 2 is',
    '                         ; bound to the key b.',
  ].join('\n');
  assert.equal(reflow(text), text);
});
