import WebKit

/// Owns the non-persistent WebKit page used by anonymous site requests.
@MainActor final class SiteWebContext: NSObject, SiteAnonymousTransport, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let sessionRequest: URLRequest
    private var loadingDocument = false

    init(origin: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        sessionRequest = URLRequest(url: URL(string: origin + "/api/auth/session")!)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    var pageURL: URL? { webView.url }
    var isLoading: Bool { webView.isLoading }

    func loadSessionIfNeeded() {
        guard !loadingDocument else { return }
        loadingDocument = true
        reloadSession()
    }

    func reloadSession() {
        webView.load(sessionRequest)
    }

    func clearWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    func evaluate(_ script: String, arguments: [String: Any]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingDocument = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingDocument = false
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}
