//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

import AVFoundation
import SwiftUI
import UIKit

/// Source files live in the app's Documents folder, which is visible in the Files app.
/// The bundled files are copied there on first launch so they can be edited.
struct DocumentStore {
    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let recordings = directory.appendingPathComponent("Recordings", isDirectory: true)
    static let spectrograms = directory.appendingPathComponent("Spectrograms", isDirectory: true)

    static let scratch = directory.appendingPathComponent("Scratch.sapf")
    static let prelude = directory.appendingPathComponent("Prelude.sapf")

    /// Documents copied from the app bundle, and their original resource names.
    static let bundled: [(URL, String)] = [
        (directory.appendingPathComponent("Examples.sapf"), "sapf-examples"),
        (directory.appendingPathComponent("Builtin Examples.sapf"), "sapf-bif-examples"),
        (prelude, "sapf-prelude"),
    ]

    static func setUp() {
        let fm = FileManager.default
        try? fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        try? fm.createDirectory(at: spectrograms, withIntermediateDirectories: true)
        for (url, resource) in bundled where !fm.fileExists(atPath: url.path) {
            restoreOriginal(url, resource: resource)
        }
        if !fm.fileExists(atPath: scratch.path) {
            let welcome = """
            ; Welcome to sapf.
            ; Put the cursor in a block of code and press Run (or Cmd-Return).
            ; Tap a word to see its help. Stop sounds with the stop button (or Cmd-.).
            ; Drag a finger on the waveform or spectrum to control mousex and mousey.

            440 0 sinosc .2 * play

            (300 1000 xmousex 0 sinosc .2 * play)

            ;; analog bubbles
            ((.4 0 lfsaw) 2 * ([8 7.23] 0 lfsaw) .25 * 9.667 + + exp2) 0 sinosc .04 * .2 0 4 combn play

            """
            try? welcome.write(to: scratch, atomically: true, encoding: .utf8)
        }
    }

    static func restoreOriginal(_ url: URL, resource: String) {
        guard let source = Bundle.main.url(forResource: resource, withExtension: "txt") else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
    }

    static func bundledResource(for url: URL) -> String? {
        bundled.first { $0.0.standardizedFileURL == url.standardizedFileURL }?.1
    }

