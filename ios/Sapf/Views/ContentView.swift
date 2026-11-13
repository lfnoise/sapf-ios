//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import QuickLook
import SwiftUI

struct EditorView: UIViewRepresentable {
    let editor: CodeTextView
    func makeUIView(context: Context) -> CodeTextView { editor }
    func updateUIView(_ uiView: CodeTextView, context: Context) {}
}

/// Run, Stop and the other key bar commands, under the editor while reading.
struct ReadingBar: UIViewRepresentable {
    let editor: CodeTextView
    func makeUIView(context: Context) -> UIView { editor.makeReadingBar() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

enum PanelTab: String, CaseIterable, Identifiable {
    case console = "Console"
    case waveform = "Scope"
    case spectrum = "Spectrum"
    case spectrogram = "Sonogram"
    var id: String { rawValue }
}

/// One of the console or the visualizers at a time, with a segmented control to choose. For small spaces.
struct TabbedPanel: View {
    let console: ConsoleBuffer
    /// Changes when a new plot is made, to bring the waveform into view.
    var plotCount = 0
    @SceneStorage("panelTab") private var tab: PanelTab = .console

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Group {
                switch tab {
                case .console: ConsoleView(buffer: console)
                case .waveform: ScopeView(kind: .waveform)
                case .spectrum: ScopeView(kind: .spectrum)
                case .spectrogram: ScopeView(kind: .spectrogram)
                }
            }
            .id(tab)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .onChange(of: plotCount) { _ in tab = .waveform }
    }
}

/// A divider you can drag to resize the panel below it.
struct PanelDivider: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var startHeight: CGFloat?

    var body: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .background(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startHeight ?? height
                    startHeight = start
                    height = clamp(start - drag.translation.height)
                }
                .onEnded { _ in startHeight = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Panel size")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityAdjustableAction { direction in
            height = clamp(height + (direction == .increment ? 40 : -40))
        }
    }

    private func clamp(_ h: CGFloat) -> CGFloat { min(max(h, range.lowerBound), range.upperBound) }
}

/// A divider you can drag between two views. A vertical one stands between views side by side. Moving
/// it by d points (right or down) makes `size`, the size of the view it resizes, `sign` × d bigger.
struct ResizeDivider: View {
    var vertical: Bool
    var sign: CGFloat
    @Binding var size: CGFloat
    let range: ClosedRange<CGFloat>
    /// Inside the panel, in the panel's colour, rather than between the editor and the panel.
    var inner = false
    var label: String
    @State private var startSize: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: vertical ? 5 : 36, height: vertical ? 36 : 5)
        }
        .frame(width: vertical ? 12 : nil, height: vertical ? nil : 12)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .background(Color(uiColor: inner ? .secondarySystemBackground : .systemBackground))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startSize ?? size
                    startSize = start
                    size = clamp(start + sign * (vertical ? drag.translation.width : drag.translation.height))
                }
                .onEnded { _ in startSize = nil }
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(size)) points")
        .accessibilityAdjustableAction { direction in
            size = clamp(size + (direction == .increment ? 40 : -40))
        }
    }

    private func clamp(_ s: CGFloat) -> CGFloat { min(max(s, range.lowerBound), range.upperBound) }
}

