//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Bringing sound files in for sf>. The browser decodes whatever it can play (WAV, AIFF, MP3, AAC, FLAC, Ogg, ...)
// at the engine's sample rate, and it's saved as a 32 bit float WAV in the Sounds folder, which sf> looks in.

/** the name a file is saved under, which is what goes in quotes before sf>: without its extension or quotes. */
export function soundName(fileName: string): string {
  const dot = fileName.lastIndexOf('.');
  const base = dot > 0 ? fileName.slice(0, dot) : fileName;
  return base.replace(/["/\\]/g, '_').replace(/[\u0000-\u001f]/g, '').trim() || 'sound';
}

/** a 32 bit float WAV file of the channels. */
export function encodeWav(channels: Float32Array[], sampleRate: number): Uint8Array {
  const numChannels = channels.length;
  const frames = numChannels ? channels[0].length : 0;
  const dataBytes = frames * numChannels * 4;
  const bytes = new Uint8Array(44 + dataBytes);
  const view = new DataView(bytes.buffer);
  const text = (at: number, s: string) => { for (let i = 0; i < s.length; ++i) view.setUint8(at + i, s.charCodeAt(i)); };
  text(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, true);
  text(8, 'WAVE');
  text(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 3, true); // IEEE float
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * numChannels * 4, true);
  view.setUint16(32, numChannels * 4, true);
  view.setUint16(34, 32, true);
  text(36, 'data');
  view.setUint32(40, dataBytes, true);
  const samples = new Float32Array(bytes.buffer, 44, frames * numChannels);
  for (let c = 0; c < numChannels; ++c) {
    const channel = channels[c];
    for (let f = 0; f < frames; ++f) samples[f * numChannels + c] = channel[f];
  }
  return bytes;
}

export interface ImportedSound {
  name: string;
  path: string;
  channels: number;
  seconds: number;
  replaced: boolean;
}

/**
 * Decodes the file with the audio context (so at its sample rate) and writes it into folder as name.wav.
 * Throws if the browser can't decode it.
 */
export async function importSound(file: File, context: BaseAudioContext, folder: string,
                                  write: (path: string, bytes: Uint8Array) => boolean): Promise<ImportedSound> {
  const buffer = await context.decodeAudioData(await file.arrayBuffer());
  const channels: Float32Array[] = [];
  for (let c = 0; c < buffer.numberOfChannels; ++c) channels.push(buffer.getChannelData(c));
  const name = soundName(file.name);
  const path = `${folder}/${name}.wav`;
  const replaced = write(path, encodeWav(channels, Math.round(buffer.sampleRate)));
  return { name, path, channels: buffer.numberOfChannels, seconds: buffer.duration, replaced };
}
