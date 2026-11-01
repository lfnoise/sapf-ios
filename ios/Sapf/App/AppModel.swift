//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    /// Every block run, with a timestamp line each hour, like ~/sapf-log.txt on the Mac. Not in the
    /// documents list, so it can't be edited while blocks are appended to it.
    static let log = directory.appendingPathComponent("sapf-log.txt")

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
        // By name and folder: URLs for the same file can differ (e.g. /private/var and /var).
        guard isInDocuments(url) else { return nil }
        return bundled.first { $0.0.lastPathComponent == url.lastPathComponent }?.1
    }

    /// Whether a built-in document differs from the copy in the app bundle (or is missing).
    static func isModified(_ url: URL, resource: String) -> Bool {
        guard let source = Bundle.main.url(forResource: resource, withExtension: "txt") else { return false }
        return FileManager.default.contentsEqual(atPath: url.path, andPath: source.path) == false
    }

    /// All editable documents: Scratch first, then the rest alphabetically.
    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let docs = urls.filter {
            ["sapf", "txt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent != log.lastPathComponent
        }
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
        url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }

    /// The README as the `readme` command shows it in the app. Written to Caches on each launch.
    static let readme = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("README.txt")

    static func writeReadme() {
        guard let source = Bundle.main.url(forResource: "README", withExtension: "txt"),
              let text = try? String(contentsOf: source, encoding: .utf8) else { return }
        try? appReadme(from: text).write(to: readme, atomically: true, encoding: .utf8)
    }

    /// The README for reading on a phone: without the sections about installing and running the
    /// command line program, and with its paragraphs reflowed so they wrap to the screen.
    static func appReadme(from text: String) -> String {
        reflow(withoutCommandLineSections(text))
    }

    /// Leaves out QUICK SET-UP up to BUILT IN FUNCTION HELP. Returns the text unchanged if they're not found.
    static func withoutCommandLineSections(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let heading = { (name: String) in lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == name } }
        guard let start = heading("QUICK SET-UP"), let end = heading("BUILT IN FUNCTION HELP"), start < end else {
            return text
        }
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    /// Joins lines that were broken only to fit 80 columns. A line is joined onto the one before when
    /// both are prose at the same shallow indent and the one before is nearly full and doesn't end a
    /// sentence. Deeper indents and lines with `-->` or starting with `;` are code examples and are
    /// left alone.
    static func reflow(_ text: String) -> String {
        func indent(_ line: Substring) -> Substring { line.prefix { $0 == " " || $0 == "\t" } }
        func columns(_ s: Substring) -> Int { s.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }
        func isProse(_ line: Substring) -> Bool {
            let body = line.drop { $0 == " " || $0 == "\t" }
            return !body.isEmpty && columns(indent(line)) <= 4 && !body.hasPrefix(";") && !line.contains("-->")
        }

        // A line that ends a sentence may be a list item, so the next line starts a new one.
        func endsSentence(_ line: Substring) -> Bool {
            guard let last = line.trimmingTrailingSpaces.last else { return false }
            return ".:?!".contains(last)
        }

        var out: [String] = []
        var previous: Substring?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let p = previous, isProse(p), isProse(line), indent(p) == indent(line),
               columns(p.trimmingTrailingSpaces) >= 60, !endsSentence(p) {
                // Measure each original line, not the joined result, so a paragraph's short last
                // line still ends it.
                out[out.count - 1] = out[out.count - 1].trimmingTrailingSpaces + " " + line.drop { $0 == " " || $0 == "\t" }
            } else {
                out.append(String(line))
            }
            previous = line
        }
        return out.joined(separator: "\n")
    }
}

@MainActor
final class AppModel: ObservableObject, CodeTextViewActions {
    @Published private(set) var documents: [URL] = []
    @Published private(set) var currentDocument: URL = DocumentStore.scratch
    @Published private(set) var isBusy = false
    @Published var previewURL: URL?
    /// Counts plots made, so views can react to a new one.
    @Published private(set) var plotCount = 0
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
    /// Frames per audio callback. sapf computes sound in the callback, so a bigger buffer rides out
    /// busy moments on the main thread (like the keyboard animating) without glitching.
    @Published var audioBufferFrames: Int {
        didSet {
            UserDefaults.standard.set(audioBufferFrames, forKey: "audioBufferFrames")
            applyAudioBufferSize()
        }
    }
    static let audioBufferChoices = [256, 512, 1024, 2048]

