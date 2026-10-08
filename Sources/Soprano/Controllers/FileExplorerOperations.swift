import Foundation

enum FileExplorerOperationError: LocalizedError, Equatable {
    case alreadyExists(String)
    case invalidName(String)
    case moveIntoItself(String)
    case trashFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            "A file or folder named '\(name)' already exists in this location"
        case .invalidName(let name):
            "'\(name)' is not a valid file or folder name"
        case .moveIntoItself(let name):
            "Cannot move '\(name)' into itself"
        case .trashFailed(let name):
            "Failed to move to Trash '\(name)'."
        case .failed(let message):
            message
        }
    }
}

/// The file-system edits the explorer performs. Each one registers its inverse
/// with `undoManager`, so Edit ▸ Undo / Redo walk them back and forth: a
/// deletion goes to the Trash and undoing it moves the item back out.
/// Main-thread-only.
@MainActor
final class FileExplorerOperations {
    let undoManager = UndoManager()

    /// Directories whose listing an operation changed, so the tree can reload
    /// them without waiting for the file-system watcher.
    var onDirectoriesChanged: ((Set<URL>) -> Void)?
    /// Undo or redo that could not be applied, typically because the item
    /// was moved or deleted outside the explorer in the meantime.
    var onUndoFailure: ((Error) -> Void)?

    private let fileManager = FileManager.default

    init() {
        undoManager.groupsByEvent = false
    }

    // MARK: - Operations

    @discardableResult
    func createFile(named name: String, in directory: URL) throws -> URL {
        let url = try destination(named: name, in: directory)
        do {
            try Data().write(to: url, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw FileExplorerOperationError.alreadyExists(name)
        } catch {
            throw FileExplorerOperationError.failed(error.localizedDescription)
        }
        record([.trash(url)], actionName: "New File", changed: [directory])
        return url
    }

    @discardableResult
    func createFolder(named name: String, in directory: URL) throws -> URL {
        let url = try destination(named: name, in: directory)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            throw FileExplorerOperationError.alreadyExists(name)
        } catch {
            throw FileExplorerOperationError.failed(error.localizedDescription)
        }
        record([.trash(url)], actionName: "New Folder", changed: [directory])
        return url
    }

    /// Renames in place; never replaces an existing item.
    @discardableResult
    func rename(_ url: URL, to name: String) throws -> URL {
        guard name != url.lastPathComponent else { return url }
        let directory = url.deletingLastPathComponent()
        let isCaseOnlyChange = name.lowercased() == url.lastPathComponent.lowercased()
        // A case-only change may "collide" with the item itself on a
        // case-insensitive volume; performMove tells that apart from a real
        // second item.
        let target = isCaseOnlyChange
            ? directory.appendingPathComponent(name)
            : try destination(named: name, in: directory)
        try performMove(from: url, to: target)
        record([.move(from: target, to: url)], actionName: "Rename", changed: [directory])
        return target
    }

