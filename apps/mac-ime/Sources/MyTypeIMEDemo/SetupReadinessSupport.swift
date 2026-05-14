import Foundation
import ASRAdapter
import Common
import Settings

enum LocalModelPack: String, CaseIterable, Sendable {
    case quick
    case recommended

    var requestedModels: [ASRModelSize] {
        switch self {
        case .quick:
            return [.tiny]
        case .recommended:
            return [.tiny, .small]
        }
    }

    var preferredRecognitionModel: ASRModelSize {
        switch self {
        case .quick:
            return .tiny
        case .recommended:
            return .small
        }
    }

    var title: String {
        switch self {
        case .quick:
            return "快速体验"
        case .recommended:
            return "推荐平衡"
        }
    }

    var detail: String {
        switch self {
        case .quick:
            return "下载速度更快，适合先体验。完成后本地识别和实时预览都使用轻量模型。"
        case .recommended:
            return "首次准备稍久一些。实时预览保持轻量，本地正式识别会使用更稳妥的档位。"
        }
    }

    var sizeEstimate: String {
        switch self {
        case .quick:
            return "预计占用较小，通常几分钟内可以准备完成。"
        case .recommended:
            return "预计占用更多空间，通常需要多一点下载时间。"
        }
    }

    var installSummary: String {
        switch self {
        case .quick:
            return "将准备本地识别运行时，并下载快速体验档位。"
        case .recommended:
            return "将准备本地识别运行时，并下载推荐平衡档位。"
        }
    }

    static func fromStored(_ rawValue: String) -> LocalModelPack {
        LocalModelPack(rawValue: rawValue) ?? .recommended
    }

    static func inferred(from installedModels: Set<ASRModelSize>) -> LocalModelPack? {
        if installedModels.contains(.small) {
            return .recommended
        }
        if installedModels.contains(.tiny) {
            return .quick
        }
        return nil
    }
}

enum MyTypeSetupState: String, CaseIterable, Sendable {
    case notStarted
    case inProgress
    case deferred
    case ready

    static func fromStored(_ rawValue: String) -> MyTypeSetupState {
        MyTypeSetupState(rawValue: rawValue) ?? .notStarted
    }
}

struct MyTypeRecognitionRouteReadiness: Sendable {
    let localReady: Bool
    let cloudReady: Bool

    var anyReady: Bool {
        localReady || cloudReady
    }
}

struct CloudRecognitionConfiguration: Sendable {
    let endpoint: String
    let appKey: String
    let apiKey: String
    let resourceID: String
    let model: String

    init(
        endpoint: String,
        appKey: String,
        apiKey: String,
        resourceID: String,
        model: String
    ) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.apiKey = apiKey
        self.resourceID = resourceID
        self.model = model
    }

    init(settings: SettingsStore) {
        self.init(
            endpoint: settings.string(forKey: SettingsKeys.cloudAPIEndpoint, default: ""),
            appKey: settings.string(forKey: SettingsKeys.cloudAPIAppKey, default: ""),
            apiKey: settings.string(forKey: SettingsKeys.cloudAPIKey, default: ""),
            resourceID: settings.string(forKey: SettingsKeys.cloudAPIResourceID, default: ""),
            model: settings.string(forKey: SettingsKeys.cloudAPIModel, default: "")
        )
    }
}

enum MyTypeCloudConfigurationValidator {
    static func validationMessage(
        for configuration: CloudRecognitionConfiguration,
        allowEmptyEndpoint: Bool = false
    ) -> String? {
        let endpointValue = configuration.endpoint.mytypeTrimmed
        if endpointValue.isEmpty {
            return allowEmptyEndpoint ? nil : "请先填写接口 URL。"
        }

        guard let url = URL(string: endpointValue),
              let scheme = url.scheme?.lowercased() else {
            return "接口 URL 格式不正确。请检查是否带了完整的协议头，例如 http://、https:// 或 wss://。"
        }

        if scheme == "ws" || scheme == "wss" {
            guard isDoubaoWebSocketEndpoint(url) else {
                return "当前只有豆包流式接口支持 ws / wss。请填写 openspeech.bytedance.com 下的 /api/v3/sauc/bigmodel 或 bigmodel_async 地址。"
            }
            if configuration.appKey.mytypeTrimmed.isEmpty {
                return "这是豆包流式接口，请填写 APP ID（AppKey）。"
            }
            if configuration.apiKey.mytypeTrimmed.isEmpty {
                return "这是豆包流式接口，请填写 Access Key / API Key。"
            }
            return nil
        }

        guard scheme == "http" || scheme == "https" else {
            return "接口协议暂不支持。当前可用的是 http / https，以及豆包专用的 wss。"
        }

        if isDoubaoHost(url) {
            guard isSupportedDoubaoHTTPPath(url) else {
                return "豆包 HTTP 地址暂只支持 /api/v3/auc/bigmodel/* 或 /api/v3/sauc/bigmodel*。"
            }
            if configuration.appKey.mytypeTrimmed.isEmpty {
                return "这是豆包接口，请填写 APP ID（AppKey）。"
            }
            if configuration.apiKey.mytypeTrimmed.isEmpty {
                return "这是豆包接口，请填写 Access Key / API Key。"
            }
        }

        return nil
    }

    static func isReady(_ configuration: CloudRecognitionConfiguration) -> Bool {
        validationMessage(for: configuration, allowEmptyEndpoint: false) == nil
    }

    private static func isDoubaoWebSocketEndpoint(_ url: URL) -> Bool {
        isDoubaoHost(url)
            && (url.path == "/api/v3/sauc/bigmodel"
                || url.path == "/api/v3/sauc/bigmodel_async")
    }

    private static func isDoubaoHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "openspeech.bytedance.com" || host.hasSuffix(".openspeech.bytedance.com")
    }

    private static func isSupportedDoubaoHTTPPath(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasPrefix("/api/v3/auc/bigmodel/")
            || path == "/api/v3/sauc/bigmodel"
            || path == "/api/v3/sauc/bigmodel_async"
    }
}

enum MyTypeSetupStateResolver {
    static func resolve(
        storedRawValue: String,
        routeReadiness: MyTypeRecognitionRouteReadiness,
        permissionState: MyTypePermissionState,
        legacyLocalPromptHandled: Bool
    ) -> MyTypeSetupState {
        if routeReadiness.anyReady && permissionState.hasAllRequiredPermissions {
            return .ready
        }

        let storedState = MyTypeSetupState(rawValue: storedRawValue)
        switch storedState {
        case .notStarted, .inProgress, .deferred:
            return storedState ?? .notStarted
        case .ready:
            return .deferred
        case nil:
            return legacyLocalPromptHandled ? .deferred : .notStarted
        }
    }
}

private extension String {
    var mytypeTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
