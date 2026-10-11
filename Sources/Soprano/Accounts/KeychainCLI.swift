import Foundation

enum KeychainError: LocalizedError {
    case commandFailed(String)
    case writeNotStored(service: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "Keychain: \(message)"
        case .writeNotStored(let service):
            return "Keychain: could not store the login in \"\(service)\"."
        }
    }
}

/// Generic-password items through `/usr/bin/security`.
///
/// Claude Code creates its credential item with `security`, so the item's
/// access list trusts that tool: going through it, Soprano reads and updates
/// the item without a Keychain prompt — and a rebuilt (re-signed) Soprano does
/// not lose access to the items it created itself.
struct KeychainCLI: Sendable {
    var runner = CommandRunner()
    var executable = "/usr/bin/security"

    /// `errSecItemNotFound`, which `security` exits with for a missing item.
    private static let notFoundStatus: Int32 = 44

    /// The item's secret, or nil when there is no such item.
    func read(service: String, account: String) async throws -> String? {
        let result = try await runner.run(
            executable: executable,
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            timeout: 15
        )
        if result.status == Self.notFoundStatus { return nil }
        guard result.succeeded else { throw KeychainError.commandFailed(result.failureMessage) }
        var output = result.stdout
        if output.hasSuffix("\n") { output.removeLast() }
        return Self.decodedSecret(output)
    }

    /// Creates or replaces the item. The secret goes in on stdin through
    /// `security -i`, hex-encoded the way Claude Code writes it, so it never
    /// shows up in a process listing.
    func write(service: String, account: String, secret: String) async throws {
        let command = Self.addCommand(service: service, account: account, secret: secret)
        let result = try await runner.run(
            executable: executable,
            arguments: ["-i"],
            input: Data(command.utf8),
            timeout: 15
        )
        // `security -i` reports a failed command on stderr but can still exit
        // 0, so the only proof of a write is reading the item back.
        guard try await read(service: service, account: account) == secret else {
            if !result.stderr.isEmpty {
                throw KeychainError.commandFailed(result.failureMessage)
            }
            throw KeychainError.writeNotStored(service: service)
        }
    }

    /// Deletes the item; a missing item is not an error.
    func delete(service: String, account: String) async throws {
        let result = try await runner.run(
            executable: executable,
            arguments: ["delete-generic-password", "-s", service, "-a", account],
            timeout: 15
        )
        guard result.succeeded || result.status == Self.notFoundStatus else {
            throw KeychainError.commandFailed(result.failureMessage)
        }
    }

    /// The `security -i` line that stores `secret`. Service and account are
    /// Soprano's own constants, the macOS user name, or UUIDs; none can
    /// contain a quote, so plain double-quoting is safe.
    static func addCommand(service: String, account: String, secret: String) -> String {
        precondition(!service.contains("\"") && !account.contains("\""))
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
    }

    /// `security -w` prints a secret that is not plain printable ASCII — JSON
    /// holding an organization name with an umlaut, say — as hex.
    static func decodedSecret(_ output: String) -> String {
        guard !output.isEmpty,
              output.count.isMultiple(of: 2),
              output.allSatisfy(\.isHexDigit)
        else { return output }
        var bytes = Data(capacity: output.count / 2)
        var index = output.startIndex
        while index < output.endIndex {
            let next = output.index(index, offsetBy: 2)
            guard let byte = UInt8(output[index..<next], radix: 16) else { return output }
            bytes.append(byte)
            index = next
        }
        guard let text = String(data: bytes, encoding: .utf8),
              text.first == "{" || text.first == "["
        else { return output }
        return text
    }
}
