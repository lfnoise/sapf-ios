# sapf for iOS and iPadOS

A native front end for sapf on iPhone and iPad. It compiles the same interpreter sources
as the desktop build (`../src`, `../include`); only the terminal REPL (`main.cpp`) is replaced.

## Building

Open `ios/Sapf.xcodeproj` in Xcode, choose your development team under Signing & Capabilities,
and run. Requires Xcode 15+ and iOS/iPadOS 16+.

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding or removing source files, regenerate it:

    brew install xcodegen
    cd ios && xcodegen

## Using it

- **Tap ▶ in the margin** beside any block to run it. A block is a run of non-blank lines,
  kept together across blank lines inside brackets, so a multi-line `( ... )` or `\[ ... ]` is one block.
  Touch and hold ▶ to select or copy the block instead.
- **Run** (▶ in the toolbar, Cmd-Return) evaluates the selection, or the block around the cursor,
  which is marked with a green bar in the margin. Shift-Return evaluates the current line.
  **Stop** (■, Cmd-.) stops all sounds.
- **Expand Selection** (the selection button on the key bar, Cmd-B) grows the selection to the inside
  of the enclosing brackets, then the brackets, then the next ones out, then the whole block.
  **Double tap a bracket** to select through its match.
- **Tap a word** to see its help: stack effect, automapping mask, and description. User defined
  functions with help strings work too, and tapping a variable shows its value.
  Turn this off with *Help on Tap* in the ⋯ menu.
- **Waveform, Spectrum and Spectrogram** show everything currently playing.
  Drag a finger on any of them to drive `mousex`, `mousey`, `xmousex` and `xmousey`.
- The key bar above the keyboard has Run, Stop and sapf's punctuation.
- Documents live in the app's Documents folder and are visible in the Files app.
  `Prelude.sapf` there is loaded at startup and can be edited; *Restore Original* in the
  title menu brings back the bundled version of the prelude and examples.
- Recordings (`record`, `>sf`) and `sgram` spectrograms are saved in Documents/Recordings and
  Documents/Spectrograms and open in Quick Look.

## Changes to the shared sources

All are no-ops on macOS:

- `post()` can be redirected (`gPostHook`), and `open`-ing files goes through
  `openFileExternally()` (`gOpenFileHook`) since iOS has no `system()`.
- Unnamed recordings and spectrograms go to `$SAPF_TMPDIR`, defaulting to `/tmp`.
- libedit is only used when `USE_LIBEDIT` (off on iOS); Carbon mouse polling is replaced on
  iOS by `setMouseUGenState()`; `makeImage.mm` has a CoreGraphics/ImageIO path for iOS.
- Players use the RemoteIO unit on iOS, and each writes a mono mix into a lock-free ring
  buffer read by `getScopeSamples()` for the displays.

## Tests

`SapfTests` covers block and bracket detection. `SapfUITests` drives the app: tap-for-help, the margin run
buttons, evaluating code and the visualizers, and layouts in both orientations. Run with Cmd-U, or:

    xcodebuild -project ios/Sapf.xcodeproj -scheme Sapf \
      -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' test
