import Foundation

/// The application's marketing version.
///
/// `Support/Info.plist` is the single source of truth. The packaged bundle carries
/// `CFBundleShortVersionString`, and everything that displays a version reads it from
/// there, so cutting a release only has to touch the plist and `CHANGELOG.md`.
enum AppVersion {
    /// Reported when running unbundled (`swift run`), where there is no `Info.plist`.
    static let unbundled = "dev"

    /// Marketing version of the running app.
    static var current: String {
        resolve(from: Bundle.main.infoDictionary)
    }

    /// Marketing version carried by an info dictionary, or ``unbundled`` when it is
    /// missing or blank.
    static func resolve(from infoDictionary: [String: Any]?) -> String {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return unbundled
        }

        return version
    }
}
