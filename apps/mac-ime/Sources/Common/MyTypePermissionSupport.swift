import Foundation

public enum MyTypeSettingsDomain {
    public static let suiteName = "com.daya.mytype.settings"
    public static let namespace = "mytype.demo"
}

public struct MyTypePermissionState: Equatable, Sendable {
    public let accessibilityTrusted: Bool
    public let listenEventTrusted: Bool
    public let microphoneAuthorized: Bool

    public init(
        accessibilityTrusted: Bool,
        listenEventTrusted: Bool,
        microphoneAuthorized: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.listenEventTrusted = listenEventTrusted
        self.microphoneAuthorized = microphoneAuthorized
    }

    public var canUseVoiceInput: Bool {
        accessibilityTrusted && microphoneAuthorized
    }

    public var canUseGlobalShortcut: Bool {
        listenEventTrusted
    }

    public var hasAllRequiredPermissions: Bool {
        accessibilityTrusted && listenEventTrusted && microphoneAuthorized
    }
}

public enum MyTypeInstallationIdentity {
    public static func permissionPromptToken(
        bundleIdentifier: String?,
        executablePath: String?
    ) -> String {
        let normalizedBundleIdentifier = normalizedBundleIdentifier(bundleIdentifier)
        let normalizedExecutablePath = normalizedExecutablePath(executablePath)
        return "\(normalizedBundleIdentifier)|\(normalizedExecutablePath)"
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown.bundle" : trimmed.lowercased()
    }

    private static func normalizedExecutablePath(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "unknown-executable" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
