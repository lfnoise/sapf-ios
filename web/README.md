# sapf for the web

sapf in a web browser, with the same layout and features as the iPhone and iPad app (`../ios`). It runs the same interpreter sources (`../src`, `../include`), compiled to WebAssembly. Only the terminal REPL (`main.cpp`) is replaced.

## Using it

Most of this matches [the iOS app](../ios/README.md).

- **Run a block.** Click **▶ in the margin** beside any block to run it. A block is a run of non-blank lines, kept together across blank lines inside brackets. Right-click ▶ (or touch and hold it) to select or copy the block.
- **Run and Stop.**
  - **Run** (▶ in the toolbar, ⌘↩ / Ctrl+Enter) evaluates the selection, or the block around the cursor, which is marked with a green bar in the margin.
  - Shift+Enter evaluates the current line.
  - **Stop** (■, ⌘. / Ctrl+.) stops all sounds.
- **Selecting code.**
  - **Expand Selection** (⌘B / Ctrl+B) grows the selection to the inside of the enclosing brackets, then the brackets, then the next ones out, then the whole block.
  - **Double-click a bracket** to select through its match.
- **Click a word** to see its help: stack effect, automapping mask and description. Clicking a variable shows its value. Turn this off with *Help on Tap* in the ⋯ menu.
- **The output panel** holds the **Console** and three views: **Waveform**, **Spectrum** and **Spectrogram**.
  - On a wide window they sit beside the editor.
  - Otherwise they sit below it, with a divider you can drag.
  - Small spaces get tabs instead.
- **Drag on a view** to control `mousex` and `mousey`.
- **The waveform:**
  - The scroll wheel, a pinch, or a trackpad pinch zooms from milliseconds to 30 seconds. Double-click resets the zoom.
  - **Plot Top of Stack** (⇧⌘P / Shift+Ctrl+P) draws the value on top of the stack. Switch between Output and Plot at the top of the view, and close the plot with ✕.
- **The Guide** (the book button, or the ⋯ menu) explains the idea behind sapf, the app and the language, with examples you can run from it. It covers the editor, leaving the console and scopes in view, and links to List All Functions and the example documents. It opens by itself on the first visit. It is `../sapf-guide.html`, shared with the iOS app.
- **Documents.** The title and the folder button open the Documents menu, where you can:
  - make a **New Document**;
  - see the **Log** of everything you've run;
  - **Revert** changed built-in files;
  - switch documents.

  Documents are saved as you type. The editor remembers where you were in each one.
- **⋯ menu.** It has:
  - Bigger / Smaller Text;
  - UI Mode (Auto, Light, Dark);
  - the audio buffer size;
  - Find;
  - the Guide and the README;
  - List All Functions (with Find);
  - Clear Stack and Clear Console;
  - **Run All Examples**, which runs every example block and the unit tests and writes `example-report.txt`.
- **Phones and tablets.** On a touch screen the app starts in reading mode on a phone: taps show help and pick the block to run, without bringing up the keyboard. The keyboard button switches to editing, where a key bar above the keyboard has the commands and the symbols sapf uses.
- **Sound files.** `record`, `>sf`, `>sfo` and `sgram` write to the Recordings and Spectrograms folders and show what they made, with Download.
- **Offline.** After the first visit the app works without a network, and it can be installed as an app.

Your documents are kept in the browser (IndexedDB), per site.

## Building

