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

/// Read-only, automatically reloading local Markdown content, drawn as Soprano
/// Agents' Markdown reader: a 40 pt header with the repository-relative
/// breadcrumbs and ghost buttons over New York 16/26 in a 920 pt column.
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
    private var toolbar: SurfaceToolbar!
    private let breadcrumbs = SurfaceBreadcrumbs.label()
    private var backButton: ShellGhostButton!
    private var forwardButton: ShellGhostButton!
    private var reloadButton: ShellGhostButton!
    private var revealButton: ShellGhostButton!
    private var editButton: ShellGhostButton!

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
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.background.cgColor
        webView.underPageBackgroundColor = palette.background
        updateToolbar()
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

        backButton = SurfaceToolbar.button("chevron.left", "Previous Markdown file", target: self, action: #selector(goBack))
        forwardButton = SurfaceToolbar.button("chevron.right", "Next Markdown file", target: self, action: #selector(goForward))
        reloadButton = SurfaceToolbar.button("arrow.clockwise", "Reload Markdown", target: self, action: #selector(reload))
        editButton = SurfaceToolbar.button("arrow.up.forward.app", "Open in Editor", target: self, action: #selector(openInEditor))
        revealButton = SurfaceToolbar.button("folder", "Reveal in Finder", target: self, action: #selector(revealInFinder))
        toolbar = SurfaceToolbar(
            leading: [breadcrumbs],
            trailing: [backButton, forwardButton, reloadButton, editButton, revealButton]
        )
        toolbar.setSpacing(6, after: forwardButton)
        addSubview(toolbar)

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

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme()
    }

    private func updateToolbar() {
        breadcrumbs.attributedStringValue = SurfaceBreadcrumbs.make(
            SurfaceBreadcrumbs.displayPath(of: fileURL),
            palette: PaletteCenter.shared.palette
        )
        breadcrumbs.toolTip = fileURL.path
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

    /// Agents' Markdown reader (`MarkdownStyle.document`) as a style sheet:
    /// New York 16/26 in a 920 px column with 32/42 padding, h1 28/34, h2
    /// 21/28 over a rule, links in `info`, inline code on a `foreground/10`
    /// chip, code blocks with a language header and the timeline's syntax
    /// colors, tables with row rules only, muted quotes on a 2 px rule.
    private func htmlDocument(body: String) -> String {
        let palette = PaletteCenter.shared.palette
        let codeBlock = palette.isDark ? palette.input.timelineAlpha(0.32) : palette.secondary
        let codeEdge = palette.isDark ? "none" : "1px solid \(palette.border.timelineAlpha(0.7).markdownCSS)"
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; img-src soprano-markdown: data: https:;
                         style-src 'unsafe-inline'; font-src data:; script-src 'none';
                         object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
          <style>
            :root {
              color-scheme: \(palette.isDark ? "dark" : "light");
              --bg: \(palette.background.markdownCSS);
              --text: \(palette.foreground.markdownCSS);
              --muted: \(palette.mutedForeground.markdownCSS);
              --link: \(palette.infoForeground.markdownCSS);
              --selection: \(SurfaceText.selection(palette).markdownCSS);
              --border: \(palette.border.markdownCSS);
              --chip: \(palette.foreground.timelineAlpha(0.1).markdownCSS);
              --quote: \(palette.foreground.timelineAlpha(0.35).markdownCSS);
              --code-bg: \(codeBlock.markdownCSS);
              --code-label: \(palette.foreground.timelineAlpha(0.72).markdownCSS);
              --tok-keyword: \(palette.mergedForeground.markdownCSS);
              --tok-string: \(palette.successForeground.markdownCSS);
              --tok-number: \(palette.warningForeground.markdownCSS);
              --tok-type: \(palette.infoForeground.markdownCSS);
              --tok-deleted: \(palette.errorForeground.markdownCSS);
              --serif: ui-serif, "New York", Georgia, serif;
              --mono: ui-monospace, "SF Mono", Menlo, monospace;
            }
            * { box-sizing: border-box; }
            html { background: var(--bg); scroll-behavior: smooth; }
            ::selection { background: var(--selection); }
            /* The reader: New York 16/26 in a 920 px column, 32/42 padding. */
            body {
              background: var(--bg);
              color: var(--text);
              font: 400 16px/26px var(--serif);
              margin: 0 auto;
              max-width: calc(920px + 84px);
              padding: 32px 42px 48px;
              overflow-wrap: break-word;
            }
            h1, h2, h3, h4, h5, h6 {
              color: var(--text);
              font-family: var(--serif);
              scroll-margin-top: 20px;
            }
            h1 { font: 400 28px/34px var(--serif); margin: 0 0 12px; }
            h2 {
              font: 400 21px/28px var(--serif);
              margin: 28px 0 10px;
              padding-bottom: 6px;
              border-bottom: 1px solid var(--border);
            }
            h3 { font-size: 17px; line-height: 22px; font-weight: 500; margin: 24px 0 8px; }
            h4, h5, h6 { font-size: 16px; line-height: 26px; font-weight: 600; margin: 20px 0 6px; }
            p, blockquote, ul, ol, .code-block, pre, .table-scroll { margin: 0 0 16px; }
            a { color: var(--link); text-decoration: none; }
            a:hover { text-decoration: underline; text-underline-offset: 3px; }
            code {
              background: var(--chip);
              border-radius: 4px;
              color: var(--text);
              font: 13px/1 var(--mono);
              padding: 1px .35em;
            }
            .code-block {
              background: var(--code-bg);
              border: \(codeEdge);
              border-radius: \(Int(Radius.lg))px;
              overflow: hidden;
            }
            .code-header {
              color: var(--code-label);
              font: 11px/16px var(--mono);
              height: 30px;
              padding: 10px 12px 0;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
            }
            pre {
              font: 13px/18px var(--mono);
              overflow: auto;
              padding: 12px 14px;
              tab-size: 4;
            }
            .code-block pre { margin: 0; }
            pre code { background: transparent; border-radius: 0; font: inherit; padding: 0; }
            .raw-html { color: var(--muted); }
            .tok-keyword, .tok-tag { color: var(--tok-keyword); }
            .tok-heading { color: var(--text); }
            .tok-string, .tok-inserted { color: var(--tok-string); }
            .tok-comment { color: var(--muted); }
            .tok-number, .tok-attribute { color: var(--tok-number); }
            .tok-type, .tok-function, .tok-key { color: var(--tok-type); }
            .tok-deleted { color: var(--tok-deleted); }
            blockquote {
              border-left: 2px solid var(--quote);
              color: var(--muted);
              margin-left: 0;
              padding-left: 12.8px;
            }
            blockquote > :last-child, li > :last-child { margin-bottom: 0; }
            ul, ol { padding-left: 24px; }
            li + li { margin-top: 4px; }
            input[type="checkbox"] { accent-color: var(--text); margin-right: .35em; }
            hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
            img { border-radius: 8px; height: auto; max-width: 100%; }
            .table-scroll { overflow-x: auto; }
            table {
              border-collapse: collapse;
              font: 13px/18px -apple-system, system-ui, sans-serif;
              width: max-content;
              min-width: 100%;
            }
            th, td { border-bottom: 1px solid var(--border); padding: 8px 12px; }
            tr:last-child td { border-bottom: 0; }
            th { font-weight: 600; padding-top: 9px; padding-bottom: 9px; }
            .align-left { text-align: left; }
            .align-center { text-align: center; }
            .align-right { text-align: right; }
            @media (max-width: 600px) {
              body { padding: 24px 22px 48px; }
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
                openLinkedFile(localURL)
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
                openLinkedFile(url)
            }
            return
        }

        decisionHandler(.cancel)
    }

    /// A linked document a viewer only displays (an image, a PDF, plain text)
    /// opens; anything else — an app, a script, a `.command` — could run code
    /// from an untrusted checkout, so it is only revealed in Finder.
    private func openLinkedFile(_ url: URL) {
        if Self.opensLinkedFile(url) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func opensLinkedFile(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey, .contentTypeKey]
        ),
            values.isRegularFile == true,
            let type = values.contentType,
            !type.conforms(to: .script),
            !type.conforms(to: .executable)
        else { return false }
        return [.image, .pdf, .audiovisualContent, .plainText].contains { type.conforms(to: $0) }
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

final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
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

        // `path` is already percent-decoded; decoding again would turn a link
        // to `a%2520b.md` (the file `a%20b.md`) into `a b.md`.
        let candidate = URL(fileURLWithPath: url.path).standardizedFileURL
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
