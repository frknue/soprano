import AppKit
import UniformTypeIdentifiers

/// One file open in the editor. Every editor tab showing the file shares it:
/// one text storage (each view lays it out separately), one undo history,
/// one saved state, and one watcher on the file.
@MainActor
final class EditorDocument {
    enum Content: Equatable {
        case text
        case image
        /// Opened but not editable as text, with the reason.
        case unavailable(String)
    }

    enum DiskState: Equatable {
        case inSync
        /// Another program changed the file while there were unsaved edits.
        case changed
        case deleted
    }

    enum Change {
        /// The text or image is about to be replaced from disk.
        case willReplaceContent
        case content
        /// Dirty, disk, or read-only state changed.
        case state
        case highlights
        /// The file was renamed or moved.
        case location
        /// The text was edited in some view.
        case edited
    }

    /// Larger files open with a note instead of their text.
    static let maximumTextBytes = 8 * 1024 * 1024
    /// Images are shown, not edited, so they may be larger.
    static let maximumImageBytes = 64 * 1024 * 1024
    /// Larger texts stay uncolored; re-highlighting them on every pause in
    /// typing would cost more than it is worth.
    static let maximumHighlightedLength = 1_500_000

    private(set) var url: URL
    let textStorage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var content: Content = .text
    private(set) var image: NSImage?
    private(set) var isDirty = false
    private(set) var diskState: DiskState = .inSync
    private(set) var isReadOnly = false
    private(set) var language: CodeLanguage?
    private(set) var tokens: [SyntaxToken] = []

    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var savedText: NSString = ""
    /// The bytes last read from or written to the file, to tell another
    /// program's change from our own save.
    private var diskData: Data?
    private var diskSignature: DiskSignature?
    private var watcher: ConfigFileWatcher?
    private var textObserver: NSObjectProtocol?
    private var isReplacingText = false
    private var textVersion = 0
    private var highlightTask: Task<Void, Never>?
    private var stateNotificationPending = false
    private var lineStarts: [Int] = [0]
    private var lineStartsVersion = -1
    private var observers: [ObjectIdentifier: (owner: WeakOwner, handler: (Change) -> Void)] = [:]

