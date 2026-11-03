import CmuxSettings
import Foundation
import Testing

/// Behavior tests for ``ManagedDevicePolicyBypass``: only DEV bundle
/// identifiers honor the launch argument or the `cmux.json` key, and an
/// active bypass makes ``ManagedDevicePolicy`` answer as if no profile were
/// installed.
struct ManagedDevicePolicyBypassTests {
    private static let forcedMirrorPrefix = "forced."

    private static let probe: ManagedDevicePolicy.ForcedObjectProbe = { defaults, key in
        defaults.object(forKey: forcedMirrorPrefix + key)
    }

    private static let launchArgs = ["/Applications/cmux.app/Contents/MacOS/cmux", ManagedDevicePolicyBypass.launchArgument]
    private static let plainArgs = ["/Applications/cmux.app/Contents/MacOS/cmux"]

    private func makeSuite(_ label: String) throws -> (UserDefaults, () -> Void) {
        let suiteName = "ManagedDevicePolicyBypassTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test(arguments: ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.my-tag", " COM.CMUXTERM.APP.DEBUG.Tag "])
    func devBundlesHonorTheLaunchArgument(bundleIdentifier: String) {
        let bypass = ManagedDevicePolicyBypass.resolve(
            bundleIdentifier: bundleIdentifier,
            arguments: Self.launchArgs,
            configFileRequestsBypass: { false }
        )
        #expect(bypass.source == .launchArgument)
        #expect(bypass.isActive)
    }

    @Test func devBundlesHonorTheConfigFileKey() {
        let bypass = ManagedDevicePolicyBypass.resolve(
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            arguments: Self.plainArgs,
            configFileRequestsBypass: { true }
        )
        #expect(bypass.source == .configFile)
    }

    @Test func devBundleWithoutEitherInputStaysEnforced() {
        let bypass = ManagedDevicePolicyBypass.resolve(
            bundleIdentifier: "com.cmuxterm.app.debug",
            arguments: Self.plainArgs,
            configFileRequestsBypass: { false }
        )
        #expect(bypass == .inactive)
    }

    @Test(arguments: [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.my-tag",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.staging",
        "com.cmuxterm.app.staging.my-tag",
        "com.cmuxterm.app.debugger",
        "com.example.debug",
    ])
    func shippedAndForeignBundlesIgnoreBothInputs(bundleIdentifier: String) {
        var configRead = false
        let bypass = ManagedDevicePolicyBypass.resolve(
            bundleIdentifier: bundleIdentifier,
            arguments: Self.launchArgs,
            configFileRequestsBypass: { configRead = true; return true }
        )
        #expect(bypass == .inactive)
        #expect(!configRead, "non-DEV builds must not read cmux.json for the bypass")
    }

    @Test func missingBundleIdentifierIgnoresBothInputs() {
        let bypass = ManagedDevicePolicyBypass.resolve(
            bundleIdentifier: nil,
            arguments: Self.launchArgs,
            configFileRequestsBypass: { true }
        )
        #expect(bypass == .inactive)
    }

    @Test func argumentInExecutablePositionDoesNotCount() {
        let bypass = ManagedDevicePolicyBypass.resolve(
            bundleIdentifier: "com.cmuxterm.app.debug",
            arguments: [ManagedDevicePolicyBypass.launchArgument],
            configFileRequestsBypass: { false }
        )
        #expect(bypass == .inactive)
    }

    @Test func configKeyIsReadFromCmuxJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bypass-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("cmux.json")
        let store = JSONConfigStore(fileURL: fileURL)
        let key = AppCatalogSection().ignoreManagedPolicy

        #expect(key.id == "app.ignoreManagedPolicy")
        #expect(store.snapshotValue(for: key) == false)

        try Data(#"{ /* dev */ "app": { "ignoreManagedPolicy": true } }"#.utf8).write(to: fileURL)
        #expect(store.snapshotValue(for: key) == true)
    }

    @Test func activeBypassMakesEveryForcedValueUnmanaged() throws {
        let (appDefaults, cleanupApp) = try makeSuite("app")
        defer { cleanupApp() }
        let (releaseDefaults, cleanupRelease) = try makeSuite("release")
        defer { cleanupRelease() }

        // A profile forces policies in both the app's own domain and the
        // release fallback domain.
        appDefaults.set(true, forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.disableCloud.rawValue)
        releaseDefaults.set(true, forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.disableRemoteControl.rawValue)
        releaseDefaults.set(false, forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.browserAllowLocalhost.rawValue)
        releaseDefaults.set(["https://example.com"], forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.browserURLAllowlist.rawValue)

        let enforced = ManagedDevicePolicy(
            defaults: appDefaults,
            releaseDomainDefaults: releaseDefaults,
            forcedObject: Self.probe,
            ignoresForcedValues: false
        )
        #expect(enforced.isEnforced(.disableCloud))
        #expect(enforced.isEnforced(.disableRemoteControl))
        #expect(enforced.isDeviceDiscoveryDisabled)
        #expect(!enforced.isAllowed(.browserAllowLocalhost))
        #expect(enforced.isForced(.browserURLAllowlist))

        let bypassed = ManagedDevicePolicy(
            defaults: appDefaults,
            releaseDomainDefaults: releaseDefaults,
            forcedObject: Self.probe,
            ignoresForcedValues: true
        )
        #expect(!bypassed.isEnforced(.disableCloud))
        #expect(!bypassed.isEnforced(.disableRemoteControl))
        #expect(!bypassed.isDeviceDiscoveryDisabled)
        #expect(!bypassed.isIncomingDeviceAccessDisabled)
        #expect(bypassed.isAllowed(.browserAllowLocalhost))
        #expect(!bypassed.isForced(.browserURLAllowlist))
        #expect(bypassed.forcedValueSource(forUserDefaultsKey: ManagedDevicePolicyKey.disableCloud.rawValue) == nil)
        #expect(!bypassed.isBrowserURLAllowlistLocked(userDefaultsKey: "browserURLAllowlist"))

        // The OS still returns forced values from the app's own domain, so
        // write suppression keeps reporting them.
        #expect(bypassed.isKeyForcedInAppDomain(ManagedDevicePolicyKey.disableCloud.rawValue))
    }

    @Test func testProcessIsNotABypassedDevBundle() {
        // Guards the default argument: tests (and the shipped app) must not
        // silently run with the bypass on.
        #expect(!ManagedDevicePolicyBypass.current.isActive)
    }
}
