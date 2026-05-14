import Foundation
import Testing
@testable import Common

@Test("permission state separates voice input readiness from global shortcut readiness")
func permissionStateSeparatesVoiceInputAndShortcutReadiness() {
    let accessibilityDenied = MyTypePermissionState(
        accessibilityTrusted: false,
        listenEventTrusted: true,
        microphoneAuthorized: true
    )
    #expect(!accessibilityDenied.canUseVoiceInput)
    #expect(accessibilityDenied.canUseGlobalShortcut)
    #expect(!accessibilityDenied.hasAllRequiredPermissions)

    let listenDenied = MyTypePermissionState(
        accessibilityTrusted: true,
        listenEventTrusted: false,
        microphoneAuthorized: true
    )
    #expect(listenDenied.canUseVoiceInput)
    #expect(!listenDenied.canUseGlobalShortcut)
    #expect(!listenDenied.hasAllRequiredPermissions)

    let allGranted = MyTypePermissionState(
        accessibilityTrusted: true,
        listenEventTrusted: true,
        microphoneAuthorized: true
    )
    #expect(allGranted.canUseVoiceInput)
    #expect(allGranted.canUseGlobalShortcut)
    #expect(allGranted.hasAllRequiredPermissions)

    let microphoneDenied = MyTypePermissionState(
        accessibilityTrusted: true,
        listenEventTrusted: true,
        microphoneAuthorized: false
    )
    #expect(!microphoneDenied.canUseVoiceInput)
    #expect(microphoneDenied.canUseGlobalShortcut)
    #expect(!microphoneDenied.hasAllRequiredPermissions)
}

@Test("installation prompt token changes across install paths")
func installationPromptTokenTracksExecutableIdentity() {
    let xcodeToken = MyTypeInstallationIdentity.permissionPromptToken(
        bundleIdentifier: "com.daya.mytype.demo",
        executablePath: "/Users/daya/Library/Developer/Xcode/DerivedData/MyType/Build/Products/Debug/MyType.app/Contents/MacOS/MyTypeIMEDemo"
    )
    let applicationsToken = MyTypeInstallationIdentity.permissionPromptToken(
        bundleIdentifier: "com.daya.mytype.demo",
        executablePath: "/Applications/MyType.app/Contents/MacOS/MyTypeIMEDemo"
    )
    #expect(xcodeToken != applicationsToken)
}

@Test("installation prompt token normalizes equivalent paths")
func installationPromptTokenNormalizesPath() {
    let normalized = MyTypeInstallationIdentity.permissionPromptToken(
        bundleIdentifier: "com.daya.mytype.demo",
        executablePath: "/Applications/MyType.app/Contents/MacOS/MyTypeIMEDemo"
    )
    let withTraversal = MyTypeInstallationIdentity.permissionPromptToken(
        bundleIdentifier: "COM.DAYA.MYTYPE.DEMO",
        executablePath: "/Applications/../Applications/MyType.app/Contents/MacOS/MyTypeIMEDemo"
    )
    #expect(normalized == withTraversal)
}
