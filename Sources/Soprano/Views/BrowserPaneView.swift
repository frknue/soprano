import AppKit
import WebKit

/// A browser pane backed by WKWebView.
final class BrowserPaneView: NSView, WKNavigationDelegate {
    let paneId: String
    private var webView: WKWebView!
    private var urlBar: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private let defaultURL = URL(string: "https://www.google.com")!

    init(paneId: String, initialURL: URL? = nil) {
        self.paneId = paneId
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        loadURL(initialURL ?? defaultURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        // Navigation bar
        let navBar = NSView()
        navBar.wantsLayer = true
        navBar.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        navBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(navBar)

        backButton = NSButton(title: "◀", target: self, action: #selector(goBack))
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 12, weight: .medium)
        backButton.contentTintColor = .secondaryLabelColor
        backButton.translatesAutoresizingMaskIntoConstraints = false
        navBar.addSubview(backButton)

        forwardButton = NSButton(title: "▶", target: self, action: #selector(goForward))
        forwardButton.isBordered = false
        forwardButton.font = .systemFont(ofSize: 12, weight: .medium)
        forwardButton.contentTintColor = .secondaryLabelColor
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
        navBar.addSubview(forwardButton)

        reloadButton = NSButton(title: "↻", target: self, action: #selector(reloadPage))
        reloadButton.isBordered = false
        reloadButton.font = .systemFont(ofSize: 14, weight: .medium)
        reloadButton.contentTintColor = .secondaryLabelColor
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        navBar.addSubview(reloadButton)

        urlBar = NSTextField()
        urlBar.placeholderString = "Enter URL..."
        urlBar.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlBar.textColor = .labelColor
        urlBar.backgroundColor = NSColor(white: 0.1, alpha: 1)
        urlBar.isBezeled = true
        urlBar.bezelStyle = .roundedBezel
        urlBar.focusRingType = .none
        urlBar.target = self
        urlBar.action = #selector(urlBarAction)
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.addSubview(urlBar)

        // WebView
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: topAnchor),
            navBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 32),

            backButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 6),
            backButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 24),

            urlBar.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            urlBar.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -8),
            urlBar.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            urlBar.heightAnchor.constraint(equalToConstant: 24),

            webView.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func loadURL(_ url: URL) {
        webView.load(URLRequest(url: url))
        urlBar.stringValue = url.absoluteString
    }

    // MARK: - Actions

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func urlBarAction() {
        var input = urlBar.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        if !input.hasPrefix("http://") && !input.hasPrefix("https://") {
            input = "https://\(input)"
        }

        guard let url = URL(string: input) else { return }
        loadURL(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        if let url = webView.url {
            urlBar.stringValue = url.absoluteString
        }
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        if let url = webView.url {
            urlBar.stringValue = url.absoluteString
        }
    }
}
