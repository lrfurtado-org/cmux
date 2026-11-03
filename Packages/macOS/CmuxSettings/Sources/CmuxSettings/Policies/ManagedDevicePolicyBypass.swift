import Foundation

/// A developer opt-out that makes ``ManagedDevicePolicy`` ignore
/// configuration-profile (MDM) values in DEV builds.
///
/// Channel builds also honor profiles that target the release payload domain
/// (``ManagedDevicePolicy/releasePayloadDomain``). On an MDM-enrolled Mac,
/// that means a tagged dev build inherits the organization's policies, so
/// managed features can't be worked on locally. The bypass lets such a
/// developer opt out with either:
///
/// - the launch argument ``launchArgument`` (`--ignore-managed-policy`), or
/// - `"app": { "ignoreManagedPolicy": true }` in `~/.config/cmux/cmux.json`
///   (``AppCatalogSection/ignoreManagedPolicy``).
///
/// It only takes effect when the bundle identifier is a DEV one
/// (`com.cmuxterm.app.debug` or `com.cmuxterm.app.debug.<tag>`). Stable,
/// nightly, rc, and staging builds ignore both inputs, so the bypass can't
/// weaken enforcement in a shipped app.
///
/// The bypass is resolved once per process (``current``). Changing the
/// config key takes effect at the next launch.
public struct ManagedDevicePolicyBypass: Sendable, Equatable {
    /// The launch argument that requests the bypass.
    public static let launchArgument = "--ignore-managed-policy"

    /// What requested an active bypass.
    public enum Source: String, Sendable, Equatable {
        /// ``ManagedDevicePolicyBypass/launchArgument`` was on the command line.
        case launchArgument
        /// `app.ignoreManagedPolicy` was `true` in `cmux.json`.
        case configFile
    }

    /// The input that activated the bypass, or `nil` when it is inactive.
    public let source: Source?

    /// Whether ``ManagedDevicePolicy`` ignores profile-forced values.
    public var isActive: Bool { source != nil }

    /// An inactive bypass: managed policies are enforced normally.
    public static let inactive = ManagedDevicePolicyBypass(source: nil)

    /// Creates a bypass state directly. Prefer ``resolve(bundleIdentifier:arguments:configFileRequestsBypass:)``.
    ///
    /// - Parameter source: The activating input, or `nil` for inactive.
    public init(source: Source?) {
        self.source = source
    }

    /// The bypass state for the running process, resolved on first use from
    /// `Bundle.main`, the process arguments, and the user's `cmux.json`.
    public static let current: ManagedDevicePolicyBypass = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        arguments: ProcessInfo.processInfo.arguments,
        configFileRequestsBypass: {
            JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
                .snapshotValue(for: AppCatalogSection().ignoreManagedPolicy)
        }
    )

    /// Resolves the bypass from explicit inputs.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The running app's bundle identifier. Anything
    ///     other than a DEV identifier makes the bypass inactive.
    ///   - arguments: The process arguments, checked for ``launchArgument``.
    ///   - configFileRequestsBypass: Reads `app.ignoreManagedPolicy` from
    ///     `cmux.json`. It runs only for a DEV bundle without the launch
    ///     argument, so other builds never read the file for this.
    /// - Returns: The resolved bypass state.
    public static func resolve(
        bundleIdentifier: String?,
        arguments: [String],
        configFileRequestsBypass: () -> Bool
    ) -> ManagedDevicePolicyBypass {
        let normalized = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard SocketControlSettings.isDebugLikeBundleIdentifier(normalized) else {
            return .inactive
        }
        if arguments.dropFirst().contains(launchArgument) {
            return ManagedDevicePolicyBypass(source: .launchArgument)
        }
        if configFileRequestsBypass() {
            return ManagedDevicePolicyBypass(source: .configFile)
        }
        return .inactive
    }
}