    /// Moves items into `folder` and returns each moved item with its new
    /// location. Items already there are skipped, as are items inside other
    /// moved folders (they travel with them); a folder cannot be moved into
    /// itself or one of its descendants.
    @discardableResult
    func move(_ urls: [URL], into folder: URL) throws -> [(source: URL, target: URL)] {
        let folderPath = folder.standardizedFileURL.path
        var inverse: [Step] = []
        var changed: Set<URL> = [folder]
        var moved: [(source: URL, target: URL)] = []
        defer {
            if !inverse.isEmpty {
                record(Array(inverse.reversed()), actionName: "Move", changed: changed)
            }
        }
        for url in Self.outermost(urls) {
            let sourcePath = url.standardizedFileURL.path
            if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                throw FileExplorerOperationError.moveIntoItself(url.lastPathComponent)
            }
            let parent = url.deletingLastPathComponent()
            guard parent.standardizedFileURL.path != folderPath else { continue }
            let target = try destination(named: url.lastPathComponent, in: folder)
            try performMove(from: url, to: target)
            inverse.append(.move(from: target, to: url))
            changed.insert(parent)
            moved.append((url, target))
        }
        return moved
    }

    /// Copies items dropped from outside the explorer into `folder`, naming
    /// any that collide the way Duplicate does.
    @discardableResult
    func copy(_ urls: [URL], into folder: URL) throws -> [URL] {
        var inverse: [Step] = []
        var copied: [URL] = []
        defer {
            if !inverse.isEmpty {
                record(Array(inverse.reversed()), actionName: "Copy", changed: [folder])
            }
        }
        for url in Self.outermost(urls) {
            var name = url.lastPathComponent
            if exists(folder.appendingPathComponent(name)) {
                name = FileExplorerNaming.duplicateName(for: name) {
                    exists(folder.appendingPathComponent($0))
                }
            }
            let target = folder.appendingPathComponent(name)
            do {
                try fileManager.copyItem(at: url, to: target)
            } catch {
                throw FileExplorerOperationError.failed(error.localizedDescription)
            }
            inverse.append(.trash(target))
            copied.append(target)
        }
        return copied
    }

    /// Copies a file next to itself as "name copy.ext", "name copy 2.ext", ….
    @discardableResult
    func duplicate(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let name = FileExplorerNaming.duplicateName(for: url.lastPathComponent) {
            exists(directory.appendingPathComponent($0))
        }
        let target = directory.appendingPathComponent(name)
        do {
            try fileManager.copyItem(at: url, to: target)
        } catch {
            throw FileExplorerOperationError.failed(error.localizedDescription)
        }
        record([.trash(target)], actionName: "Duplicate", changed: [directory])
        return target
    }

    /// Moves items to the Trash without asking, like Finder's ⌘⌫. Items that
    /// are already gone count as deleted.
    func trash(_ urls: [URL]) throws {
        var inverse: [Step] = []
        var changed: Set<URL> = []
        defer {
            if !inverse.isEmpty {
                record(Array(inverse.reversed()), actionName: "Move to Trash", changed: changed)
            }
        }
        for url in Self.outermost(urls) {
            changed.insert(url.deletingLastPathComponent())
            guard exists(url) else { continue }
            guard let trashed = try? performTrash(url) else {
                throw FileExplorerOperationError.trashFailed(url.lastPathComponent)
            }
            inverse.append(.restore(trashed: trashed, to: url))
        }
    }

    /// `urls` without any item that sits inside another listed folder.
    static func outermost(_ urls: [URL]) -> [URL] {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        return urls.filter { url in
            var parent = (url.standardizedFileURL.path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if paths.contains(parent) {
                    return false
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    // MARK: - Undo

    private enum Step {
        case move(from: URL, to: URL)
        case trash(URL)
        case restore(trashed: URL, to: URL)

        var touchedDirectories: [URL] {
            switch self {
            case .move(let from, let to):
                [from.deletingLastPathComponent(), to.deletingLastPathComponent()]
            case .trash(let url), .restore(_, let url):
                [url.deletingLastPathComponent()]
            }
        }
    }

    /// Registers `inverse` as the undo of the operation that just ran.
    private func record(_ inverse: [Step], actionName: String, changed: Set<URL>) {
        register(inverse, actionName: actionName)
        onDirectoriesChanged?(changed)
    }

    private func register(_ steps: [Step], actionName: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.apply(steps, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Runs undo/redo steps and registers their inverse, which AppKit files on
    /// the opposite stack.
    private func apply(_ steps: [Step], actionName: String) {
        var inverse: [Step] = []
        var changed: Set<URL> = []
        defer {
            if !inverse.isEmpty {
                register(Array(inverse.reversed()), actionName: actionName)
            }
            onDirectoriesChanged?(changed)
        }
        do {
            for step in steps {
                changed.formUnion(step.touchedDirectories)
                switch step {
                case .move(let from, let to):
                    try performMove(from: from, to: to)
                    inverse.append(.move(from: to, to: from))
                case .trash(let url):
                    guard exists(url) else { continue }
                    let trashed = try performTrash(url)
                    inverse.append(.restore(trashed: trashed, to: url))
                case .restore(let trashed, let url):
                    try performMove(from: trashed, to: url)
                    inverse.append(.trash(url))
                }
            }
        } catch {
            onUndoFailure?(error)
        }
    }

    // MARK: - File System

    private func destination(named name: String, in directory: URL) throws -> URL {
        guard Self.isValidName(name) else {
            throw FileExplorerOperationError.invalidName(name)
        }
        let url = directory.appendingPathComponent(name)
        guard !exists(url) else {
            throw FileExplorerOperationError.alreadyExists(name)
        }
        return url
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Whether anything, including a dangling symlink, occupies `url`.
    private func exists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        var lhsInfo = stat()
        var rhsInfo = stat()
        guard lstat(lhs.path, &lhsInfo) == 0, lstat(rhs.path, &rhsInfo) == 0 else {
            return false
        }
        return lhsInfo.st_dev == rhsInfo.st_dev && lhsInfo.st_ino == rhsInfo.st_ino
    }

    /// Moves `source` to `target`, never replacing a different item at
    /// `target`: the one guard for operations, undo, and redo alike.
    private func performMove(from source: URL, to target: URL) throws {
        if source.path.lowercased() == target.path.lowercased() {
            // Case-only change. On a case-insensitive volume the target is the
            // source itself, which FileManager refuses, so rename(2) does it. On
            // a case-sensitive volume the other spelling can be a second item;
            // RENAME_EXCL refuses that atomically, even if it appeared just now.
            let result = isSameItem(source, target)
                ? Darwin.rename(source.path, target.path)
                : renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
            guard result == 0 else {
                if errno == EEXIST {
                    throw FileExplorerOperationError.alreadyExists(target.lastPathComponent)
                }
                throw FileExplorerOperationError.failed(String(cString: strerror(errno)))
            }
            return
        }
        do {
            // Fails rather than replace an existing destination.
            try fileManager.moveItem(at: source, to: target)
        } catch CocoaError.fileWriteFileExists {
            throw FileExplorerOperationError.alreadyExists(target.lastPathComponent)
        } catch {
            throw FileExplorerOperationError.failed(error.localizedDescription)
        }
    }

    private func performTrash(_ url: URL) throws -> URL {
        var trashedURL: NSURL?
        do {
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            throw FileExplorerOperationError.trashFailed(url.lastPathComponent)
        }
        guard let trashedURL = trashedURL as URL? else {
            throw FileExplorerOperationError.trashFailed(url.lastPathComponent)
        }
        return trashedURL
    }
}
