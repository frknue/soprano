import Foundation

// Parsed unified diffs (the right panel renders them) and git errors.
// Everything is Sendable so results cross from git's background tasks to the
// main actor unchanged.

// MARK: - Diffs

public enum ChangeKind: String, Sendable, Hashable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
    case untracked = "?"
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case added
        case removed
        /// "\ No newline at end of file", attached to the line before it.
        case noNewlineMarker
    }

    public var kind: Kind
    /// Line text without the leading +/-/space and without the newline.
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the closing "@@" (usually the enclosing function), may be empty.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

public struct FileDiff: Sendable, Hashable {
    /// nil when the old side is /dev/null (added file).
    public var oldPath: String?
    /// nil when the new side is /dev/null (deleted file).
    public var newPath: String?
    public var kind: ChangeKind
    public var isBinary: Bool
    public var oldMode: String?
    public var newMode: String?
    /// Raw header lines from "diff --git" through "+++".
    public var headerLines: [String]
    public var hunks: [DiffHunk]

    public var path: String { newPath ?? oldPath ?? "" }

    public init(
        oldPath: String?, newPath: String?, kind: ChangeKind, isBinary: Bool, oldMode: String? = nil,
        newMode: String? = nil, headerLines: [String], hunks: [DiffHunk]
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.isBinary = isBinary
        self.oldMode = oldMode
        self.newMode = newMode
        self.headerLines = headerLines
        self.hunks = hunks
    }
}

// MARK: - Errors

/// A git invocation that exited with a status outside its accepted set.
public struct GitError: Error, Sendable, Hashable, LocalizedError {
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(arguments: [String], exitCode: Int32, stdout: String, stderr: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("index.lock") {
            return "Git's index is locked. Wait for other Git operations to finish, then try again."
        }
        if !message.isEmpty { return message }
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        return "git \(arguments.first ?? "") exited with status \(exitCode)"
    }
}

public enum GitSetupError: Error, Sendable, Hashable, LocalizedError {
    /// No usable git executable was found.
    case gitNotFound
    /// The path is not inside a git worktree.
    case notARepository(String)
    /// git (or gh) could not be launched.
    case launchFailed(String)
    /// gh did not answer in time.
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "No git executable found. Install Git with Homebrew or the Xcode Command Line Tools."
        case let .notARepository(path):
            "\(path) is not a git repository."
        case let .launchFailed(reason):
            "Could not run git: \(reason)"
        case let .timedOut(command):
            "\(command) did not finish in time."
        }
    }
}

/// A git action that cannot run in the repository's current state; the message is shown as is.
public struct GitActionError: Error, Sendable, Hashable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
