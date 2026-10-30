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
    /// The bottom panel's share of the height, and the waveform's height while typing on a phone.
    @AppStorage("panelFraction") private var panelFraction = 0.4
    @AppStorage("typingScopeHeight") private var typingScopeHeight = 80.0

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
            if wide {
                Divider()
                sideColumn(height: height)
                    .frame(width: min(max(300, size.width * 0.38), 520))
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
            VStack(spacing: 0) {
                ScopeStack().frame(height: height * 0.5)
                Divider()
                ConsoleView(buffer: model.console)
            }
        } else {
            TabbedPanel(console: model.console, plotCount: model.plotCount)
        }
    }

    @ViewBuilder
    private func bottomPanel(width: CGFloat) -> some View {
        if width >= 600 {
            HStack(spacing: 0) {
                ConsoleView(buffer: model.console)
                Divider()
                ScopeStack().frame(width: width * 0.45)
            }
        } else {
            TabbedPanel(console: model.console, plotCount: model.plotCount)
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

    private var runButton: some View {
        Button { model.evaluate() } label: { Label("Run", systemImage: "play.fill") }
            .keyboardShortcut(.return, modifiers: .command)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Left side, so that on a small phone it doesn't push Stop off the right.
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Menu { documentMenu } label: { Label("Documents", systemImage: "folder") }
            if !model.isEditing {
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
                Picker(selection: $model.audioBufferFrames) {
                    ForEach(AppModel.audioBufferChoices, id: \.self) { frames in
                        Text("\(frames) frames (\(Int((Double(frames) / max(SapfEngine.shared.sampleRate, 8000) * 1000).rounded())) ms)").tag(frames)
                    }
                } label: {
                    Label("Audio Buffer", systemImage: "waveform.badge.plus")
                }
                .pickerStyle(.menu)
                Button { model.plotTopOfStack() } label: {
                    Label("Plot Top of Stack", systemImage: "chart.xyaxis.line")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
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
