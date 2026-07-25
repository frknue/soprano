import Testing
@testable import Soprano

struct AppVersionTests {
    @Test func theMarketingVersionComesFromTheBundleInfoDictionary() {
        #expect(AppVersion.resolve(from: ["CFBundleShortVersionString": "1.4.2"]) == "1.4.2")
    }

    @Test func anUnbundledLaunchWithoutAnInfoDictionaryReportsTheDevelopmentVersion() {
        #expect(AppVersion.resolve(from: nil) == AppVersion.unbundled)
    }

    @Test func aMissingOrBlankVersionKeyReportsTheDevelopmentVersion() {
        #expect(AppVersion.resolve(from: [:]) == AppVersion.unbundled)
        #expect(AppVersion.resolve(from: ["CFBundleShortVersionString": "   "]) == AppVersion.unbundled)
    }

    @Test func aNonStringVersionValueReportsTheDevelopmentVersion() {
        #expect(AppVersion.resolve(from: ["CFBundleShortVersionString": 2]) == AppVersion.unbundled)
    }
}
