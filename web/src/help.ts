//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Function help: the table behind tap-for-help and highlighting (from parseHelpLine in the iOS SapfEngine.mm),
// and parsing for the All Functions viewer (from FunctionList.swift).

export interface WordHelp {
  name: string;
  mask: string | null;
  help: string;
  builtIn: boolean;
}

/**
 * Help lines look like "name @mask (a b --> c) description" or "name (a --> b) description". Section headers and
 * the legend start with whitespace or are otherwise not a single word.
 */
export function parseHelpLine(line: string, builtIn: boolean): WordHelp | null {
  if (!line || /\s/.test(line[0])) return null;
  const nameEnd = line.indexOf(' ');
  if (nameEnd <= 0) return null;
  const name = line.slice(0, nameEnd);
  if (name.endsWith(':')) return null; // "Argument Automapping legend:"
  let rest = line.slice(nameEnd + 1);
  let mask: string | null = null;
  if (rest.startsWith('@')) {
    const maskEnd = rest.indexOf(' ');
    mask = rest.slice(1, maskEnd < 0 ? undefined : maskEnd);
    rest = maskEnd < 0 ? '' : rest.slice(maskEnd + 1);
  }
  return { name, mask, help: rest, builtIn };
}

/** Built-in and user defined help, by name. Built-in help arrives once; user help only grows. */
export class HelpTable {
  readonly builtInWords = new Set<string>();
  readonly userWords = new Set<string>();
  private table = new Map<string, WordHelp>();
  private bifLines: string[] = [];
  private udfLines: string[] = [];
  /** bumped when the vocabulary changes, so the editor recolors. */
  generation = 0;

  add(builtIn: string[], userDefined: string[]): void {
    for (const line of builtIn) {
      this.bifLines.push(line);
      const h = parseHelpLine(line, true);
      if (!h) continue;
      this.table.set(h.name, h);
      this.builtInWords.add(h.name);
    }
    for (const line of userDefined) {
      this.udfLines.push(line);
      const h = parseHelpLine(line, false);
      if (!h) continue;
      this.table.set(h.name, h);
      this.userWords.add(h.name);
    }
    this.generation += 1;
  }

  get(word: string): WordHelp | undefined {
    return this.table.get(word);
  }

  /** the text for the All Functions viewer. */
  allHelpText(): string {
    return 'BUILT IN FUNCTIONS\n\n' + this.bifLines.map(l => l + '\n').join('') +
      '\nUSER DEFINED FUNCTIONS\n\n' + this.udfLines.map(l => l + '\n').join('');
  }
}

export interface FunctionEntry {
  name: string;
  mask: string | null;
  effect: string | null;
  description: string;
}

/**
 * Splits a help line like "name @mask (a b --> c) description" for the function list. Returns null for headings
 * and the legend, which start with whitespace or end their first word with a colon.
 */
export function functionEntry(line: string): FunctionEntry | null {
  if (!line || /\s/.test(line[0]) || line.endsWith(':')) return null;
  const space = line.indexOf(' ');
  if (space < 0) return null;
  const name = line.slice(0, space);
  if (name.endsWith(':') || name.startsWith('***')) return null;
  let rest = line.slice(space + 1).replace(/^ +/, '');
  let mask: string | null = null;
  if (rest.startsWith('@')) {
    let end = rest.indexOf(' ');
    if (end < 0) end = rest.length;
    mask = rest.slice(1, end);
    rest = rest.slice(end).replace(/^ +/, '');
  }
  let effect: string | null = null;
  if (rest.startsWith('(')) {
    // The stack effect ends at the parenthesis after its arrow; its items can have their own.
    const arrowAt = rest.indexOf('-->');
    const searchFrom = arrowAt < 0 ? 0 : arrowAt + 3;
    const close = rest.indexOf(')', searchFrom);
    if (close >= 0) {
      effect = rest.slice(0, close + 1);
      rest = rest.slice(close + 1).replace(/^ +/, '');
    }
  }
  return { name, mask, effect, description: rest };
}
