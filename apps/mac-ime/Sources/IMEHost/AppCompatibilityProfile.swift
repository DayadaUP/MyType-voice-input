import Foundation

public enum AppCompatibilityProfile: String, Sendable {
    case generic
    case browser
    case notion
    case wechat
    case electronLike
    case iPhoneMirroring
}

public enum AppCompatibilityResolver {
    public static func resolve(bundleID: String?, appName: String?) -> AppCompatibilityProfile {
        let bundle = bundleID?.lowercased() ?? ""
        let name = appName?.lowercased() ?? ""

        if bundle.contains("iphonemirroring") || bundle.contains("iphone-mirroring")
            || name.contains("iphone mirroring") || name.contains("iphone 镜像") {
            return .iPhoneMirroring
        }

        if bundle == "com.apple.safari"
            || bundle == "com.google.chrome"
            || bundle == "com.microsoft.edgemac"
            || bundle == "com.brave.browser"
            || bundle == "company.thebrowser.browser"
            || bundle.contains("firefox")
            || bundle.contains("browser")
            || name.contains("chrome")
            || name.contains("safari")
            || name.contains("edge")
            || name.contains("brave")
            || name.contains("firefox")
            || name.contains("arc") {
            return .browser
        }

        if bundle.contains("notion") || name.contains("notion") {
            return .notion
        }

        if bundle.contains("xinwechat") || bundle.contains("wechat") || name.contains("微信") || name.contains("wechat") {
            return .wechat
        }

        if bundle.contains("codex")
            || bundle.contains("electron")
            || bundle.contains("slack")
            || bundle.contains("discord")
            || name.contains("codex")
            || name.contains("slack")
            || name.contains("discord") {
            return .electronLike
        }

        return .generic
    }
}
