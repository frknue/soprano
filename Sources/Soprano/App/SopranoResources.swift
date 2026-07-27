import Foundation

enum SopranoResources {
    static let bundle: Bundle = {
        if let bundleURL = packagedBundleURL(resourcesURL: Bundle.main.resourceURL),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }

        return Bundle.module
    }()

    static func packagedBundleURL(
        resourcesURL: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        guard let resourcesURL else { return nil }
        let bundleURL = resourcesURL.appendingPathComponent(
            "Soprano_Soprano.bundle",
            isDirectory: true
        )
        return fileExists(bundleURL) ? bundleURL : nil
    }
}