You need Node 22.18 or later and [Emscripten](https://emscripten.org/docs/getting_started/downloads.html) (tested with 7.0.0). The engine build looks for `emcmake` on the PATH, or for an emsdk checkout at `$EMSDK` (default `~/emsdk`).

```sh
cd web
npm install
npm run engine    # compile the interpreter to WebAssembly into public/engine
npm run dev       # http://localhost:5173
```

`npm run build` writes the site to `dist/`. Set `SAPF_BASE=/some/path/` to serve it from a subdirectory. From the repository root, `make web` does all of this.

## Testing

```sh
npm test                          # unit tests: lexer, blocks, help parsing, README reflow (cases from ../ios/SapfTests)
npm run test:browser              # end-to-end tests in headless Chrome against the dev server
npm run build && node scripts/browser-test.mjs --prod       # the same against dist/, plus offline use
node scripts/browser-test.mjs --prod --examples             # also run every example (several minutes)
```

The browser tests need Chrome or Chromium; set `CHROME_PATH` if it isn't in a standard place.

From the repository root, `make test` builds the macOS program twice, once with Apple's frameworks and once with the portable code the web version uses. It runs the unit tests through both, and checks the portable vector math and FFT against Accelerate.

## Deploying

`../.github/workflows/web.yml` builds and tests on every push and pull request. On `main` it publishes `dist/` to GitHub Pages, but only once Pages is enabled for the repository with GitHub Actions as the source.

Any static host works. The page must be **cross-origin isolated**, because the interpreter shares memory between threads (SharedArrayBuffer). `public/sw.js` handles this by adding the `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers itself, so hosts that can't set headers are fine. On the first visit the page reloads once while the service worker installs.

## How it works

| Piece | Where | Notes |
|---|---|---|
| Interpreter | `../src`, `../include` | `include/Platform.hpp` selects the platform code. Off Apple platforms: Accelerate becomes `include/PortableAccel.hpp`; ExtAudioFile becomes `dr_wav`; the JPEG writer becomes `stb_image_write` (both in `../third_party`); CoreMIDI is left out. |
| Bridge | `engine/sapf_web.cpp` | The counterpart of `ios/Sapf/Engine/SapfEngine.mm`, and it behaves the same way. |
| Engine wrapper | `src/engine.ts` | TypeScript wrapper over the bridge. |
| UI | `src/*.ts` | Ports of the iOS views: `lexer.ts` (SapfLexer), `codeStructure.ts` (CodeStructure), `editor.ts` (CodeTextView), `analyzer.ts` (AudioAnalyzer), `scopes.ts` (ScopeViews, WaveformView), `console.ts` (ConsoleView), `documents.ts` (DocumentStore), `help.ts` and `functionList.ts` (FunctionList). `main.ts` is ContentView and AppModel. |

There are four threads:

1. **Page:** the UI. It never waits for the interpreter.
2. **Interpreter thread:** evaluates, plots and describes words, one request at a time.
3. **AudioWorklet:** mixes every playing sound through `renderSharedMix()` in `Play.cpp`, feeding the same per-player scope taps the iOS views read.
4. **Player watchdog:** removes finished sounds and writes recordings.

Stop acts immediately from the page, even during a long evaluation. So do dragging on the views and reading the scope.

## Differences from the iOS app

- **Shortcuts:** ⌘+ / ⌘− zoom the page, as browsers do. Text size is in the ⋯ menu.
- **Audio buffer:** browsers choose their own audio buffer. The Audio Buffer setting asks for a latency to match, and takes effect when the page is reloaded. The sample rate is the browser's.
- **Load readout:** the browser's audio thread has only a millisecond clock. So the load readout is measured over windows of about 170 ms, and **dropouts are not detected** (the count stays at 0).
- **Audio interruptions:** if the browser suspends audio while the page is hidden, sounds pick up where they were when you come back.
- **Keeping code warm:** there is nothing to keep warm.
- **Sound files:** `sf>` reads WAV and AIFF files from the documents folder, without sample-rate conversion. A file at a different rate plays at the wrong speed, with a warning. There's no way yet to bring your own sound files in.
- **MIDI:** the MIDI words exist, but no devices are connected. `midiStart` says so. The bridge has an entry point for incoming MIDI bytes (`sapf_midi_input`) for Web MIDI later.
- **Long evaluations:** as on iOS, a long-running evaluation can't be cancelled. Stop silences it and the page stays responsive, but later evaluations wait for it to finish, or for a reload.
- **Previews and sharing:** Quick Look becomes an in-page preview, and sharing becomes Download (or the system share sheet, for All Functions).
