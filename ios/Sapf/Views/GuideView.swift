//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import WebKit

/// The guide, sapf-guide.html (shared with the web app), in a web view. Its Run buttons and links post
/// messages to the "sapf" handler, which hands them on. One web view for the life of the app, so the
/// guide keeps its place between showings.
@MainActor
final class GuideController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// What the guide asks for: ["action": "run", "code": …], or "stop", "functions", "readme", "close",
    /// or ["action": "open", "document": title].
    var onMessage: (([String: Any]) -> Void)?

    lazy var webView: WKWebView = {
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: "window.sapfHost = { platform: 'ios' };",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakMessageHandler(self), name: "sapf")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        // The page has its own light and dark colors; this avoids a white flash while it loads in dark mode.
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "Guide"
        if let url = Bundle.main.url(forResource: "sapf-guide", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        onMessage?(body)
    }

    /// The guide and its own anchors stay here; any other link opens in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL { return decisionHandler(.allow) }
        if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }
}

/// The user content controller keeps its handlers, so hand messages on without keeping the controller alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private struct GuideWebView: UIViewRepresentable {
    let controller: GuideController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The guide over the editor, with Done. The toolbar (with Stop), the console and the scopes stay in
/// view, so you can watch and hear its examples.
struct GuidePane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("sapf Guide").font(.headline)
                Spacer()
                Button { model.closeGuide() } label: { Text("Done").fontWeight(.semibold) }
                    .accessibilityIdentifier("Close Guide")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(uiColor: .secondarySystemBackground))
            Divider()
            GuideWebView(controller: model.guide)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