    /// All editable documents: Scratch first, then the rest alphabetically.
    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let docs = urls.filter { ["sapf", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return [scratch] + docs.filter { $0.lastPathComponent != scratch.lastPathComponent }
    }

    static func newDocumentURL() -> URL {
        var n = 1
        while true {
            let url = directory.appendingPathComponent(n == 1 ? "Untitled.sapf" : "Untitled \(n).sapf")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    static func isInDocuments(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }
}

@MainActor
final class AppModel: ObservableObject, CodeTextViewActions {
    @Published private(set) var documents: [URL] = []
    @Published private(set) var currentDocument: URL = DocumentStore.scratch
    @Published private(set) var isBusy = false
    @Published var previewURL: URL?
    /// The on-screen keyboard's frame in screen coordinates, or nil when it's hidden.
    @Published private(set) var keyboardFrame: CGRect?
    /// Whether the editor brings up the keyboard. When off, taps only show help and pick the block to run.
    @Published var isEditing: Bool {
        didSet { editor.isEditable = isEditing }
    }

    @Published var showsHelpOnTap: Bool {
        didSet {
            editor.showsHelpOnTap = showsHelpOnTap
            UserDefaults.standard.set(showsHelpOnTap, forKey: "helpOnTap")
        }
    }
    @Published var editorFontSize: Double {
        didSet {
            editor.fontSize = editorFontSize
            UserDefaults.standard.set(editorFontSize, forKey: "editorFontSize")
        }
    }
    private var savedDocumentName: String {
        get { UserDefaults.standard.string(forKey: "currentDocument") ?? DocumentStore.scratch.lastPathComponent }
        set { UserDefaults.standard.set(newValue, forKey: "currentDocument") }
    }

    let console = ConsoleBuffer()
    /// One editor for the life of the app, so text, undo and scroll position survive layout changes.
    let editor = CodeTextView()

    private var saveWorkItem: DispatchWorkItem?
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        showsHelpOnTap = defaults.object(forKey: "helpOnTap") as? Bool ?? true
        editorFontSize = defaults.object(forKey: "editorFontSize") as? Double
            ?? (UIDevice.current.userInterfaceIdiom == .pad ? 16 : 14)
        // On a phone the keyboard covers most of the screen, so start out reading.
        isEditing = UIDevice.current.userInterfaceIdiom == .pad

        editor.actions = self
        editor.fontSize = editorFontSize
        editor.showsHelpOnTap = showsHelpOnTap
        editor.isEditable = isEditing

        // The layout makes room for the keyboard itself: SwiftUI's own keyboard avoidance can leave
        // the bottom panel under the accessory bar after rotating.
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            Task { @MainActor in
                withAnimation(.easeOut(duration: duration)) { self?.keyboardFrame = frame }
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            Task { @MainActor in
                withAnimation(.easeOut(duration: duration)) { self?.keyboardFrame = nil }
            }
        }
    }

    /// How far the keyboard reaches above a view's bottom edge, given in window coordinates.
    func keyboardOverlap(bottom: CGFloat) -> CGFloat {
        guard let screenFrame = keyboardFrame, !screenFrame.isEmpty else { return 0 }
        var frame = screenFrame
        if let window = editor.window {
            frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        }
        return max(0, bottom - frame.minY)
    }

    func startEditing() {
        isEditing = true
        editor.becomeFirstResponder()
    }

    func start() {
        guard !started else { return }
        started = true

        DocumentStore.setUp()
        setenv("SAPF_RECORDINGS", DocumentStore.recordings.path, 1)
        setenv("SAPF_SPECTROGRAMS", DocumentStore.spectrograms.path, 1)
        setenv("SAPF_TMPDIR", NSTemporaryDirectory(), 1)
        setenv("SAPF_PRELUDE", DocumentStore.prelude.path, 1)
        if let readme = Bundle.main.path(forResource: "README", ofType: "txt") { setenv("SAPF_README", readme, 1) }
        setenv("SAPF_EXAMPLES", DocumentStore.bundled[0].0.path, 1)
        // Relative paths in sapf code (e.g. for sound files) are relative to Documents.
        FileManager.default.changeCurrentDirectoryPath(DocumentStore.directory.path)

        let sampleRate = configureAudioSession()

        let engine = SapfEngine.shared
        engine.outputHandler = { [weak self] text in self?.console.append(text) }
        engine.busyHandler = { [weak self] busy in
            self?.isBusy = busy
            if !busy { NotificationCenter.default.post(name: .sapfVocabularyChanged, object: nil) }
        }
        engine.openFileHandler = { [weak self] url in self?.open(url) }
        engine.start(withSampleRate: sampleRate, preludePath: DocumentStore.prelude.path)
        // Prelude loading happens on the interpreter queue; this runs after it and picks up its words.
        engine.evaluate("")

        refreshDocuments()
        let saved = DocumentStore.directory.appendingPathComponent(savedDocumentName)
        load(FileManager.default.fileExists(atPath: saved.path) ? saved : DocumentStore.scratch)
    }

    private func configureAudioSession() -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(256.0 / 48000)
            try session.setActive(true)
        } catch {
            console.append("audio session error: \(error.localizedDescription)\n")
        }
        return session.sampleRate > 0 ? session.sampleRate : 48000
    }

    // MARK: Documents

    func refreshDocuments() {
        documents = DocumentStore.list()
    }

    func load(_ url: URL) {
        saveNow()
        let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? ""
        currentDocument = url
        savedDocumentName = url.lastPathComponent
        editor.setText(text)
        refreshDocuments()
    }

    func newDocument() {
        let url = DocumentStore.newDocumentURL()
        try? "".write(to: url, atomically: true, encoding: .utf8)
        load(url)
        // Editable, but not focused: focusing from the Documents menu's action loses out to the menu closing.
        isEditing = true
    }

    var canRestoreCurrent: Bool { DocumentStore.bundledResource(for: currentDocument) != nil }

    func restoreCurrent() {
        guard let resource = DocumentStore.bundledResource(for: currentDocument) else { return }
        saveWorkItem?.cancel()
        DocumentStore.restoreOriginal(currentDocument, resource: resource)
        load(currentDocument)
    }

    func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func saveNow() {
        guard saveWorkItem != nil else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        try? editor.text.write(to: currentDocument, atomically: true, encoding: .utf8)
    }

    /// Called when sapf wants to show a file. Source files open in the editor; anything else in Quick Look.
    func open(_ url: URL) {
        if ["sapf", "txt"].contains(url.pathExtension.lowercased()) && DocumentStore.isInDocuments(url) {
            load(url)
        } else {
            previewURL = url
        }
    }

    // MARK: Evaluation

    func evaluate() {
        editor.evaluate(wholeBlock: true)
    }

    func evaluate(_ code: String) {
        console.echo(code)
        SapfEngine.shared.evaluate(code)
    }

    func stop() {
        SapfEngine.shared.stopAll()
    }

    func clearStack() {
        SapfEngine.shared.clearStack()
        console.append("stack cleared\n")
    }

    func codeTextView(_ view: CodeTextView, evaluate code: String) { evaluate(code) }
    func codeTextViewStop(_ view: CodeTextView) { stop() }
    func codeTextViewDidChangeText(_ view: CodeTextView) { scheduleSave() }
    func codeTextViewDidEndEditing(_ view: CodeTextView) { isEditing = false }
}
