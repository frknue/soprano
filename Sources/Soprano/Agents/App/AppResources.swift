import Foundation

/// The SPM resource bundle (`AppIcon.icns`), for the Dock icon fallback when
/// the app runs outside a packaged `.app`.
enum AppResources {
    static let bundleName = "SopranoAgents_SopranoAgents.bundle"

    /// The SPM resource bundle inside the packaged app, else `Bundle.module`
    /// when running from `.build` (swift run, tests).
    static let bundle: Bundle = {
        if let url = packagedBundleURL(resourcesURL: Bundle.main.resourceURL), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func packagedBundleURL(
        resourcesURL: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        guard let resourcesURL else { return nil }
        let url = resourcesURL.appendingPathComponent(bundleName, isDirectory: true)
        return fileExists(url) ? url : nil
    }
}
