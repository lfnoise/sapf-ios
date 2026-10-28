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

import QuickLook
import SwiftUI

struct EditorView: UIViewRepresentable {
    let editor: CodeTextView
    func makeUIView(context: Context) -> CodeTextView { editor }
    func updateUIView(_ uiView: CodeTextView, context: Context) {}
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
    }
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

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                layout(for: geo.size)
            }
            .navigationTitle(model.title(for: model.currentDocument))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { documentMenu }
            .toolbar { toolbarContent }
        }
        .quickLookPreview($model.previewURL)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.saveNow() }
            if phase == .active { model.refreshDocuments() }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func layout(for size: CGSize) -> some View {
        let wide = size.width > size.height * 1.15 && size.width >= 640
        if wide {
            HStack(spacing: 0) {
                EditorView(editor: model.editor)
                Divider()
                sideColumn(height: size.height)
                    .frame(width: min(max(300, size.width * 0.38), 520))
            }
        } else {
            VStack(spacing: 0) {
                EditorView(editor: model.editor)
                Divider()
                bottomPanel(size: size)
            }
        }
    }

    @ViewBuilder
    private func sideColumn(height: CGFloat) -> some View {
        if height >= 600 {
            VStack(spacing: 0) {
                ScopeStack().frame(height: height * 0.5)
                Divider()
                ConsoleView(buffer: model.console)
            }
        } else {
            TabbedPanel(console: model.console)
        }
    }

    @ViewBuilder
    private func bottomPanel(size: CGSize) -> some View {
        if size.width < 600 && model.keyboardVisible {
            // Typing on a phone: keep a small live waveform so you can still see what's playing.
            ScopeView(kind: .waveform).frame(height: 56)
        } else if size.width >= 600 {
            HStack(spacing: 0) {
                ConsoleView(buffer: model.console)
                Divider()
                ScopeStack().frame(width: size.width * 0.45)
            }
            .frame(height: max(220, size.height * 0.38))
        } else {
            TabbedPanel(console: model.console)
                .frame(height: max(200, size.height * 0.4))
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var documentMenu: some View {
        Section {
            Button { model.newDocument() } label: { Label("New Document", systemImage: "doc.badge.plus") }
            if model.canRestoreCurrent {
                Button(role: .destructive) { model.restoreCurrent() } label: {
                    Label("Restore Original", systemImage: "arrow.counterclockwise")
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Menu { documentMenu } label: { Label("Documents", systemImage: "folder") }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if model.isBusy {
                ProgressView().accessibilityLabel("Evaluating")
            }
            Button { model.evaluate() } label: { Label("Run", systemImage: "play.fill") }
                .tint(.green)
                .keyboardShortcut(.return, modifiers: .command)
            Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            Menu {
                Toggle(isOn: $model.showsHelpOnTap) { Label("Help on Tap", systemImage: "questionmark.bubble") }
                Section {
                    Button { model.editorFontSize = min(model.editorFontSize + 1, 32) } label: {
                        Label("Bigger Text", systemImage: "textformat.size.larger")
                    }
                    Button { model.editorFontSize = max(model.editorFontSize - 1, 9) } label: {
                        Label("Smaller Text", systemImage: "textformat.size.smaller")
                    }
                }
                Section {
                    Button { model.evaluate("helpall") } label: { Label("List All Functions", systemImage: "list.bullet.rectangle") }
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
