import Foundation
import Testing
@testable import IMEHost

@Test("resolver maps high frequency apps to expected profiles")
func resolverMapsHighFrequencyApps() {
    #expect(
        AppCompatibilityResolver.resolve(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome"
        ) == .browser
    )
    #expect(
        AppCompatibilityResolver.resolve(
            bundleID: "notion.id",
            appName: "Notion"
        ) == .notion
    )
    #expect(
        AppCompatibilityResolver.resolve(
            bundleID: "com.tencent.xinWeChat",
            appName: "微信"
        ) == .wechat
    )
    #expect(
        AppCompatibilityResolver.resolve(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack"
        ) == .electronLike
    )
    #expect(
        AppCompatibilityResolver.resolve(
            bundleID: "com.apple.iPhoneMirroring",
            appName: "iPhone Mirroring"
        ) == .iPhoneMirroring
    )
}

@Test("compatibility insertion presets remain conservative for high frequency apps")
func compatibilityInsertionPresetsStayConservative() {
    let browser = TextInsertionOptions.compatibilityPreset(.browser)
    #expect(browser.pasteAttempts == 2)
    #expect(browser.prePasteDelay >= 0.05)
    #expect(browser.stopRetryWhenTextChanged)

    let notion = TextInsertionOptions.compatibilityPreset(.notion)
    #expect(notion.pasteAttempts == 2)
    #expect(notion.prePasteDelay >= 0.06)
    #expect(notion.postPasteSettleDelay >= 0.12)

    let wechat = TextInsertionOptions.compatibilityPreset(.wechat)
    #expect(wechat.pasteAttempts == 1)
    #expect(wechat.prePasteDelay >= 0.08)

    let mirror = TextInsertionOptions.compatibilityPreset(.iPhoneMirroring)
    #expect(mirror.pasteAttempts == 1)
    #expect(mirror.restoreDelay >= 20.0)
}
