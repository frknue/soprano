import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class MarkdownPaneRegistry {
    static let shared = MarkdownPaneRegistry()

    private final class WeakView {
        weak var value: MarkdownPaneView?

        init(_ value: MarkdownPaneView) {
            self.value = value
        }
    }

    private var views: [TerminalTarget: WeakView] = [:]

    func register(_ view: MarkdownPaneView) {
        prune()
        views[view.target] = WeakView(view)
    }

    func unregister(_ view: MarkdownPaneView) {
        guard views[view.target]?.value === view else { return }
        views.removeValue(forKey: view.target)
    }

    func view(for target: TerminalTarget) -> MarkdownPaneView? {
        prune()
        return views[target]?.value
    }

    private func prune() {
        views = views.filter { $0.value.value != nil }
    }
}

/// Read-only, automatically reloading local Markdown content.
@MainActor
final class MarkdownPaneView: NSView, WKNavigationDelegate {
    let target: TerminalTarget
    var onFocusRequested: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onDocumentChanged: ((URL) -> Void)?
    var onExternalURLRequested: ((URL) -> Void)?

    private let themeManager: ThemeManager
    private let schemeHandler: MarkdownSchemeHandler
    private let webView: MarkdownWebView
    private let toolbar = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let revealButton = NSButton()
    private let editButton = NSButton()

    private(set) var fileURL: URL
    private var watcher: ConfigFileWatcher?
    private var history: [URL] = []
    private var historyIndex = -1
    private var hasLoadedPage = false
    private var pendingScrollY: Double?
    private var pendingFragment: String?

    init(
        target: TerminalTarget,
        fileURL: URL,
        themeManager: ThemeManager
    ) {
        self.target = target
        self.fileURL = fileURL.standardizedFileURL
        self.themeManager = themeManager

        let handler = MarkdownSchemeHandler()
        schemeHandler = handler
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(
            handler,
            forURLScheme: MarkdownSchemeHandler.scheme
        )
        webView = MarkdownWebView(frame: .zero, configuration: configuration)

        super.init(frame: .zero)
        setupViews()
        MarkdownPaneRegistry.shared.register(self)
        openDocument(fileURL, recordHistory: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        watcher?.stop()
        MainActor.assumeIsolated {
            MarkdownPaneRegistry.shared.unregister(self)
        }
    }

    func focusPreferredControl() {
        onFocusRequested?()
        window?.makeFirstResponder(webView)
    }

    func applyTheme() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgBase.cgColor
        toolbar.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        pathLabel.textColor = theme.colors.textMuted
        for button in [backButton, forwardButton, reloadButton, revealButton, editButton] {
            button.contentTintColor = theme.colors.textMuted
        }
        webView.underPageBackgroundColor = theme.colors.bgBase
        if historyIndex >= 0 || hasLoadedPage {
            renderDocument(preservingScroll: true)
        }
    }

    func openDocument(
        _ fileURL: URL,
        fragment: String? = nil,
        recordHistory: Bool = false
    ) {
        let standardizedURL = fileURL.standardizedFileURL
        if standardizedURL == self.fileURL, hasLoadedPage {
            if let fragment {
                scrollToFragment(fragment)
            }
            return
        }

        self.fileURL = standardizedURL
        pendingFragment = fragment
        if recordHistory {
            if historyIndex + 1 < history.count {
                history.removeSubrange((historyIndex + 1)...)
            }
            history.append(standardizedURL)
            historyIndex = history.count - 1
        }
        startWatching()
        updateToolbar()
        onTitleChanged?(standardizedURL.lastPathComponent)
        onDocumentChanged?(standardizedURL)
        renderDocument(preservingScroll: false)
    }

    private func setupViews() {
        wantsLayer = true

        toolbar.wantsLayer = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        configureButton(
            backButton,
            symbol: "chevron.left",
            toolTip: "Previous Markdown file",
            action: #selector(goBack)
        )
        configureButton(
            forwardButton,
            symbol: "chevron.right",
            toolTip: "Next Markdown file",
            action: #selector(goForward)
        )
        configureButton(
            reloadButton,
            symbol: "arrow.clockwise",
            toolTip: "Reload Markdown",
            action: #selector(reload)
        )
        configureButton(
            revealButton,
            symbol: "folder",
            toolTip: "Reveal in Finder",
            action: #selector(revealInFinder)
        )
        configureButton(
            editButton,
            symbol: "square.and.pencil",
            toolTip: "Open in Editor",
            action: #selector(openInEditor)
        )

        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(pathLabel)

        webView.navigationDelegate = self
        webView.onFocusRequested = { [weak self] in
            self?.onFocusRequested?()
        }
        webView.onBackRequested = { [weak self] in self?.goBack() }
        webView.onForwardRequested = { [weak self] in self?.goForward() }
        webView.onReloadRequested = { [weak self] in self?.reload() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),

            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            pathLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: revealButton.leadingAnchor,
                constant: -8
            ),

            editButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            editButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            revealButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -4),
            revealButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme()
        updateToolbar()
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        toolTip: String,
        action: Selector
    ) {
        button.title = ""
        button.target = self
        button.action = action
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: toolTip
        )
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(button)
    }

    private func updateToolbar() {
        pathLabel.stringValue = ConfigFile.abbreviatingHome(fileURL.path)
        pathLabel.toolTip = fileURL.path
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex >= 0 && historyIndex + 1 < history.count
    }

    private func startWatching() {
        watcher?.stop()
        let watcher = ConfigFileWatcher(
            url: fileURL,
            debounceInterval: .milliseconds(180)
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.renderDocument(preservingScroll: true)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func renderDocument(preservingScroll: Bool) {
        guard preservingScroll, hasLoadedPage else {
            renderNow(restoringScrollY: nil)
            return
        }
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            let scrollY = (value as? NSNumber)?.doubleValue
            DispatchQueue.main.async {
                self?.renderNow(restoringScrollY: scrollY)
            }
        }
    }

    private func renderNow(restoringScrollY: Double?) {
        let html: String
        do {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let body = MarkdownHTMLRenderer.render(source)
            html = htmlDocument(body: body)
        } catch {
            html = errorDocument(error)
        }

        let accessRoot = MarkdownSchemeHandler.accessRoot(for: fileURL)
        let pageURL = schemeHandler.update(
            html: html,
            documentURL: fileURL,
            accessRoot: accessRoot
        )
        pendingScrollY = restoringScrollY
        webView.load(URLRequest(url: pageURL))
    }

    private func htmlDocument(body: String) -> String {
        let colors = themeManager.currentTheme.colors
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; img-src soprano-markdown: data: https:;
                         style-src 'unsafe-inline'; script-src 'none'; object-src 'none';
                         frame-src 'none'; form-action 'none'; base-uri 'none'">
          <style>
            :root {
              color-scheme: dark;
              --bg: \(colors.bgBase.markdownCSS);
              --panel: \(colors.bgPanel.markdownCSS);
              --raised: \(colors.bgRaised.markdownCSS);
              --overlay: \(colors.bgOverlay.markdownCSS);
              --text: \(colors.textPrimary.markdownCSS);
              --muted: \(colors.textMuted.markdownCSS);
              --accent: \(colors.accent.markdownCSS);
              --border: \(colors.borderSubtle.markdownCSS);
              --border-strong: \(colors.borderStrong.markdownCSS);
            }
            * { box-sizing: border-box; }
            html { background: var(--bg); scroll-behavior: smooth; }
            body {
              background: var(--bg);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              font-size: 15px;
              line-height: 1.65;
              margin: 0 auto;
              max-width: 920px;
              padding: 32px 42px 80px;
              overflow-wrap: break-word;
            }
            h1, h2, h3, h4, h5, h6 {
              color: var(--text);
              line-height: 1.25;
              margin: 1.5em 0 0.6em;
              scroll-margin-top: 20px;
            }
            h1 { font-size: 2em; border-bottom: 1px solid var(--border); padding-bottom: .3em; }
            h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: .3em; }
            h3 { font-size: 1.25em; }
            h4 { font-size: 1em; }
            p, blockquote, ul, ol, pre, .table-scroll { margin: 0 0 1em; }
            a { color: var(--accent); text-decoration: none; }
            a:hover { text-decoration: underline; }
            code {
              background: var(--raised);
              border: 1px solid var(--border);
              border-radius: 5px;
              font-family: "SFMono-Regular", Menlo, Monaco, monospace;
              font-size: .88em;
              padding: .15em .35em;
            }
            pre {
              background: var(--panel);
              border: 1px solid var(--border);
              border-radius: 8px;
              line-height: 1.5;
              overflow: auto;
              padding: 16px;
              tab-size: 4;
            }
            pre code { background: transparent; border: 0; padding: 0; }
            .raw-html { color: var(--muted); }
            blockquote {
              border-left: 4px solid var(--accent);
              color: var(--muted);
              padding: .25em 1em;
            }
            blockquote > :last-child, li > :last-child { margin-bottom: 0; }
            ul, ol { padding-left: 2em; }
            li + li { margin-top: .25em; }
            input[type="checkbox"] { accent-color: var(--accent); margin-right: .35em; }
            hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
            img { border-radius: 6px; height: auto; max-width: 100%; }
            .table-scroll { overflow-x: auto; }
            table { border-collapse: collapse; width: max-content; min-width: 100%; }
            th, td { border: 1px solid var(--border); padding: 7px 12px; }
            th { background: var(--panel); font-weight: 600; }
            tr:nth-child(even) td { background: color-mix(in srgb, var(--raised) 55%, transparent); }
            .align-left { text-align: left; }
            .align-center { text-align: center; }
            .align-right { text-align: right; }
            @media (max-width: 600px) {
              body { padding: 24px 22px 64px; }
            }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func errorDocument(_ error: Error) -> String {
        let path = fileURL.path.markdownEscaped
        let message = error.localizedDescription.markdownEscaped
        return htmlDocument(body: """
        <h1>Unable to read Markdown</h1>
        <p><code>\(path)</code></p>
        <blockquote>\(message)</blockquote>
        <p>Soprano is still watching this path and will reload it when it reappears.</p>
        """)
    }

    @objc private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        openDocument(history[historyIndex], recordHistory: false)
        updateToolbar()
    }

    @objc private func goForward() {
        guard historyIndex >= 0, historyIndex + 1 < history.count else { return }
        historyIndex += 1
        openDocument(history[historyIndex], recordHistory: false)
        updateToolbar()
    }

    @objc private func reload() {
        onFocusRequested?()
        renderDocument(preservingScroll: true)
    }

    @objc private func revealInFinder() {
        onFocusRequested?()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func openInEditor() {
        onFocusRequested?()
        NSWorkspace.shared.open(fileURL)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme == MarkdownSchemeHandler.scheme {
            if schemeHandler.isDocumentPage(url) {
                decisionHandler(.allow)
                return
            }
            guard let localURL = schemeHandler.fileURL(for: url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
            if MarkdownFilePicker.isMarkdown(localURL) {
                openDocument(
                    localURL,
                    fragment: url.fragment,
                    recordHistory: true
                )
            } else {
                NSWorkspace.shared.open(localURL)
            }
            return
        }

        if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            decisionHandler(.cancel)
            onExternalURLRequested?(url)
            return
        }

        if url.isFileURL {
            decisionHandler(.cancel)
            if MarkdownFilePicker.isMarkdown(url) {
                openDocument(url, fragment: url.fragment, recordHistory: true)
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }

        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoadedPage = true
        if let scrollY = pendingScrollY {
            pendingScrollY = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(scrollY))")
        } else if let fragment = pendingFragment {
            pendingFragment = nil
            scrollToFragment(fragment)
        }
    }

    private func scrollToFragment(_ fragment: String) {
        guard let data = try? JSONEncoder().encode(fragment),
              let literal = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript(
            "document.getElementById(\(literal))?.scrollIntoView()"
        )
    }
}