    enum UIMode: String, CaseIterable, Identifiable {
        case auto = "Auto", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var style: UIUserInterfaceStyle {
            switch self {
            case .auto: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }
    /// Light or dark, or following the system.
    @Published var uiMode: UIMode {
        didSet {
            UserDefaults.standard.set(uiMode.rawValue, forKey: "uiMode")
            applyUIMode()
        }
    }

    /// Set on the windows rather than with SwiftUI's preferredColorScheme, so the UIKit editor and
    /// console, Quick Look, and going back to Auto all work.
    func applyUIMode() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = uiMode.style }
        }
    }

    /// Where you were in each document, by file name, kept across launches.
    private var positions: [String: CodeTextView.Position] = {
        guard let data = UserDefaults.standard.data(forKey: "documentPositions") else { return [:] }
        return (try? JSONDecoder().decode([String: CodeTextView.Position].self, from: data)) ?? [:]
    }()
    /// The document in the editor, once one has been loaded.
    private var loadedDocument: URL?

    private var savedDocumentName: String {
        get { UserDefaults.standard.string(forKey: "currentDocument") ?? DocumentStore.scratch.lastPathComponent }
        set { UserDefaults.standard.set(newValue, forKey: "currentDocument") }
    }

    let console = ConsoleBuffer()
    /// One editor for the life of the app, so text, undo and scroll position survive layout changes.
    let editor = CodeTextView()

    private var saveWorkItem: DispatchWorkItem?
    /// An interruption (a call, an alarm, Siri) stopped the sound and it hasn't been restarted yet.
    private var resumeAfterInterruption = false
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        showsHelpOnTap = defaults.object(forKey: "helpOnTap") as? Bool ?? true
        editorFontSize = defaults.object(forKey: "editorFontSize") as? Double
            ?? (UIDevice.current.userInterfaceIdiom == .pad ? 16 : 14)
        audioBufferFrames = defaults.object(forKey: "audioBufferFrames") as? Int ?? 1024
        uiMode = defaults.string(forKey: "uiMode").flatMap(UIMode.init) ?? .auto
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

    /// Back to reading: hides the keyboard, and taps no longer bring it back.
    func stopEditing() {
        editor.resignFirstResponder()
        isEditing = false
    }

    func start() {
        guard !started else { return }
        started = true
        applyUIMode()

        DocumentStore.setUp()
        setenv("SAPF_RECORDINGS", DocumentStore.recordings.path, 1)
        setenv("SAPF_SPECTROGRAMS", DocumentStore.spectrograms.path, 1)
        setenv("SAPF_TMPDIR", NSTemporaryDirectory(), 1)
        setenv("SAPF_PRELUDE", DocumentStore.prelude.path, 1)
        setenv("SAPF_LOG", DocumentStore.log.path, 1)
        DocumentStore.writeReadme()
        setenv("SAPF_README", DocumentStore.readme.path, 1)
        setenv("SAPF_EXAMPLES", DocumentStore.bundled[0].0.path, 1)
        // Relative paths in sapf code (e.g. for sound files) are relative to Documents.
        FileManager.default.changeCurrentDirectoryPath(DocumentStore.directory.path)

        let sampleRate = configureAudioSession()
        observeAudioSession()

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

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self?.audioInterruption(type, shouldResume: options.contains(.shouldResume)) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioServicesWereReset() }
        }
    }

    private func audioInterruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            // iOS has already stopped the output units. The sounds keep their place.
            resumeAfterInterruption = true
            console.append("audio interrupted\n")
        case .ended:
            // Without shouldResume, iOS asks that we wait until the user comes back to the app.
            if shouldResume { resumeAudioIfInterrupted() }
        default:
            break
        }
    }

    /// Restarts sound stopped by an interruption. Also called whenever the app becomes active.
    func resumeAudioIfInterrupted() {
        guard resumeAfterInterruption else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Something else still has the audio hardware; try again next time.
            return
        }
        resumeAfterInterruption = false
        SapfEngine.shared.resumeAll()
        console.append("audio resumed\n")
    }

    /// The media server crashed and restarted, so every audio unit is gone.
    private func audioServicesWereReset() {
        resumeAfterInterruption = false
        SapfEngine.shared.stopAll()
        _ = configureAudioSession()
        console.append("audio system was reset; sounds stopped\n")
    }

    private func configureAudioSession() -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
        } catch {
            console.append("audio session error: \(error.localizedDescription)\n")
        }
        applyAudioBufferSize()
        return session.sampleRate > 0 ? session.sampleRate : 48000
    }

    private func applyAudioBufferSize() {
        let session = AVAudioSession.sharedInstance()
        let rate = session.sampleRate > 0 ? session.sampleRate : 48000
        try? session.setPreferredIOBufferDuration(Double(audioBufferFrames) / rate)
    }

    // MARK: Documents

    func refreshDocuments() {
        documents = DocumentStore.list()
        checkBuiltIns()
    }

    func load(_ url: URL) {
        saveNow()
        rememberPosition()
        let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? ""
        currentDocument = url
        savedDocumentName = url.lastPathComponent
        editor.setText(text)
        loadedDocument = url
        if let position = positions[url.lastPathComponent] { editor.restore(position) }
        refreshDocuments()
    }

    /// Notes where you are in the current document, to return there next time it's opened.
    func rememberPosition() {
        guard let url = loadedDocument else { return }
        positions[url.lastPathComponent] = editor.position
        if let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: "documentPositions")
        }
    }

    func newDocument() {
        let url = DocumentStore.newDocumentURL()
        try? "".write(to: url, atomically: true, encoding: .utf8)
        load(url)
        // Editable, but not focused: focusing from the Documents menu's action loses out to the menu closing.
        isEditing = true
    }

    /// Built-in documents that have been changed from the originals in the app bundle.
    @Published private(set) var modifiedBuiltIns: [URL] = []

    func checkBuiltIns() {
        modifiedBuiltIns = DocumentStore.bundled.filter { DocumentStore.isModified($0.0, resource: $0.1) }.map(\.0)
    }

    var canRevertCurrent: Bool { modifiedBuiltIns.contains { isCurrent($0) } }

    /// By name: URLs for the same file can differ (e.g. /private/var and /var).
    private func isCurrent(_ url: URL) -> Bool { url.lastPathComponent == currentDocument.lastPathComponent }

    /// Puts a built-in document back the way it came with the app. Edits to it are lost.
    func revertToOriginal(_ url: URL) {
        guard let resource = DocumentStore.bundledResource(for: url) else { return }
        let current = isCurrent(url)
        if current {
            // Drop any unsaved edits, or loading would save them over the original.
            saveWorkItem?.cancel()
            saveWorkItem = nil
        }
        DocumentStore.restoreOriginal(url, resource: resource)
        if current { load(currentDocument) }
        if url.lastPathComponent == DocumentStore.prelude.lastPathComponent {
            console.append("Prelude.sapf reverted. It's loaded when sapf starts, so the change takes effect next launch.\n")
        }
        checkBuiltIns()
    }

    func revertAllBuiltIns() {
        for url in modifiedBuiltIns { revertToOriginal(url) }
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
        if DocumentStore.bundledResource(for: currentDocument) != nil { checkBuiltIns() }
    }

    /// The help text for the All Functions viewer while it's showing. Read afresh each time, since
    /// user defined functions can be added at any time.
    @Published var functionListText: String?

    func showAllFunctions() {
        functionListText = SapfEngine.shared.allHelpText()
    }

    /// Shows the log of everything run, read-only.
    func showLog() {
        if !FileManager.default.fileExists(atPath: DocumentStore.log.path) {
            FileManager.default.createFile(atPath: DocumentStore.log.path, contents: Data())
        }
        previewURL = DocumentStore.log
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

    /// Plots up to a minute of the value on top of the stack in the waveform views.
    func plotTopOfStack() {
        SapfEngine.shared.plotTopOfStack(withMaxSeconds: 60) { [weak self] plot, message in
            guard let self else { return }
            guard let plot else {
                self.console.append("plot: \(message)\n")
                return
            }
            let shown = Plot(plot)
            WaveformState.shared.show(shown)
            self.plotCount += 1
            self.console.append("plot: \(shown.summary)\n")
        }
    }

    func clearStack() {
        SapfEngine.shared.clearStack()
        console.append("stack cleared\n")
    }

    func codeTextView(_ view: CodeTextView, evaluate code: String) { evaluate(code) }
    func codeTextViewStop(_ view: CodeTextView) { stop() }
    func codeTextViewDidChangeText(_ view: CodeTextView) { scheduleSave() }
    func codeTextViewDidEndEditing(_ view: CodeTextView) { isEditing = false }
    func codeTextViewPlot(_ view: CodeTextView) { plotTopOfStack() }
}

private extension StringProtocol {
    var trimmingTrailingSpaces: SubSequence {
        var s = self[...]
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return s
    }
}
