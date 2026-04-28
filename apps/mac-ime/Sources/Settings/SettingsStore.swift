import Foundation

public protocol SettingsStore {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool
    func string(forKey key: String, default defaultValue: String) -> String
    func stringArray(forKey key: String, default defaultValue: [String]) -> [String]
    func set(_ value: Bool, forKey key: String)
    func set(_ value: String, forKey key: String)
    func set(_ value: [String], forKey key: String)
}

public final class InMemorySettingsStore: SettingsStore {
    private var boolStorage: [String: Bool] = [:]
    private var stringStorage: [String: String] = [:]
    private var listStorage: [String: [String]] = [:]

    public init() {}

    public func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        boolStorage[key] ?? defaultValue
    }

    public func string(forKey key: String, default defaultValue: String) -> String {
        stringStorage[key] ?? defaultValue
    }

    public func stringArray(forKey key: String, default defaultValue: [String]) -> [String] {
        listStorage[key] ?? defaultValue
    }

    public func set(_ value: Bool, forKey key: String) {
        boolStorage[key] = value
    }

    public func set(_ value: String, forKey key: String) {
        stringStorage[key] = value
    }

    public func set(_ value: [String], forKey key: String) {
        listStorage[key] = value
    }
}

public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let namespace: String

    public init(defaults: UserDefaults = .standard, namespace: String = "mytype") {
        self.defaults = defaults
        self.namespace = namespace
    }

    public func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        let fullKey = namespaced(key)
        if defaults.object(forKey: fullKey) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: fullKey)
    }

    public func string(forKey key: String, default defaultValue: String) -> String {
        defaults.string(forKey: namespaced(key)) ?? defaultValue
    }

    public func stringArray(forKey key: String, default defaultValue: [String]) -> [String] {
        defaults.stringArray(forKey: namespaced(key)) ?? defaultValue
    }

    public func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: namespaced(key))
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: namespaced(key))
    }

    public func set(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: namespaced(key))
    }

    package func hasStoredValue(forKey key: String) -> Bool {
        defaults.object(forKey: namespaced(key)) != nil
    }

    private func namespaced(_ key: String) -> String {
        "\(namespace).\(key)"
    }
}

public enum SettingsKeys {
    public static let removeFillers = "remove_fillers"
    public static let autoPunctuation = "auto_punctuation"
    public static let punctuationStyle = "punctuation_style"
    public static let preserveCloudRawPunctuation = "preserve_cloud_raw_punctuation"
    public static let enableAdaptivePunctuation = "enable_adaptive_punctuation"
    public static let punctuationLearningEnabled = "punctuation_learning_enabled"
    public static let punctuationDebugLogEnabled = "punctuation_debug_log_enabled"
    public static let punctuationMisbreakFixCount = "punctuation_misbreak_fix_count"
    public static let punctuationQuestionBiasFixCount = "punctuation_question_bias_fix_count"
    public static let punctuationUserCorrectionEventCount = "punctuation_user_correction_event_count"
    public static let sentenceEndingPunctuationEnabled = "sentence_ending_punctuation_enabled"
    public static let chineseScriptMode = "chinese_script_mode"
    public static let fillerBlacklist = "filler_blacklist"
    public static let asrModel = "asr_model"
    public static let recognitionMode = "recognition_mode"
    public static let livePreviewEnabled = "live_preview_enabled"
    public static let livePreviewSource = "live_preview_source"
    public static let cloudStablePreviewCommitEnabled = "cloud_stable_preview_commit_enabled"
    public static let recordingDurationLimit = "recording_duration_limit"
    public static let cloudAPIEndpoint = "cloud_api_endpoint"
    public static let cloudAPIAppKey = "cloud_api_app_key"
    public static let cloudAPIKey = "cloud_api_key"
    public static let cloudAPIResourceID = "cloud_api_resource_id"
    public static let cloudAPIModel = "cloud_api_model"
    public static let cloudAPIPricePerMinute = "cloud_api_price_per_minute"
    public static let cloudRequestLogs = "cloud_request_logs"
    public static let pipelinePerformanceLogs = "pipeline_performance_logs"
    public static let historyDurationUnit = "history_duration_unit"
    public static let historyRetentionPolicy = "history_retention_policy"
    public static let historyInputRecords = "history_input_records"
    public static let lexiconHitVisibility = "lexicon_hit_visibility"
    public static let shortcutHoldToTalk = "shortcut_hold_to_talk"
    public static let shortcutHandsFreeToggle = "shortcut_hands_free_toggle"
    public static let shortcutInputMode = "shortcut_input_mode"
    public static let inputCompletionSoundEnabled = "input_completion_sound_enabled"
    public static let floatingBallOrigin = "floating_ball_origin"
    public static let didRunInitialPermissionPrompt = "did_run_initial_permission_prompt"
    public static let didRunInitialLocalASRPrompt = "did_run_initial_local_asr_prompt"
}
