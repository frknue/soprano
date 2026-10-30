import Foundation

/// Finds the agent CLIs and builds the environment their processes run with.
///
/// GUI apps start with launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so the
/// inherited PATH is extended with the directories installers put `codex` and `claude` in:
/// `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.cargo/bin`,
/// `~/.npm-global/bin`. Children get the same extended PATH so the CLIs find node, git, etc.
public enum ExecutableLocator {
    /// Extra tool directories, in search order after the inherited PATH.
    public static func toolDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
        ]
    }

    /// The inherited PATH followed by `toolDirectories`, without duplicates or empty entries.
    public static func searchPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String] {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (inherited + toolDirectories(home: home)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Resolves `name`. An explicit path (settings `providers.codexPath` / `claudePath`, `~`
    /// expanded) wins and is never second-guessed: nil when it is not an executable file.
    /// Without one, the first executable `name` on `searchPath`.
    public static func locate(
        _ name: String,
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        let fileManager = FileManager.default
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = expandTilde(explicitPath.trimmingCharacters(in: .whitespaces), home: home)
            return isExecutableFile(expanded, fileManager: fileManager) ? expanded : nil
        }
        for directory in searchPath(environment: environment, home: home) {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isExecutableFile(candidate, fileManager: fileManager) { return candidate }
        }
        return nil
    }

    /// `base` with PATH replaced by `searchPath`, plus `overrides`.
    public static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = searchPath(environment: base, home: home).joined(separator: ":")
        for (key, value) in overrides { environment[key] = value }
        return environment
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    private static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }
}
