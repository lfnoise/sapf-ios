//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Web MIDI requests, and the sound file importer's naming and WAV encoding.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebMidi, midiUID } from '../src/midi.ts';
import { soundName, encodeWav } from '../src/soundImport.ts';

test('sound names leave out the extension and characters that would break the sf> string', () => {
  assert.equal(soundName('drum loop.aiff'), 'drum loop');
  assert.equal(soundName('say "hi".wav'), 'say _hi_');
  assert.equal(soundName('a/b\\c.mp3'), 'a_b_c');
  assert.equal(soundName('.wav'), '.wav');
  assert.equal(soundName('   .mp3'), 'sound');
});

test('encodeWav writes a 32 bit float WAV, interleaved', () => {
  const bytes = encodeWav([new Float32Array([0.5, -1]), new Float32Array([0.25, 1])], 44100);
  const v = new DataView(bytes.buffer);
  const text = (at: number) => String.fromCharCode(...bytes.subarray(at, at + 4));
  assert.equal(text(0), 'RIFF');
  assert.equal(text(8), 'WAVE');
  assert.equal(v.getUint16(20, true), 3);
  assert.equal(v.getUint16(22, true), 2);
  assert.equal(v.getUint32(24, true), 44100);
  assert.equal(v.getUint32(40, true), 16);
  assert.deepEqual([...new Float32Array(bytes.buffer, 44, 4)], [0.5, 0.25, -1, 1]);
});

test('MIDI UIDs are positive, stable, and differ between ids', () => {
  const a = midiUID('input-1');
  assert.ok(a > 0 && a <= 0x7fffffff);
  assert.equal(midiUID('input-1'), a);
  assert.notEqual(midiUID('input-2'), a);
});

function fakeAccess() {
  const input = { id: 'k', name: 'Keys', manufacturer: 'Maker', type: 'input', state: 'connected',
    onmidimessage: null as null | ((e: { data: Uint8Array }) => void), close: async () => {} };
  const access = { inputs: new Map([['k', input]]), outputs: new Map(), addEventListener() {} };
  return { input, access: access as unknown as MIDIAccess };
}

test('WebMidi lists, connects, forwards to the input ports, and disconnects', async () => {
  const { input, access } = fakeAccess();
  const sent: [number, number[]][] = [];
  let printed = '';
  let asked = 0;
  const midi = new WebMidi((port, data) => sent.push([port, [...data]]), t => { printed += t; },
    async () => { ++asked; return access; });
  const uid = midiUID('k');
  midi.request('list', 0, 0);
  midi.request('connect', uid, 2);
  midi.request('connect', uid, 5);
  await midi.settled;
  assert.equal(asked, 1);
  assert.match(printed, new RegExp(`MIDI Source  0 'Maker', 'Keys' UID: ${uid}`));
  input.onmidimessage!({ data: new Uint8Array([0x90, 60, 1]) });
  assert.deepEqual(sent, [[2, [0x90, 60, 1]], [5, [0x90, 60, 1]]]);

  midi.request('connect', 99, 0);
  await midi.settled;
  assert.match(printed, /no MIDI source with UID 99/);

  midi.request('disconnect', uid, 2);
  midi.request('disconnect', uid, 5);
  await midi.settled;
  assert.equal(input.onmidimessage, null);
});

test('WebMidi says so when access is refused, and asks again next time', async () => {
  let printed = '';
  let asked = 0;
  const midi = new WebMidi(() => {}, t => { printed += t; }, async () => { ++asked; throw new Error('denied'); });
  midi.request('start', 0, 0);
  await midi.settled;
  midi.request('start', 0, 0);
  await midi.settled;
  assert.match(printed, /MIDI is not available: denied/);
  assert.equal(asked, 2);
});
