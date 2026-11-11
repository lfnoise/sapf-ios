//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// MIDI input through Web MIDI. The web counterpart of the CoreMIDI code in src/Midi.cpp.
//
// The MIDI words (midiStart, midiList, midiConnectInput, ...) send their requests here (see Midi.hpp). Connected
// sources' messages go to the engine as raw bytes, for the MIDI unit generators (mctl, mgate, mlastkey, ...).
// The output matches the Mac's, so a source is connected the same way: its UID, then the input port, 0 to 15.

export type MidiRequest = 'start' | 'restart' | 'stop' | 'list' | 'connect' | 'disconnect';

/** a source's UID: Web MIDI ids are strings, so a positive 31 bit hash of the id, which stays the same across visits. */
export function midiUID(id: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < id.length; ++i) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0) & 0x7fffffff || 1;
}

export class WebMidi {
  private access: MIDIAccess | null = null;
  private requesting: Promise<MIDIAccess | null> | null = null;
  /** the connections asked for: each source's UID and the input ports it feeds. Kept across unplugging. */
  private connections = new Map<number, Set<number>>();
  /** requests are handled in the order they were made; getting access may wait for the person to allow it. */
  private queue: Promise<void> = Promise.resolve();
  private requestAccess: () => Promise<MIDIAccess>;
  private send: (port: number, data: Uint8Array) => void;
  private print: (text: string) => void;

  /** send passes a source's messages to the engine; print writes to the console. */
  constructor(send: (port: number, data: Uint8Array) => void, print: (text: string) => void,
              requestAccess?: () => Promise<MIDIAccess>) {
    this.send = send;
    this.print = print;
    this.requestAccess = requestAccess ?? (() => navigator.requestMIDIAccess({ sysex: false }));
    this.hasAccessRequest = !!requestAccess;
  }

  private hasAccessRequest: boolean;

  /** whether the browser has Web MIDI. */
  get isSupported(): boolean {
    return this.hasAccessRequest || (typeof navigator !== 'undefined' && typeof navigator.requestMIDIAccess === 'function');
  }

  request(kind: MidiRequest, uid: number, port: number): void {
    this.queue = this.queue.then(() => this.handle(kind, uid, port)).catch(e => {
      this.print(`MIDI error: ${e instanceof Error ? e.message : String(e)}\n`);
    });
  }

  /** resolves when the requests made so far have been handled. */
  get settled(): Promise<void> {
    return this.queue;
  }

  private async handle(kind: MidiRequest, uid: number, port: number): Promise<void> {
    switch (kind) {
      case 'start':
      case 'list':
        if (await this.ensureAccess()) this.list();
        break;
      case 'restart':
        if (await this.ensureAccess()) {
          this.attach();
          this.list();
        }
        break;
      case 'stop':
        this.connections.clear();
        this.attach();
        break;
      case 'connect': {
        if (!(await this.ensureAccess())) break;
        if (!this.sources().some(input => midiUID(input.id) === uid)) {
          this.print(`midiConnectInput : there is no MIDI source with UID ${uid}. midiList lists them.\n`);
          break;
        }
        const ports = this.connections.get(uid) ?? new Set<number>();
        ports.add(port);
        this.connections.set(uid, ports);
        this.attach();
        break;
      }
      case 'disconnect': {
        const ports = this.connections.get(uid);
        ports?.delete(port);
        if (ports && !ports.size) this.connections.delete(uid);
        this.attach();
        break;
      }
    }
  }

  private async ensureAccess(): Promise<MIDIAccess | null> {
    if (this.access) return this.access;
    if (!this.isSupported) {
      this.print('MIDI is not available in this browser. Chrome, Edge, Opera and Firefox have Web MIDI; Safari doesn’t.\n');
      return null;
    }
    this.requesting ??= this.requestAccess().then(access => {
      this.access = access;
      access.addEventListener('statechange', e => this.stateChanged(e as MIDIConnectionEvent));
      this.attach();
      return access;
    }, (e: unknown) => {
      // the person can be asked again next time.
      this.requesting = null;
      const reason = e instanceof Error ? e.message : String(e);
      this.print(`MIDI is not available: ${reason || 'access was not allowed'}. Check the site's MIDI permission in the browser's settings.\n`);
      return null;
    });
    return this.requesting;
  }

  private sources(): MIDIInput[] {
    return this.access ? [...this.access.inputs.values()] : [];
  }

  private destinations(): MIDIOutput[] {
    return this.access ? [...this.access.outputs.values()] : [];
  }

  /** prints the sources and destinations, as the Mac does. */
  private list(): void {
    const sources = this.sources();
    const destinations = this.destinations();
    const line = (kind: string, i: number, port: MIDIPort) => {
      const device = port.manufacturer || port.name || '';
      return `MIDI ${kind} ${String(i).padStart(2)} '${device}', '${port.name ?? ''}' UID: ${midiUID(port.id)}\n`;
    };
    let text = `midi sources ${sources.length} destinations ${destinations.length}\n`;
    sources.forEach((s, i) => { text += line('Source', i, s); });
    destinations.forEach((d, i) => { text += line('Destination', i, d); });
    if (sources.length && !this.connections.size) {
      text += `connect a source to input port 0 with its UID: ${midiUID(sources[0].id)} 0 midiConnectInput\n`;
    }
    this.print(text);
  }

  /** points each source's messages at the input ports it's connected to, and stops listening to the rest. */
  private attach(): void {
    for (const input of this.sources()) {
      const ports = this.connections.get(midiUID(input.id));
      if (ports && ports.size) {
        const targets = [...ports];
        input.onmidimessage = e => {
          if (e.data) for (const port of targets) this.send(port, e.data);
        };
      } else if (input.onmidimessage) {
        input.onmidimessage = null;
        void input.close().catch(() => {});
      }
    }
  }

  private stateChanged(e: MIDIConnectionEvent): void {
    const port = e.port;
    if (!port || port.type !== 'input') return;
    const uid = midiUID(port.id);
    // also fires when a port opens; only say something when a connected source comes and goes.
    if (port.state === 'connected') {
      // a source plugged back in comes back connected.
      this.attach();
      if (this.unplugged.delete(uid)) this.print(`MIDI source '${port.name ?? ''}' is back\n`);
    } else if (this.connections.has(uid) && !this.unplugged.has(uid)) {
      this.unplugged.add(uid);
      this.print(`MIDI source '${port.name ?? ''}' was unplugged\n`);
    }
  }

  private unplugged = new Set<number>();
}
