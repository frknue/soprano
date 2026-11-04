import AppKit
import SopranoAgentsCore

/// Opens a workspace's Git repository in Soprano Git, the family's Git client, like Soprano's
/// Prefix → G: the repository root goes over the way Finder and `open -a` hand folders to it, and a
/// repository Soprano Git already shows just gets its tab selected there.
@MainActor
enum AgentsSopranoGitLauncher {
    static let bundleIdentifier = "com.soprano.git"
    private static let title = "Open in Soprano Git"

    static func installedApplication() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Opens `ref`'s repository, or explains in a dialog over `window` why it can't.
    static func open(_ ref: WorkspaceRef, engine: AgentEngine, window: NSWindow?) async {
        guard let application = installedApplication() else {
            await Dialogs.alert(title: title, message: "Soprano Git isn't installed.", in: window)
            return
        }
        guard let root = await engine.repositoryRoot(of: ref) else {
            let folder = engine.workingDirectory(of: ref).map { ($0 as NSString).abbreviatingWithTildeInPath }
            await Dialogs.alert(title: title, message: "\(folder ?? "This workspace") is not inside a Git repository.", in: window)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let repository = URL(fileURLWithPath: root, isDirectory: true)
        NSWorkspace.shared.open([repository], withApplicationAt: application, configuration: configuration) { _, error in
            guard let error else { return }
            let message = "Soprano Git could not open \(root): \(error.localizedDescription)"
            Task { @MainActor in
                await Dialogs.alert(title: title, message: message, in: window)
            }
        }
    }
}
