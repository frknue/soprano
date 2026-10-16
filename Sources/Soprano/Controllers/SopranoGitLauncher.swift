import AppKit

/// Opens the active terminal tab's Git repository in Soprano Git, the family's
/// Git client. Soprano Git takes folders the way Finder and `open -a` hand them
/// over, so this resolves the repository root here and passes that on; a
/// repository Soprano Git already shows just gets its tab selected there.
enum SopranoGitLauncher {
    static let bundleIdentifier = "com.soprano.git"

    enum Plan: Equatable {
        case open(repository: URL, application: URL)
        case noWorkingDirectory
        case notInstalled
        case notARepository(String)
    }

    /// What opening `workingDirectory` would do. `application` locates the
    /// installed Soprano Git; tests pass their own.
    static func plan(
        workingDirectory: String?,
        application: () -> URL? = installedApplication
    ) -> Plan {
        guard let workingDirectory, !workingDirectory.isEmpty else { return .noWorkingDirectory }
        guard let applicationURL = application() else { return .notInstalled }
        let directory = (workingDirectory as NSString).expandingTildeInPath
        guard let root = GitBranchMonitor.repositoryRoot(startingAt: directory) else {
            return .notARepository(directory)
        }
        return .open(repository: URL(fileURLWithPath: root, isDirectory: true), application: applicationURL)
    }

    static func installedApplication() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Why nothing opens, for every plan that doesn't open anything.
    static func explanation(for plan: Plan) -> String? {
        switch plan {
        case .open:
            nil
        case .noWorkingDirectory:
            "The active tab has no folder. Focus a terminal inside a Git repository and try again."
        case .notInstalled:
            "Soprano Git isn't installed."
        case let .notARepository(directory):
            "\((directory as NSString).abbreviatingWithTildeInPath) is not inside a Git repository."
        }
    }

    /// Opens the repository, or reports why it can't through `report`.
    @MainActor
    static func open(workingDirectory: String?, report: @escaping @MainActor (String) -> Void) {
        let plan = plan(workingDirectory: workingDirectory)
        guard case let .open(repository, application) = plan else {
            if let message = explanation(for: plan) { report(message) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([repository], withApplicationAt: application, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                report("Soprano Git could not open \(repository.path): \(error.localizedDescription)")
            }
        }
    }
}