    private final class WeakOwner {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    init(url: URL) {
        self.url = url.standardizedFileURL
        language = CodeLanguage.forFile(named: self.url.lastPathComponent)
        textObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textStorageDidProcessEditing()
            }
        }
        load()
        startWatching()
    }

    deinit {
        MainActor.assumeIsolated {
            watcher?.stop()
            highlightTask?.cancel()
            if let textObserver {
                NotificationCenter.default.removeObserver(textObserver)
            }
        }
    }

    var name: String { url.lastPathComponent }

    // MARK: - Observers

    func addObserver(_ owner: AnyObject, handler: @escaping (Change) -> Void) {
        observers[ObjectIdentifier(owner)] = (WeakOwner(owner), handler)
    }

    func removeObserver(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func notify(_ change: Change) {
        for (key, entry) in observers {
            guard entry.owner.value != nil else {
                observers.removeValue(forKey: key)
                continue
            }
            entry.handler(change)
        }
    }

    // MARK: - Loading

    /// What is on disk, without reading it: comparing these costs one stat
    /// call, while the watcher fires for every write in the file's folder.
    private struct DiskSignature: Equatable {
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        let inode: UInt64
    }

    private enum DiskRead {
        case data(Data)
        case tooLarge(Int64)
        case missing
        case failed(Error)
    }

    private static func signature(of url: URL) -> DiskSignature? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return DiskSignature(
            size: Int64(info.st_size),
            seconds: info.st_mtimespec.tv_sec,
            nanoseconds: info.st_mtimespec.tv_nsec,
            inode: UInt64(info.st_ino)
        )
    }

    /// Reads the file, unless it is larger than anything the editor shows:
    /// a click previews any file, and a multi-gigabyte video must not be
    /// read into memory just to say it is too large.
    private func readDisk() -> (DiskRead, DiskSignature?) {
        guard let signature = Self.signature(of: url) else {
            return (errno == ENOENT ? .missing : .failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)), nil)
        }
        let limit = Self.isImageFile(url) ? Self.maximumImageBytes : Self.maximumTextBytes
        guard signature.size <= limit else { return (.tooLarge(signature.size), signature) }
        do {
            return (.data(try Data(contentsOf: url)), signature)
        } catch CocoaError.fileReadNoSuchFile {
            return (.missing, nil)
        } catch {
            return (.failed(error), signature)
        }
    }

    private func load() {
        let (read, signature) = readDisk()
        diskSignature = signature
        switch read {
        case .data(let data):
            apply(data)
        case .tooLarge(let size):
            diskData = nil
            image = nil
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            content = .unavailable("“\(name)” is \(formatted), too large to open in Soprano.")
            replaceText("")
        case .missing:
            // Deleted since its tab was saved: an empty buffer that saving
            // writes back.
            diskData = nil
            content = .text
            replaceText("")
            savedText = ""
            diskState = .deleted
        case .failed(let error):
            diskData = nil
            content = .unavailable("Soprano couldn't read “\(name)”: \(error.localizedDescription)")
            replaceText("")
        }
    }

    private func apply(_ data: Data) {
        diskData = data
        image = nil
        if Self.isImageFile(url), let image = NSImage(data: data) {
            self.image = image
            content = .image
            replaceText("")
            return
        }
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else {
            content = .unavailable("“\(name)” isn't a UTF-8 text file.")
            replaceText("")
            return
        }
        content = .text
        replaceText(text)
        savedText = text as NSString
        isReadOnly = !FileManager.default.isWritableFile(atPath: url.path)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        // SVG is an image to the system but text people edit.
        guard pathExtension != "svg", let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func replaceText(_ text: String) {
        isReplacingText = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.setAttributes(baseAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        isReplacingText = false
        textVersion += 1
        undoManager.removeAllActions()
        scheduleHighlight(immediately: true)
    }

    /// Font and color for every character; syntax colors are drawn on top
    /// by each view. All views use the same theme, so this is shared.
    func applyBaseAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        baseAttributes = attributes
        isReplacingText = true
        textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        isReplacingText = false
    }

    // MARK: - Editing

    private func textStorageDidProcessEditing() {
        guard !isReplacingText, textStorage.editedMask.contains(.editedCharacters) else { return }
        textVersion += 1
        let wasDirty = isDirty
        isDirty = textStorage.length != savedText.length
            || !textStorage.mutableString.isEqual(to: savedText as String)
        // Views react by renaming tabs; that must wait until the text system
        // has finished processing this edit.
        if wasDirty != isDirty {
            scheduleStateNotification()
        }
        notify(.edited)
        scheduleHighlight()
    }

    private func scheduleStateNotification() {
        guard !stateNotificationPending else { return }
        stateNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateNotificationPending = false
            self.notify(.state)
        }
    }

    /// 1-based line containing the UTF-16 offset `location`.
    func lineNumber(at location: Int) -> Int {
        updateLineStarts()
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(1, low)
    }

    var lineCount: Int {
        updateLineStarts()
        return lineStarts.count
    }

    private func updateLineStarts() {
        guard lineStartsVersion != textVersion else { return }
        lineStartsVersion = textVersion
        let string = textStorage.mutableString
        let length = string.length
        var starts = [0]
        var buffer = [unichar](repeating: 0, count: 4096)
        var offset = 0
        while offset < length {
            let count = min(buffer.count, length - offset)
            string.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for index in 0..<count where buffer[index] == 10 {
                starts.append(offset + index + 1)
            }
            offset += count
        }
        lineStarts = starts
    }

    // MARK: - Highlighting

    private func scheduleHighlight(immediately: Bool = false) {
        highlightTask?.cancel()
        guard content == .text, let language, textStorage.length <= Self.maximumHighlightedLength else {
            if !tokens.isEmpty {
                tokens = []
                notify(.highlights)
            }
            return
        }
        highlightTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            let version = self.textVersion
            let snapshot = self.textStorage.mutableString.copy() as! NSString as String
            let tokens = await Task.detached(priority: .userInitiated) {
                CodeSyntaxHighlighter.tokens(in: snapshot, language: language)
            }.value
            guard !Task.isCancelled, version == self.textVersion else { return }
            self.tokens = tokens
            self.notify(.highlights)
        }
    }

    // MARK: - Saving

    /// Writes the text to disk, keeping the file's permissions; a symlink
    /// keeps pointing at the file it names.
    func save() throws {
        guard content == .text else { return }
        let text = textStorage.mutableString.copy() as! NSString
        let data = Data((text as String).utf8)
        let target = Self.resolvedPath(url.path)
        let permissions = try? FileManager.default.attributesOfItem(atPath: target)[.posixPermissions]
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target)
        }
        diskData = data
        diskSignature = Self.signature(of: url)
        savedText = text
        isDirty = textStorage.length != text.length || !textStorage.mutableString.isEqual(to: text as String)
        diskState = .inSync
        isReadOnly = false
        notify(.state)
    }

    /// Whether another program wrote a different version since the file was
    /// last read or saved here. A deleted file has nothing to overwrite.
    var diskChangedSinceLastSync: Bool {
        guard let signature = Self.signature(of: url), signature != diskSignature else { return false }
        // A different size is a different file; only an equal size needs the bytes.
        guard let diskData, Int64(diskData.count) == signature.size,
              let current = try? Data(contentsOf: url)
        else { return true }
        return current != diskData
    }

    // MARK: - Disk Changes

    private func startWatching() {
        watcher?.stop()
        let watcher = ConfigFileWatcher(url: url, debounceInterval: .milliseconds(150)) { [weak self] in
            Task { @MainActor [weak self] in
                self?.diskDidChange()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// A clean buffer follows the file; one with unsaved edits keeps them
    /// and is marked, like Orca's "changed on disk".
    func diskDidChange() {
        // Another file in the same folder changed: nothing to read.
        let signature = Self.signature(of: url)
        guard signature != diskSignature else { return }
        let (read, newSignature) = readDisk()
        diskSignature = newSignature
        switch read {
        case .missing:
            if diskState != .deleted {
                diskState = .deleted
                notify(.state)
            }
        case .failed:
            return
        case .data(let data) where data == diskData:
            // Touched, or written back unchanged.
            if diskState != .inSync {
                diskState = .inSync
                notify(.state)
            }
        case .data, .tooLarge:
            if isDirty {
                diskState = .changed
                notify(.state)
            } else {
                reloadContent()
            }
        }
    }

    /// Replaces the buffer, unsaved edits included, with the file on disk.
    func reloadFromDisk() {
        guard Self.signature(of: url) != nil else {
            diskState = .deleted
            notify(.state)
            return
        }
        reloadContent()
    }

    private func reloadContent() {
        notify(.willReplaceContent)
        diskState = .inSync
        isDirty = false
        load()
        notify(.content)
        notify(.state)
    }

    /// Drops unsaved edits ("Don't Save").
    func discardChanges() {
        guard isDirty else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            reloadFromDisk()
        } else {
            savedText = textStorage.mutableString.copy() as! NSString
            isDirty = false
            notify(.state)
        }
    }

    /// Follows a rename or move made in the explorer.
    func relocate(to newURL: URL) {
        url = newURL.standardizedFileURL
        language = CodeLanguage.forFile(named: url.lastPathComponent)
        startWatching()
        scheduleHighlight(immediately: true)
        notify(.location)
    }

    private static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Store

/// The open editor documents, shared by every tab showing the same file,
/// and the questions asked before unsaved changes would be lost.
@MainActor
final class EditorDocumentStore {
    static let shared = EditorDocumentStore()

    enum SaveChoice {
        case save
        case discard
        case cancel
    }

    /// Asked when documents with unsaved changes are about to close.
    var askToSave: @MainActor ([EditorDocument]) -> SaveChoice = EditorDocumentStore.alertAskingToSave
    /// Asked before a save would replace a version another program wrote.
    var askToOverwrite: @MainActor (EditorDocument) -> Bool = EditorDocumentStore.alertAskingToOverwrite
    var reportSaveError: @MainActor (EditorDocument, Error) -> Void = { _, error in
        NSAlert(error: error).runModal()
    }

    private var documents: [URL: EditorDocument] = [:]
    /// The views showing each document, keyed by the view itself: a tab's
    /// view can be rebuilt while the old one is still alive, and the old
    /// one leaving must not take the new one's place with it.
    private var attachments: [ObjectIdentifier: (target: TerminalTarget, document: EditorDocument)] = [:]

    init() {}

    /// The open document for `url`, opened now if it is not yet.
    func document(for url: URL) -> EditorDocument {
        let key = url.standardizedFileURL
        if let document = documents[key] {
            return document
        }
        let document = EditorDocument(url: key)
        documents[key] = document
        return document
    }

    /// Records that `view`, the content of tab `target`, shows `document`.
    func attach(_ view: AnyObject, as target: TerminalTarget, to document: EditorDocument) {
        attachments[ObjectIdentifier(view)] = (target, document)
    }

    /// `view` is gone; the last view of a document closes it.
    func detach(_ view: AnyObject) {
        guard let removed = attachments.removeValue(forKey: ObjectIdentifier(view)) else { return }
        if !attachments.values.contains(where: { $0.document === removed.document }) {
            documents.removeValue(forKey: removed.document.url)
        }
    }

    func hasUnsavedChanges(_ url: URL) -> Bool {
        documents[url.standardizedFileURL]?.isDirty == true
    }

    /// Before the tabs `targets` close: asks about documents with unsaved
    /// changes that no remaining tab shows. False means keep them open.
    func confirmClosing(_ targets: [TerminalTarget]) -> Bool {
        let closing = Set(targets)
        var losing: [EditorDocument] = []
        for (target, document) in attachments.values where closing.contains(target) && document.isDirty {
            let keepsAnotherTab = attachments.values.contains { other in
                other.document === document && !closing.contains(other.target)
            }
            if !keepsAnotherTab, !losing.contains(where: { $0 === document }) {
                losing.append(document)
            }
        }
        return resolveUnsaved(losing)
    }

    /// Before the app quits or its window closes.
    func confirmClosingAll() -> Bool {
        resolveUnsaved(documents.values.filter(\.isDirty).sorted { $0.name < $1.name })
    }

    private func resolveUnsaved(_ documents: [EditorDocument]) -> Bool {
        guard !documents.isEmpty else { return true }
        switch askToSave(documents) {
        case .cancel:
            return false
        case .discard:
            for document in documents {
                document.discardChanges()
            }
            return true
        case .save:
            return documents.allSatisfy { save($0) }
        }
    }

    /// Saves, asking first when another program changed the file since it
    /// was read. False when nothing was written.
    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        if document.diskChangedSinceLastSync, !askToOverwrite(document) {
            return false
        }
        do {
            try document.save()
            return true
        } catch {
            reportSaveError(document, error)
            return false
        }
    }

    /// Follows a rename or move of `oldURL`, or of a folder containing open
    /// documents.
    func relocate(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        for (url, document) in documents {
            let path = url.path
            let relocated: String
            if path == oldPath {
                relocated = newPath
            } else if path.hasPrefix(oldPath + "/") {
                relocated = newPath + path.dropFirst(oldPath.count)
            } else {
                continue
            }
            let newKey = URL(fileURLWithPath: relocated).standardizedFileURL
            documents.removeValue(forKey: url)
            documents[newKey] = document
            document.relocate(to: newKey)
        }
    }

    // MARK: - Alerts

    private static func alertAskingToSave(_ documents: [EditorDocument]) -> SaveChoice {
        let alert = NSAlert()
        if documents.count == 1 {
            alert.messageText = "Do you want to save the changes you made to “\(documents[0].name)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
        } else {
            alert.messageText = "Do you want to save the changes you made to \(documents.count) files?"
            alert.informativeText = documents.map(\.name).joined(separator: ", ")
                + "\n\nYour changes will be lost if you don't save them."
        }
        alert.addButton(withTitle: documents.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .cancel
        default:
            return .discard
        }
    }

    private static func alertAskingToOverwrite(_ document: EditorDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(document.name)” has changed on disk."
        alert.informativeText = "Another program changed it since you opened it. Saving replaces that version with yours."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