private final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "soprano-markdown"
    private static let documentName = "__soprano_document__.html"

    private let lock = NSLock()
    private var html = Data()
    private var accessRoot = URL(fileURLWithPath: "/", isDirectory: true)

    func update(html: String, documentURL: URL, accessRoot: URL) -> URL {
        lock.lock()
        self.html = Data(html.utf8)
        self.accessRoot = accessRoot.standardizedFileURL
        lock.unlock()

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "local"
        components.path = documentURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.documentName)
            .path
        return components.url!
    }

    func isDocumentPage(_ url: URL) -> Bool {
        url.lastPathComponent == Self.documentName
    }

    func fileURL(for url: URL) -> URL? {
        guard url.scheme == Self.scheme,
              url.host == "local",
              !isDocumentPage(url)
        else { return nil }

        let candidate = URL(
            fileURLWithPath: url.path.removingPercentEncoding ?? url.path
        ).standardizedFileURL
        lock.lock()
        let root = accessRoot
        lock.unlock()
        guard candidate.path == root.path
                || candidate.path.hasPrefix(root.path + "/")
        else { return nil }
        return candidate
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: .badURL)
            return
        }

        let data: Data
        let mimeType: String
        if isDocumentPage(url) {
            lock.lock()
            data = html
            lock.unlock()
            mimeType = "text/html"
        } else {
            guard let fileURL = fileURL(for: url),
                  let fileData = try? Data(contentsOf: fileURL)
            else {
                fail(urlSchemeTask, code: .resourceUnavailable)
                return
            }
            data = fileData
            mimeType = UTType(filenameExtension: fileURL.pathExtension)?
                .preferredMIMEType
                ?? "application/octet-stream"
        }

        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType == "text/html" ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask, code: URLError.Code) {
        task.didFailWithError(URLError(code))
    }

    static func accessRoot(for fileURL: URL) -> URL {
        let fileManager = FileManager.default
        var directory = fileURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if fileManager.fileExists(
                atPath: directory.appendingPathComponent(".git").path
            ) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return fileURL.deletingLastPathComponent().standardizedFileURL
    }
}

@MainActor
private final class MarkdownWebView: WKWebView {
    var onFocusRequested: (() -> Void)?
    var onBackRequested: (() -> Void)?
    var onForwardRequested: (() -> Void)?
    var onReloadRequested: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                self?.onFocusRequested?()
            }
        }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "[":
            onBackRequested?()
        case "]":
            onForwardRequested?()
        case "r":
            onReloadRequested?()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private extension NSColor {
    var markdownCSS: String {
        guard let color = usingColorSpace(.sRGB) else { return "rgba(255,255,255,1)" }
        return String(
            format: "rgba(%d,%d,%d,%.3f)",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            color.alphaComponent
        )
    }
}

private extension String {
    var markdownEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
