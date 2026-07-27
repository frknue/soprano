import Testing
import AppKit
@testable import Soprano

struct PackagedResourceLookupTests {
    @Test func swiftPMResourcesResolveInsideThePackagedAppsResourcesDirectory() {
        let resourcesURL = URL(
            fileURLWithPath: "/Applications/Soprano.app/Contents/Resources",
            isDirectory: true
        )

        let bundleURL = SopranoResources.packagedBundleURL(
            resourcesURL: resourcesURL,
            fileExists: { _ in true }
        )

        #expect(bundleURL?.path == "/Applications/Soprano.app/Contents/Resources/Soprano_Soprano.bundle")
    }

    @Test func packagedResourceBundleIsUnavailableWithoutAppResources() {
        #expect(SopranoResources.packagedBundleURL(resourcesURL: nil) == nil)
    }
}
