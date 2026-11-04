import Foundation

/// The directory a CLI invocation's relative paths resolve against: the real
/// process working directory, spelled as `$PWD` when `$PWD` names that same
/// directory (it keeps the symlinked path the shell shows). `$PWD` is only
/// inherited, so a subprocess spawned with another cwd still carries its
/// parent's value and must not win.
enum CallerWorkingDirectory {
    static func resolve(
        environment: [String: String],
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> String {
        guard let pwd = environment["PWD"], pwd.hasPrefix("/"),
              let pwdIdentity = fileIdentity(pwd),
              pwdIdentity == fileIdentity(currentDirectoryPath)
        else { return currentDirectoryPath }
        return pwd
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
