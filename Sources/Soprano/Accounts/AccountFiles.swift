import Foundation

enum AccountFileError: LocalizedError {
    case unreadable(String)
    case writeFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "\(path) is not valid JSON; Soprano left it untouched."
        case .writeFailed(let path, let reason):
            return "Could not write \(path): \(reason)"
        }
    }
}

/// File and JSON helpers for the login files of other tools, which must never
/// be half-written, world-readable, or replaced when they are symlinks.
enum AccountFiles {
    /// Replaces `url`'s contents atomically. The temporary file is created with
    /// `permissions` before any byte is written, so a credential file is never
    /// readable by others, not even briefly. A symlink is written through, not
    /// replaced, so dotfile-managed configs stay linked.
    static func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        let target = url.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).soprano-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard descriptor >= 0 else {
            throw AccountFileError.writeFailed(url.path, String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw AccountFileError.writeFailed(url.path, error.localizedDescription)
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw AccountFileError.writeFailed(url.path, reason)
        }
    }

    /// The JSON object in `url`; nil when the file does not exist. Throws when
    /// it exists but is not a JSON object, so a caller never mistakes a file
    /// it cannot read for an empty one and overwrites it.
    static func jsonObject(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AccountFileError.unreadable(url.path) }
        return object
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jsonData(_ object: [String: Any], pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    static func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try jsonData(object), as: UTF8.self)
    }

    /// The claims of a JWT, without verifying it: only used to read who a
    /// token says it belongs to and when it expires.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