/// All three visualizers stacked.
struct ScopeStack: View {
    var body: some View {
        VStack(spacing: 1) {
            ScopeView(kind: .waveform)
            ScopeView(kind: .spectrum)
            ScopeView(kind: .spectrogram)
        }
        .background(Color.black)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum RevertRequest: Identifiable {
        case current(URL), all
        var id: String {
            switch self {
            case .current(let url): return url.path
            case .all: return "all"
            }
        }
    }
    @State private var revertRequest: RevertRequest?
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    /// The bottom panel's share of the height, and the waveform's height while typing on a phone.
    @AppStorage("panelFraction") private var panelFraction = 0.4
    @AppStorage("typingScopeHeight") private var typingScopeHeight = 80.0
    /// The side panel's share of the width in the wide layout; negative until its divider is dragged.
    @AppStorage("sideFraction") private var sideFraction = -1.0
    /// The scopes' share of the height, above the console in the side panel.
    @AppStorage("sideScopeFraction") private var sideScopeFraction = 0.5
    /// The scopes' share of the width, beside the console in the panel below.
    @AppStorage("rowScopeFraction") private var rowScopeFraction = 0.45

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let overlap = model.keyboardOverlap(bottom: geo.frame(in: .global).maxY)
                layout(for: geo.size, keyboard: overlap)
                    .padding(.bottom, overlap)
            }
            .ignoresSafeArea(.keyboard)
            .navigationTitle(model.title(for: model.currentDocument))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { documentMenu }
            .toolbar { toolbarContent }
        }
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: Binding(get: { model.functionListText != nil }, set: { if !$0 { model.functionListText = nil } })) {
            FunctionListView(text: model.functionListText ?? "")
        }
        .confirmationDialog(revertTitle, isPresented: Binding(get: { revertRequest != nil }, set: { if !$0 { revertRequest = nil } }),
                            titleVisibility: .visible, presenting: revertRequest) { request in
            Button("Revert", role: .destructive) {
                switch request {
                case .current(let url): model.revertToOriginal(url)
                case .all: model.revertAllBuiltIns()
                }
            }
        } message: { _ in
            Text("Your changes will be lost.")
        }
        .alert("Rename “\(model.title(for: model.currentDocument))”", isPresented: $renaming) {
            TextField("Name", text: $newName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameError = model.renameCurrent(to: newName) }
        }
        .alert("Can’t rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                model.saveNow()
                model.rememberPosition()
            }
            if phase == .active {
                model.refreshDocuments()
                model.resumeAudioIfInterrupted()
            }
        }
    }

    // MARK: Layout

    /// `size` is the whole content area; `keyboard` is how much of its bottom the keyboard covers.
    /// The editor stays the first child of one layout throughout, so changing layouts doesn't
    /// remove it from the window and take the keyboard away.
    private func layout(for size: CGSize, keyboard: CGFloat) -> some View {
        let wide = size.width > size.height * 1.15 && size.width >= 640
        let height = size.height - keyboard
        let stack = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return stack {
            EditorView(editor: model.editor)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !model.isEditing {
                        ReadingBar(editor: model.editor).frame(height: 46)
                    }
                }
                // Over the editor, so the console and scopes stay in view while you try its examples.
                .overlay {
                    if model.showsGuide { GuidePane() }
                }
            if wide {
                // Until its divider is dragged, the side panel is 38% of the width, from 300 to 520 points.
                let range: ClosedRange<CGFloat> = 260...max(260, size.width - 320)
                let saved = sideFraction < 0 ? min(max(300, size.width * 0.38), 520) : CGFloat(sideFraction) * size.width
                let sideWidth = min(max(saved, range.lowerBound), range.upperBound)
                ResizeDivider(vertical: true, sign: -1,
                              size: Binding(get: { sideWidth }, set: { sideFraction = Double($0 / size.width) }),
                              range: range, label: "Side panel width")
                sideColumn(height: height)
                    .frame(width: sideWidth)
            } else if size.width < 600 && keyboard > 120 {
                // Typing on a phone: keep a small live waveform so you can still see what's playing.
                let range: ClosedRange<CGFloat> = 40...max(40, height * 0.6)
                PanelDivider(height: Binding(get: { CGFloat(typingScopeHeight) }, set: { typingScopeHeight = Double($0) }), range: range)
                ScopeView(kind: .waveform)
                    .frame(height: min(max(CGFloat(typingScopeHeight), range.lowerBound), range.upperBound))
            } else {
                let range: ClosedRange<CGFloat> = 120...max(120, height - 140)
                let panelHeight = min(max(CGFloat(panelFraction) * height, range.lowerBound), range.upperBound)
                PanelDivider(height: Binding(get: { panelHeight }, set: { panelFraction = Double($0 / height) }), range: range)
                bottomPanel(width: size.width)
                    .frame(height: panelHeight)
            }
        }
    }

    @ViewBuilder
    private func sideColumn(height: CGFloat) -> some View {
        if height >= 600 {
            let range: ClosedRange<CGFloat> = 120...max(120, height - 120)
            let scopesHeight = min(max(CGFloat(sideScopeFraction) * height, range.lowerBound), range.upperBound)
            VStack(spacing: 0) {
                ScopeStack().frame(height: scopesHeight)
                ResizeDivider(vertical: false, sign: 1,
                              size: Binding(get: { scopesHeight }, set: { sideScopeFraction = Double($0 / height) }),
                              range: range, inner: true, label: "Scopes height")
                ConsoleView(buffer: model.console)
            }
        } else {
            TabbedPanel(console: model.console, plotCount: model.plotCount)
        }
    }

    @ViewBuilder
    private func bottomPanel(width: CGFloat) -> some View {
        if width >= 600 {
            let range: ClosedRange<CGFloat> = 200...max(200, width - 200)
            let scopesWidth = min(max(CGFloat(rowScopeFraction) * width, range.lowerBound), range.upperBound)
            HStack(spacing: 0) {
                ConsoleView(buffer: model.console)
                ResizeDivider(vertical: true, sign: -1,
                              size: Binding(get: { scopesWidth }, set: { rowScopeFraction = Double($0 / width) }),
                              range: range, inner: true, label: "Scopes width")
                ScopeStack().frame(width: scopesWidth)
            }
        } else {
            TabbedPanel(console: model.console, plotCount: model.plotCount)
        }
    }

    private var revertTitle: String {
        switch revertRequest {
        case .current(let url)?: return "Revert \(model.title(for: url)) to the original?"
        case .all?:
            let names = model.modifiedBuiltIns.map { model.title(for: $0) }.sorted().joined(separator: ", ")
            return "Revert \(names) to the originals?"
        case nil: return ""
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var documentMenu: some View {
        Section {
            Button { model.newDocument() } label: { Label("New Document", systemImage: "doc.badge.plus") }
            if model.canRenameCurrent {
                Button {
                    newName = model.title(for: model.currentDocument)
                    renaming = true
                } label: { Label("Rename…", systemImage: "pencil") }
            }
            Button { model.exportCurrent() } label: { Label("Save to Files…", systemImage: "square.and.arrow.down") }
            Button { model.showLog() } label: { Label("Log", systemImage: "clock.arrow.circlepath") }
            if model.canRevertCurrent {
                Button(role: .destructive) { revertRequest = .current(model.currentDocument) } label: {
                    Label("Revert to Original…", systemImage: "arrow.counterclockwise")
                }
            }
            if !model.modifiedBuiltIns.isEmpty {
                Button(role: .destructive) { revertRequest = .all } label: {
                    Label("Revert All Built-in Files…", systemImage: "arrow.counterclockwise.circle")
                }
            }
        }
        Section {
            ForEach(model.documents, id: \.self) { url in
                Button {
                    model.load(url)
                } label: {
                    if url == model.currentDocument {
                        Label(model.title(for: url), systemImage: "checkmark")
                    } else {
                        Text(model.title(for: url))
                    }
                }
            }
        }
    }

    private var runButton: some View {
        Button { model.evaluate() } label: { Label("Run", systemImage: "play.fill") }
            .keyboardShortcut(.return, modifiers: .command)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Left side, so that on a small phone it doesn't push Stop off the right.
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Menu { documentMenu } label: { Label("Documents", systemImage: "folder") }
            // A phone's toolbar has no room for it: it would push Stop into an overflow menu. There, the
            // Guide is first in the ⋯ menu.
            if sizeClass != .compact {
                Button { model.showsGuide ? model.closeGuide() : model.showGuide() } label: { Label("Guide", systemImage: "book") }
            }
            if model.isEditing {
                Button { model.stopEditing() } label: { Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down") }
            } else {
                Button { model.startEditing() } label: { Label("Edit", systemImage: "keyboard") }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if model.isBusy {
                ProgressView().accessibilityLabel("Evaluating")
            }
            // A narrow toolbar overflows into a menu, and Stop must stay one tap away. Blocks can
            // still be run from the margin and the key bar, so Run moves into the ⋯ menu.
            if sizeClass != .compact {
                runButton.tint(.green)
            }
            Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            Menu {
                if sizeClass == .compact {
                    runButton
                    Button { model.showGuide() } label: { Label("Guide", systemImage: "book") }
                }
                Toggle(isOn: $model.showsHelpOnTap) { Label("Help on Tap", systemImage: "questionmark.bubble") }
                Section {
                    Button { model.editorFontSize = min(model.editorFontSize + 1, 32) } label: {
                        Label("Bigger Text", systemImage: "textformat.size.larger")
                    }
                    Button { model.editorFontSize = max(model.editorFontSize - 1, 9) } label: {
                        Label("Smaller Text", systemImage: "textformat.size.smaller")
                    }
                }
                Picker(selection: $model.uiMode) {
                    ForEach(AppModel.UIMode.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Label("UI Mode", systemImage: "circle.lefthalf.filled")
                }
                .pickerStyle(.menu)
                Picker(selection: $model.audioBufferFrames) {
                    ForEach(AppModel.audioBufferChoices, id: \.self) { frames in
                        Text("\(frames) frames (\(Int((Double(frames) / max(SapfEngine.shared.sampleRate, 8000) * 1000).rounded())) ms)").tag(frames)
                    }
                } label: {
                    Label("Audio Buffer", systemImage: "waveform.badge.plus")
                }
                .pickerStyle(.menu)
                Button { model.editor.showFind() } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                Button { model.plotTopOfStack() } label: {
                    Label("Plot Top of Stack", systemImage: "chart.xyaxis.line")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Section {
                    if sizeClass != .compact {
                        Button { model.showGuide() } label: { Label("Guide", systemImage: "book") }
                    }
                    Button { model.previewURL = DocumentStore.readme } label: { Label("README", systemImage: "doc.text") }
                    Button { model.showAllFunctions() } label: { Label("List All Functions", systemImage: "list.bullet.rectangle") }
                    Button { model.clearStack() } label: { Label("Clear Stack", systemImage: "square.stack.3d.up.slash") }
                    Button { model.console.clear() } label: { Label("Clear Console", systemImage: "trash") }
                }
                Section("sapf \(SapfEngine.shared.version) · \(Int(SapfEngine.shared.sampleRate)) Hz") {}
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}
