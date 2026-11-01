//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

/// The help for every function, styled, with find and share.
struct FunctionListView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var textView = UITextView()

    var body: some View {
        NavigationStack {
            StyledText(textView: textView, text: FunctionList.attributedText(from: text))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("All Functions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { textView.findInteraction?.presentFindNavigator(showingReplace: false) } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct StyledText: UIViewRepresentable {
    let textView: UITextView
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        textView.isEditable = false
        textView.isFindInteractionEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
        textView.attributedText = text
        textView.accessibilityIdentifier = "All Functions"
        return textView
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
