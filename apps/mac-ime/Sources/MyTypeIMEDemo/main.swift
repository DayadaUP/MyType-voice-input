import Foundation
import AppKit
import AVFoundation
import Darwin
import Common
import Settings
import Lexicon
import TextProcessor
import AudioEngine
import ASRAdapter
import FloatingUI
import IMEHost

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private struct UncheckedTextProcessor: @unchecked Sendable {
        let value: TextProcessor
    }

    private final class AsyncPolishState: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?

        func store(_ value: String) {
            lock.lock()
            text = value
            lock.unlock()
        }

        func load() -> String? {
            lock.lock()
            let value = text
            lock.unlock()
            return value
        }
    }

    private struct FinalPolishResult {
        let text: String
        let elapsedMs: Int
        let timedOut: Bool
        let fallbackUsed: Bool
        let skipped: Bool
        let adopted: Bool
        let strategy: String
        let timeoutBudgetMs: Int
    }

    private struct ProtectedSpanGuardResult {
        let text: String
        let applied: Bool
        let reason: String
    }

    private struct PipelinePerformanceEntry: Codable {
        let timestamp: String
        let recognitionMode: String
        let previewSource: String
        let previewTransport: String?
        let recordingSeconds: Double?
        let stopRecordingMs: Int
        let asrMs: Int
        let asrEngineReportedMs: Int
        let textProcessMs: Int
        let finalPolishMs: Int
        let insertionMs: Int
        let totalMs: Int
        let textLength: Int
        let insertedAtStop: Bool
        let liveInserted: Bool
        let firstOutputMs: Int?
        let firstOutputSource: String?
        let recordingToPreviewFirstTextMs: Int?
        let previewUpdateCount: Int?
        let previewUpdateIntervalP50Ms: Int?
        let previewUpdateIntervalP95Ms: Int?
        let previewStreamingAttempted: Bool?
        let previewStreamingSucceeded: Bool?
        let previewStreamingFallbackToPolling: Bool?
        let previewStreamingFallbackReason: String?
        let finalizationPath: String?
        let stopToFinalRecognitionMs: Int?
        let finalRecognitionRoute: String?
        let finalRecognitionFallbackUsed: Bool?
        let finalPolishTimedOut: Bool?
        let finalPolishFallbackUsed: Bool?
        let finalPolishSkipped: Bool?
        let finalPolishAdopted: Bool?
        let finalPolishGuardRejected: Bool?
        let finalPolishStrategy: String?
        let finalPolishTimeoutBudgetMs: Int?
        let previewRawTextSample: String?
        let previewVisibleTextSample: String?
        let finalRecognitionRawTextSample: String?
        let finalProcessedTextSample: String?
        let finalPolishedTextSample: String?
        let protectedSpanGuardApplied: Bool?
        let protectedSpanGuardReason: String?
    }

    private struct PipelinePerformanceSummary {
        let sampleCount: Int
        let totalP50: Int
        let totalP95: Int
        let asrP50: Int
        let asrP95: Int
    }

    private struct CloudSessionObservation {
        let recordingStartedAt: Date
        var previewTransport: String = "not_started"
        var previewStreamingAttempted = false
        var previewStreamingSucceeded = false
        var previewStreamingFallbackToPolling = false
        var previewStreamingFallbackReason: String?
        var firstPreviewVisibleAt: Date?
        var lastPreviewVisibleAt: Date?
        var lastDisplayedPreviewText: String = ""
        var previewUpdateIntervalsMs: [Int] = []
        var previewUpdateCount = 0
        var finalizationPath: String = "batch_asr"
    }

    private struct CloudObservationFields {
        let previewTransport: String?
        let recordingToPreviewFirstTextMs: Int?
        let previewUpdateCount: Int?
        let previewUpdateIntervalP50Ms: Int?
        let previewUpdateIntervalP95Ms: Int?
        let previewStreamingAttempted: Bool?
        let previewStreamingSucceeded: Bool?
        let previewStreamingFallbackToPolling: Bool?
        let previewStreamingFallbackReason: String?
        let finalizationPath: String?
        let stopToFinalRecognitionMs: Int?
        let finalRecognitionRoute: String?
        let finalRecognitionFallbackUsed: Bool?
    }

    private struct LivePreviewStopSnapshot {
        let committedText: String
        let hasSuccessfulInsertion: Bool
        let previewRawText: String
        let visibleText: String
        let retainedWindowDuringProcessing: Bool
    }

    private enum StreamFinalizationAttemptOutcome {
        case accepted(recognition: RecognitionResult, asrMs: Int)
        case fallback(extraAsrMs: Int)
    }

    private struct HistoryInputRecord: Codable {
        let id: String
        let timestamp: String
        let text: String
    }

    private enum HistoryRetentionPolicy: String {
        case never
        case h24
        case w1
        case m1
        case forever

        static func fromStored(_ raw: String) -> HistoryRetentionPolicy {
            switch raw {
            case "never":
                return .never
            case "24h", "h24":
                return .h24
            case "1w", "w1":
                return .w1
            case "1m", "m1":
                return .m1
            case "forever":
                return .forever
            default:
                return .forever
            }
        }

        var retentionDays: Int? {
            switch self {
            case .never:
                return 0
            case .h24:
                return 1
            case .w1:
                return 7
            case .m1:
                return 30
            case .forever:
                return nil
            }
        }
    }

    private struct PermissionSnapshot: Equatable {
        let accessibilityTrusted: Bool
        let listenEventTrusted: Bool
        let microphoneStatus: AVAuthorizationStatus
    }

    private static let maxPipelinePerformanceLogEntries = 3000
    private static let firstOutputTargetMs = 220
    private static let finalPolishSoftTargetMs = 180
    private static let finalPolishHardTimeoutMs = 320
    private static let finalPolishMinTimeoutMs = 140
    private static let finalPolishPerContentCharBudgetMs = 2
    private static let finalPolishHighYieldBonusMs = 40
    private static let duplicateInsertSuppressionWindowSeconds = 1.2
    private static let processingProgressUpdateIntervalSeconds = 0.06
    private static let processingProgressAutoCap = 0.94
    private static let processingProgressFallbackEstimateMs = 1800
    private static let processingProgressCompletionHoldMs = 140
    private static let processingProgressEstimateCapMs = 12_000
    private static let livePreviewFirstPollDelaySeconds: TimeInterval = 0.12
    private static let livePreviewLocalIntervalSeconds: TimeInterval = 0.62
    private static let livePreviewCloudFastIntervalSeconds: TimeInterval = 0.26
    private static let livePreviewCloudDefaultIntervalSeconds: TimeInterval = 0.90
    private static let cloudStreamFinalizeTimeoutMs = 1500
    private static let cloudStreamFinalizeQuietPeriodMs = 260
    private static let cloudBatchFallbackHedgeDelayMs = 500
    private static let cloudStablePreviewCommitObservationWindow = 3
    private static let experimentalLivePreviewCommitEnvironmentKey =
        "MYTYPE_EXPERIMENTAL_LIVE_PREVIEW_COMMIT"
    private static let perfDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let historyDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let maxHistoryInputRecords = 5000

    private var orchestrator: IMEOrchestrator?
    private var floatingBall: FloatingBallWindow?
    private var settingsPanelController: SettingsPanelController?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu(title: "MyType")
    private let settings: SettingsStore = UserDefaultsSettingsStore(namespace: "mytype.demo")
    private var fillerBlacklistStore: FillerBlacklistStore?
    private var punctuationLearningStore: PunctuationLearningStore?
    private var lexiconService: LexiconService?
    private var textProcessor: TextProcessor?
    private let localASREngine = FasterWhisperASREngine()
    private let localPreviewASREngine = FasterWhisperASREngine()
    private lazy var cloudASREngine = CloudASREngine(
        settings: settings,
        hotwordsProvider: { [weak self] in
            guard let self else { return [] }
            if Thread.isMainThread {
                return self.lexiconService?.listManualTerms() ?? []
            }
            var terms: [String] = []
            DispatchQueue.main.sync {
                terms = self.lexiconService?.listManualTerms() ?? []
            }
            return terms
        }
    )
    private lazy var asrEngine: RoutedASREngine = RoutedASREngine(
        localEngine: localASREngine,
        cloudEngine: cloudASREngine,
        settings: settings
    )
    private let textInjector = FocusedTextInjector()
    private var lastTargetAppPID: pid_t?
    private var lastTargetAppBundleID: String?
    private var lastTargetAppName: String?
    private var correctionMonitorTimer: Timer?
    private var correctionMonitorBaselineText: String?
    private var correctionMonitorTargetPID: pid_t?
    private var correctionMonitorExpiry: Date?
    private var livePreviewWindow: LivePreviewWindow?
    private var cloudLivePreviewStreamer: CloudLivePreviewStreamer?
    private var livePreviewTimer: Timer?
    private let livePreviewQueue = DispatchQueue(label: "mytype.live.preview")
    private var livePreviewInFlight = false
    private var lastLivePreviewRawText: String = ""
    private var lastLivePreviewText: String = ""
    private var livePreviewAccumulatedText: String = ""
    private var liveCommittedText: String = ""
    private var liveHasSuccessfulInsertion = false
    private var lowLatencyStreamingPreviewHistory: [String] = []
    private var retainedProcessingPreviewText: String = ""
    private var activeCloudObservation: CloudSessionObservation?
    private var insertionGuardSessionID: String = UUID().uuidString
    private var lastInsertedDedupToken: String = ""
    private var lastInsertedAt: Date?
    private var countdownWindow: RecordingCountdownWindow?
    private var recordingLimitTimer: Timer?
    private var recordingDeadline: Date?
    private var stabilityMonitorTimer: Timer?
    private var lastPermissionSnapshot: PermissionSnapshot?
    private var globalShortcutManager: GlobalShortcutManager?
    private var startedByHoldShortcut = false
    private var activeRecordingStartedAt: Date?
    private var endRecordingPlayer: AVAudioPlayer?
    private var processingProgressTimer: Timer?
    private var processingProgressStartedAt: Date?
    private var processingProgressExpectedDurationMs = 1800
    private var processingProgressCurrentValue: Double = 0
    private var processingProgressActive = false
    private var activeProcessingRequestID: UUID?
    private var canceledProcessingRequestIDs: Set<UUID> = []
    private var stopTransitionActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherMyTypeInstances()
        prepareAudioCache()
        initializeDefaults()
        setupFillerBlacklistStore()
        configureStatusItem()
        configureGlobalShortcuts()

        if let audioURL = AppResourceLocator.url(forResource: "RecordingEndCue", withExtension: "aac") {
            do {
                endRecordingPlayer = try AVAudioPlayer(contentsOf: audioURL)
                endRecordingPlayer?.volume = 0.5
                endRecordingPlayer?.prepareToPlay()
            } catch {
                print("Failed to load audio cue: \(error)")
            }
        }

        if let logoURL = AppResourceLocator.url(forResource: "AppLogo", withExtension: "png"),
           let logoImage = NSImage(contentsOf: logoURL) {
            NSApp.applicationIconImage = createStandardDockIcon(from: logoImage)
        }

        let lexicon = LexiconService(threshold: 3, enablePersistence: true)
        let punctuationLearningStore = try? PunctuationLearningStore()
        let processor = TextProcessor(
            lexiconService: lexicon,
            settings: settings,
            punctuationProfileProvider: punctuationLearningStore
        )
        if punctuationLearningStore == nil {
            fputs("Punctuation learning SQLite init failed; adaptive punctuation falls back to neutral profile.\n", stderr)
        }
        let floatingBall = FloatingBallWindow(initialOrigin: loadFloatingBallOrigin())
        let startupASRConfig = applyModelFromSettings()
        scheduleLocalASRWarmup(
            model: startupASRConfig.model,
            scriptMode: startupASRConfig.scriptMode,
            reason: "startup"
        )
        let orchestrator = IMEOrchestrator(
            floatingBall: floatingBall,
            recorder: AudioRecorder(),
            asr: asrEngine,
            processor: processor
        )

        floatingBall.onTap = { [weak self] in
            self?.handleFloatingBallTap()
        }
        floatingBall.onSecondaryTap = { [weak self] in
            self?.handleFloatingBallSecondaryTap()
        }

        self.floatingBall = floatingBall
        self.orchestrator = orchestrator
        self.punctuationLearningStore = punctuationLearningStore
        self.lexiconService = lexicon
        self.textProcessor = processor

        print("MyType demo started. Active input capsule appears only while recording or processing.")
        print("ASR engine: RoutedASREngine (local/cloud/hybrid)")
        print("Local preview engine: tiny (performance mode)")
        print("Text output: Insert into focused input by Command+V injection.")
        print("Right-click active capsule: cancel current recording and discard.")
        print("Settings: top menu bar icon (left/right click).")
        print("Shortcuts: single configurable shortcut with input mode (hold/continuous).")
        printPipelinePerformanceReportIfAny()
        observeLocalASRAssetState()
        requestInitialPermissionsIfNeeded()
        startStabilityMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: LocalASRAssetManager.stateDidChangeNotification,
            object: LocalASRAssetManager.shared
        )
        stopTransitionActive = false
        stopCorrectionMonitor()
        stopLivePreview()
        stopFloatingProcessingProgress(resetVisual: true)
        cloudLivePreviewStreamer?.stop()
        cloudLivePreviewStreamer = nil
        stopRecordingLimitGuard()
        stopStabilityMonitor()
        globalShortcutManager?.stop()
        globalShortcutManager = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsPanel(anchorToFloatingBall: false)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Dock Menu")
        let settingsItem = NSMenuItem(
            title: "打开设置",
            action: #selector(showSettingsMenuAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    @objc private func showSettingsMenuAction() {
        showSettingsPanel(anchorToFloatingBall: false)
    }

    private func terminateOtherMyTypeInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard app.processIdentifier != currentPID else { continue }
            guard app.executableURL?.lastPathComponent == "MyTypeIMEDemo" else { continue }
            app.terminate()
        }
    }

    private func handleFloatingBallTap() {
        guard let orchestrator else { return }

        switch orchestrator.state {
        case .idle:
            guard ensurePermissionsReadyForVoiceInput() else {
                return
            }
            do {
                stopFloatingProcessingProgress(resetVisual: true)
                captureTargetAppBeforeRecording()
                resetInsertionDedupSession()
                stopTransitionActive = false
                try orchestrator.startRecording()
                activeRecordingStartedAt = Date()
                beginCloudObservationSessionIfNeeded(startedAt: activeRecordingStartedAt ?? Date())
                startLivePreview()
                startRecordingLimitGuard()
                print("Recording started.")
            } catch {
                fputs("Start recording failed: \(error)\n", stderr)
                resetCloudObservationSession()
            }
        case .recording:
            handleStopRecording(orchestrator: orchestrator)
        case .processing:
            break
        }
    }

    private func handleStopRecording(orchestrator: IMEOrchestrator) {
        guard !stopTransitionActive else {
            print("Stop request ignored: transition already active.")
            return
        }

        stopTransitionActive = true
        startedByHoldShortcut = false
        let stopTappedAt = Date()
        let recordingSeconds = activeRecordingStartedAt.map { max(0, stopTappedAt.timeIntervalSince($0)) }
        activeRecordingStartedAt = nil
        stopRecordingLimitGuard()

        let shouldAttemptStreamFinalization = shouldAttemptStreamingFinalization()
        let liveSnapshot = stopLivePreview(
            preserveLiveCommitState: true,
            retainWindowDuringProcessing: shouldRetainPreviewWindowDuringProcessing(),
            preserveStreamingSessionForFinalization: shouldAttemptStreamFinalization
        )
        beginFloatingProcessingProgress()
        let processingRequestID = beginProcessingRequest()

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.cloudLivePreviewStreamer?.stop()
                self.cloudLivePreviewStreamer = nil
                self.dismissRetainedProcessingPreviewIfNeeded()
                self.finishProcessingRequest(processingRequestID, orchestrator: orchestrator)
                self.resetLiveCommitState()
                self.resetCloudObservationSession()
                self.stopTransitionActive = false
            }

            do {
                if liveSnapshot.hasSuccessfulInsertion {
                    print("First output strategy: live preview is already visible; stop stage keeps final polish under hard timeout.")
                } else {
                    print("First output strategy: no live insertion yet; stop stage will use timeout-bounded final polish.")
                }

                let context = try orchestrator.stopRecordingForDeferredProcessing()
                if self.isProcessingRequestCanceled(processingRequestID) {
                    print("Processing canceled: discard stopped recording before final recognition.")
                    return
                }

                let orchestrationResult = try await self.processStoppedRecording(
                    context,
                    liveSnapshot: liveSnapshot,
                    shouldAttemptStreamFinalization: shouldAttemptStreamFinalization,
                    orchestrator: orchestrator
                )
                if self.isProcessingRequestCanceled(processingRequestID) {
                    print("Processing canceled: discard recognition result before final insertion.")
                    return
                }

                let text = orchestrationResult.processedText
                let polished = self.applyFinalTextPolish(text)
                if self.isProcessingRequestCanceled(processingRequestID) {
                    print("Processing canceled: discard polished text before final insertion.")
                    return
                }
                let protectedSpanGuard = self.applyProtectedSpanGuard(
                    previewText: liveSnapshot.visibleText,
                    candidateText: polished.text
                )
                let finalOutputText = protectedSpanGuard.text
                self.appendHistoryInputRecordIfNeeded(finalOutputText)
                self.printLexiconHitsIfEnabled()
                self.restoreTargetAppFocusIfNeeded()

                if liveSnapshot.retainedWindowDuringProcessing {
                    self.updateRetainedProcessingPreviewIfNeeded(with: finalOutputText)
                }

                let effectiveLiveState = self.resolveEffectiveLiveCommitState(snapshot: liveSnapshot)
                var pendingText = self.pendingFinalInsertionText(
                    finalText: finalOutputText,
                    liveCommittedText: effectiveLiveState.committedText,
                    liveHasSuccessfulInsertion: effectiveLiveState.hasSuccessfulInsertion
                )
                if effectiveLiveState.hasSuccessfulInsertion,
                   self.shouldSkipFinalAppendForNearEquivalentTexts(
                    liveCommittedText: effectiveLiveState.committedText,
                    finalText: finalOutputText
                   ) {
                    pendingText = ""
                    print("Skip final insert: live/final text near-equivalent at stop gate.")
                }

                var insertedAtStop = false
                var insertionMs = 0
                var firstOutputMs: Int? = effectiveLiveState.hasSuccessfulInsertion ? 0 : nil
                var firstOutputSource: String? = effectiveLiveState.hasSuccessfulInsertion ? "live_preview" : nil
                if liveSnapshot.retainedWindowDuringProcessing, firstOutputMs == nil {
                    firstOutputMs = 0
                    firstOutputSource = "preview_retained"
                    print("First output strategy: retain preview window during finalization to avoid blank gap.")
                }
                do {
                    if !pendingText.isEmpty {
                        if effectiveLiveState.hasSuccessfulInsertion,
                           self.shouldSkipFinalInsertBecauseTextAlreadyPresent(pendingText) {
                            print("Skip final insert: pending text already present in focused input.")
                            if firstOutputMs == nil {
                                firstOutputMs = Int(Date().timeIntervalSince(stopTappedAt) * 1000.0)
                                firstOutputSource = "focused_input_already_has_text"
                            }
                        } else if self.shouldSuppressDuplicateInsertion(pendingText, source: "stop_insert") {
                            print("Skip final insert: duplicate pending text suppressed in current session.")
                            if firstOutputMs == nil {
                                firstOutputMs = Int(Date().timeIntervalSince(stopTappedAt) * 1000.0)
                                firstOutputSource = "stop_insert_duplicate_suppressed"
                            }
                        } else {
                            let insertionStarted = DispatchTime.now().uptimeNanoseconds
                            try self.textInjector.insert(
                                pendingText,
                                options: self.insertionOptionsForCurrentTarget()
                            )
                            insertionMs = Int((DispatchTime.now().uptimeNanoseconds - insertionStarted) / 1_000_000)
                            insertedAtStop = true
                            self.recordInsertedTextForDedup(pendingText)
                            if firstOutputMs == nil {
                                firstOutputMs = Int(Date().timeIntervalSince(stopTappedAt) * 1000.0)
                                firstOutputSource = "stop_insert"
                            }
                            print("Inserted text: \(pendingText)")
                        }
                    } else if effectiveLiveState.hasSuccessfulInsertion {
                        print("Final text already covered by live insertion.")
                    }
                } catch {
                    fputs("Text insertion failed: \(error)\n", stderr)
                    print("Processed text (fallback): \(polished.text)")
                    if firstOutputMs == nil {
                        firstOutputSource = "none_insert_failed"
                    }
                }

                if insertedAtStop || effectiveLiveState.hasSuccessfulInsertion {
                    self.playInputCompletionCueIfEnabled()
                    self.beginCorrectionMonitor()
                }

                if let firstOutputMs {
                    let source = firstOutputSource ?? "unknown"
                    let suffix = firstOutputMs <= Self.firstOutputTargetMs ? "within target" : "over target"
                    print(
                        "FirstOutput source=\(source) t=\(firstOutputMs)ms "
                            + "(\(suffix), target<=\(Self.firstOutputTargetMs)ms)"
                    )
                } else {
                    print("FirstOutput source=\(firstOutputSource ?? "none") no visible insert at stop stage.")
                }

                let totalMs = Int(Date().timeIntervalSince(stopTappedAt) * 1000.0)
                self.recordPipelinePerformance(
                    metrics: orchestrationResult.metrics,
                    recordingSeconds: recordingSeconds,
                    polishMs: polished.elapsedMs,
                    polishTimedOut: polished.timedOut,
                    polishFallbackUsed: polished.fallbackUsed,
                    polishSkipped: polished.skipped,
                    polishAdopted: polished.adopted,
                    polishStrategy: polished.strategy,
                    polishTimeoutBudgetMs: polished.timeoutBudgetMs,
                    insertionMs: max(0, insertionMs),
                    totalMs: max(0, totalMs),
                    textLength: finalOutputText.count,
                    insertedAtStop: insertedAtStop,
                    liveInserted: effectiveLiveState.hasSuccessfulInsertion,
                    firstOutputMs: firstOutputMs,
                    firstOutputSource: firstOutputSource,
                    previewRawText: liveSnapshot.previewRawText,
                    previewVisibleText: liveSnapshot.visibleText,
                    finalRecognitionRawText: orchestrationResult.rawRecognitionText,
                    finalProcessedText: text,
                    finalPolishedText: finalOutputText,
                    protectedSpanGuardApplied: protectedSpanGuard.applied,
                    protectedSpanGuardReason: protectedSpanGuard.reason
                )
            } catch {
                if self.isProcessingRequestCanceled(processingRequestID) {
                    return
                }
                fputs("Stop/process failed: \(error)\n", stderr)
                self.printCloudASRHintIfNeeded(error)
            }
        }
    }

    private func configureGlobalShortcuts() {
        let manager = GlobalShortcutManager(settings: settings)
        manager.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .holdPressed:
                self.handleHoldShortcutPressed()
            case .holdReleased:
                self.handleHoldShortcutReleased()
            case .handsFreeToggle:
                self.handleHandsFreeShortcutToggle()
            }
        }
        manager.start()
        globalShortcutManager = manager

        if !CGPreflightListenEventAccess() {
            print("Warning: Input monitoring permission not granted. Global shortcut will not work in other apps.")
        }
    }

    private func reloadGlobalShortcuts() {
        globalShortcutManager?.reloadBindings()
    }

    private func playInputCompletionCueIfEnabled() {
        guard settings.bool(forKey: SettingsKeys.inputCompletionSoundEnabled, default: true) else { return }
        guard let endRecordingPlayer else { return }
        endRecordingPlayer.currentTime = 0
        endRecordingPlayer.play()
    }

    private func handleHoldShortcutPressed() {
        guard let orchestrator, orchestrator.state == .idle else { return }
        startedByHoldShortcut = true
        handleFloatingBallTap()
    }

    private func handleHoldShortcutReleased() {
        defer { startedByHoldShortcut = false }
        guard let orchestrator else { return }
        guard startedByHoldShortcut else { return }
        guard orchestrator.state == .recording else { return }
        handleFloatingBallTap()
    }

    private func handleHandsFreeShortcutToggle() {
        startedByHoldShortcut = false
        guard let orchestrator else { return }
        switch orchestrator.state {
        case .idle, .recording:
            handleFloatingBallTap()
        case .processing:
            break
        }
    }

    private func handleFloatingBallSecondaryTap() {
        guard let orchestrator else { return }
        startedByHoldShortcut = false

        switch orchestrator.state {
        case .recording:
            stopTransitionActive = false
            activeRecordingStartedAt = nil
            stopRecordingLimitGuard()
            stopLivePreview()
            resetLiveCommitState()
            resetCloudObservationSession()
            do {
                let discardedURL = try orchestrator.cancelCurrentRecordingDiscard()
                if let discardedURL {
                    print("Recording canceled. Discarded audio: \(discardedURL.lastPathComponent)")
                } else {
                    print("Recording canceled.")
                }
            } catch {
                fputs("Cancel recording failed: \(error)\n", stderr)
            }
        case .idle:
            print("No active recording to cancel.")
        case .processing:
            cancelCurrentProcessingRequest(orchestrator: orchestrator)
        }
    }

    private func applyFinalTextPolish(_ text: String) -> FinalPolishResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let normalizedInput = normalizeLivePreviewText(text)
        guard let textProcessor else {
            return FinalPolishResult(
                text: normalizedInput,
                elapsedMs: 0,
                timedOut: false,
                fallbackUsed: true,
                skipped: true,
                adopted: false,
                strategy: "skip_no_processor",
                timeoutBudgetMs: 0
            )
        }

        guard shouldRunFullFinalPolish(for: normalizedInput) else {
            print("Final polish skipped: low-yield text path.")
            return FinalPolishResult(
                text: normalizedInput,
                elapsedMs: 0,
                timedOut: false,
                fallbackUsed: false,
                skipped: true,
                adopted: false,
                strategy: "skip_low_yield",
                timeoutBudgetMs: 0
            )
        }
        let timeoutBudgetMs = estimatedFinalPolishTimeoutMs(for: normalizedInput)

        let processor = UncheckedTextProcessor(value: textProcessor)
        let state = AsyncPolishState()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = processor.value.polishFinalText(normalizedInput)
            state.store(result)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutBudgetMs))
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

        if waitResult == .timedOut {
            print(
                "Final polish timeout: >\(timeoutBudgetMs)ms, "
                    + "fallback to pre-polish text for stop insertion."
            )
            return FinalPolishResult(
                text: normalizedInput,
                elapsedMs: max(elapsedMs, timeoutBudgetMs),
                timedOut: true,
                fallbackUsed: true,
                skipped: false,
                adopted: false,
                strategy: "full_dynamic_timeout",
                timeoutBudgetMs: timeoutBudgetMs
            )
        }

        let polishedOutput = state.load()
        let output: String
        let fallbackUsed: Bool
        let adopted: Bool
        let strategy: String
        if let polishedOutput {
            let decision = finalPolishAdoptionDecision(
                originalText: normalizedInput,
                polishedText: polishedOutput
            )
            adopted = decision.adopt
            if decision.adopt {
                output = polishedOutput
                fallbackUsed = false
                strategy = "full_dynamic_timeout_adopted"
            } else {
                output = normalizedInput
                fallbackUsed = true
                strategy = "full_dynamic_timeout_guard_reject_" + decision.reason
                print("Final polish rejected by quality guard: \(decision.reason).")
            }
        } else {
            output = normalizedInput
            fallbackUsed = true
            adopted = false
            strategy = "full_dynamic_timeout_missing_output"
        }
        let targetMs = min(Self.finalPolishSoftTargetMs, timeoutBudgetMs)
        let suffix = elapsedMs <= targetMs ? "within target" : "over target"
        print(
            "Final polish cost: \(elapsedMs)ms (\(suffix), target<=\(targetMs)ms, budget=\(timeoutBudgetMs)ms)."
        )
        return FinalPolishResult(
            text: output,
            elapsedMs: max(0, elapsedMs),
            timedOut: false,
            fallbackUsed: fallbackUsed,
            skipped: false,
            adopted: adopted,
            strategy: strategy,
            timeoutBudgetMs: timeoutBudgetMs
        )
    }

    private func applyProtectedSpanGuard(
        previewText: String,
        candidateText: String
    ) -> ProtectedSpanGuardResult {
        let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
            previewText: previewText,
            candidateText: candidateText
        )
        guard decision.changed else {
            return ProtectedSpanGuardResult(
                text: candidateText,
                applied: false,
                reason: decision.reason
            )
        }
        print("Protected span guard applied: \(decision.reason).")
        return ProtectedSpanGuardResult(
            text: decision.outputText,
            applied: true,
            reason: decision.reason
        )
    }

    private func finalPolishAdoptionDecision(
        originalText: String,
        polishedText: String
    ) -> (adopt: Bool, reason: String) {
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { return (false, "empty_polished_output") }
        guard !original.isEmpty else { return (true, "empty_original") }
        if original == polished { return (true, "unchanged") }
        if let numericRegressionReason = CloudStreamingFinalizationGuard.detectHardNumericIntegrityRegression(
            sourceText: original,
            candidateText: polished
        ) {
            return (false, "protected_numeric_regression_" + numericRegressionReason)
        }

        let originalCanonical = canonicalComparableText(original)
        let polishedCanonical = canonicalComparableText(polished)
        guard !polishedCanonical.isEmpty else { return (false, "empty_polished_canonical") }
        if originalCanonical == polishedCanonical {
            return (true, "format_only_change")
        }
        guard !originalCanonical.isEmpty else {
            return (true, "empty_original_canonical")
        }

        let maxLen = max(originalCanonical.count, polishedCanonical.count)
        let minLen = min(originalCanonical.count, polishedCanonical.count)
        let lengthDelta = maxLen - minLen
        let allowedDelta = max(10, Int(Double(maxLen) * 0.45))
        if lengthDelta > allowedDelta {
            return (false, "length_delta_too_large")
        }

        if originalCanonical.contains(polishedCanonical) || polishedCanonical.contains(originalCanonical) {
            return (true, "containment_match")
        }

        let prefixLen = commonPrefix(originalCanonical, polishedCanonical).count
        let suffixLen = commonSuffixLength(originalCanonical, polishedCanonical)
        let covered = min(minLen, prefixLen + suffixLen)
        let overlapCoverage = Double(covered) / Double(max(1, maxLen))
        if overlapCoverage >= 0.62 {
            return (true, "overlap_coverage_ok")
        }
        if prefixLen >= 6 || suffixLen >= 6 {
            return (true, "edge_overlap_ok")
        }

        return (false, "overlap_too_low")
    }

    private func shouldRunFullFinalPolish(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let contentCount = countMatches(pattern: "[\\p{Han}A-Za-z0-9]", in: trimmed)
        if contentCount >= 16 {
            return true
        }

        let highYieldPattern =
            "(\\d\\s*[。．，]\\s*\\d)"
            + "|([。！？]\\s*(但是|不过|然后|所以|因此|另外|同时|而且|并且|接着|最后|如果|虽然|因为|比如|例如|那么|还有|只要|就是|也就是|而是))"
            + "|(\\p{Han}\\s+[A-Za-z0-9])|([A-Za-z0-9]\\s+\\p{Han})"
            + "|([这那哪每]\\s*1\\s*(个|次|台|遍|句|种|款|页|章))|(\\p{Han}\\s*1\\s*(下|点\\s*点))|(之\\s*1)"
            + "|([，。！？；：,.!?;:]{2,})"
        if trimmed.range(of: highYieldPattern, options: .regularExpression) != nil {
            return true
        }

        if contentCount <= 8 {
            return false
        }

        // Medium-length plain sentences still benefit from final punctuation normalization.
        return trimmed.range(of: "[，。！？；：,.!?;:]", options: .regularExpression) != nil
    }

    private func estimatedFinalPolishTimeoutMs(for text: String) -> Int {
        let contentCount = countMatches(pattern: "[\\p{Han}A-Za-z0-9]", in: text)
        let punctuationCount = countMatches(pattern: "[，。！？；：,.!?;:]", in: text)
        let mixedBoundaryCount = countMatches(
            pattern: "(\\p{Han}\\s+[A-Za-z0-9])|([A-Za-z0-9]\\s+\\p{Han})",
            in: text
        )
        var budget = Self.finalPolishMinTimeoutMs
            + min(220, contentCount * Self.finalPolishPerContentCharBudgetMs)
        if punctuationCount >= 3 || mixedBoundaryCount > 0 {
            budget += Self.finalPolishHighYieldBonusMs
        }
        return min(max(budget, Self.finalPolishMinTimeoutMs), Self.finalPolishHardTimeoutMs)
    }

    private func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func beginCloudObservationSessionIfNeeded(startedAt: Date) {
        guard currentRecognitionMode() == .cloud else {
            activeCloudObservation = nil
            return
        }
        var observation = CloudSessionObservation(recordingStartedAt: startedAt)
        if !settings.bool(forKey: SettingsKeys.livePreviewEnabled, default: false) {
            observation.previewTransport = "disabled"
        }
        activeCloudObservation = observation
    }

    private func resetCloudObservationSession() {
        activeCloudObservation = nil
    }

    private func currentVisibleLivePreviewText() -> String {
        let accumulated = normalizeLivePreviewText(livePreviewAccumulatedText)
        if !accumulated.isEmpty {
            return accumulated
        }
        return normalizeLivePreviewText(lastLivePreviewText)
    }

    private func shouldRetainPreviewWindowDuringProcessing() -> Bool {
        guard currentRecognitionMode() == .cloud else { return false }
        guard !liveHasSuccessfulInsertion else { return false }
        return !currentVisibleLivePreviewText().isEmpty
    }

    private func shouldAttemptStreamingFinalization() -> Bool {
        guard currentRecognitionMode() == .cloud else { return false }
        guard isLowLatencyCloudPreviewMode() else { return false }
        return cloudLivePreviewStreamer != nil
    }

    private func shouldEnableStablePrefixLiveOutput() -> Bool {
        guard currentRecognitionMode() == .cloud else { return false }
        guard isLowLatencyCloudPreviewMode() else { return false }
        guard cloudLivePreviewStreamer != nil else { return false }
        return currentLivePreviewCommitMode() == .experimentalDirectInsert
    }

    private func updateRetainedProcessingPreviewIfNeeded(with text: String) {
        let normalized = normalizeLivePreviewText(text)
        guard !normalized.isEmpty else { return }
        guard retainedProcessingPreviewText != normalized else { return }
        retainedProcessingPreviewText = normalized
        livePreviewWindow?.updateText(normalized, near: floatingBall?.frameInScreen())
        print("Live preview finalized in-place before output: chars=\(normalized.count)")
    }

    private func dismissRetainedProcessingPreviewIfNeeded() {
        retainedProcessingPreviewText = ""
        livePreviewWindow?.hide()
    }

    private func updateCloudObservation(_ update: (inout CloudSessionObservation) -> Void) {
        guard var observation = activeCloudObservation else { return }
        update(&observation)
        activeCloudObservation = observation
    }

    private func setCloudFinalizationPath(_ path: String) {
        updateCloudObservation { observation in
            observation.finalizationPath = path
        }
    }

    private func noteCloudStreamingPreviewAttempt() {
        updateCloudObservation { observation in
            observation.previewStreamingAttempted = true
        }
    }

    private func noteCloudStreamingPreviewActivated() {
        updateCloudObservation { observation in
            observation.previewStreamingAttempted = true
            observation.previewStreamingSucceeded = true
            observation.previewTransport = "cloud_streaming"
        }
    }

    private func noteCloudStreamingPreviewFallback(reason: String) {
        updateCloudObservation { observation in
            observation.previewStreamingFallbackToPolling = true
            observation.previewStreamingFallbackReason = reason
        }
    }

    private func notePollingPreviewStarted() {
        updateCloudObservation { observation in
            let source = currentEffectivePreviewSource()
            switch source {
            case .cloud:
                if observation.previewStreamingSucceeded || observation.previewStreamingFallbackToPolling {
                    observation.previewTransport = "cloud_streaming_then_polling"
                } else {
                    observation.previewTransport = "cloud_polling"
                }
            case .local:
                observation.previewTransport = "local_polling"
            }
        }
    }

    private func noteVisiblePreviewText(_ displayedText: String) {
        let normalized = normalizeLivePreviewText(displayedText)
        guard !normalized.isEmpty else { return }
        updateCloudObservation { observation in
            guard observation.lastDisplayedPreviewText != normalized else { return }
            let now = Date()
            if let previousAt = observation.lastPreviewVisibleAt {
                observation.previewUpdateIntervalsMs.append(
                    max(0, Int(now.timeIntervalSince(previousAt) * 1000.0))
                )
            }
            if observation.firstPreviewVisibleAt == nil {
                observation.firstPreviewVisibleAt = now
            }
            observation.lastPreviewVisibleAt = now
            observation.lastDisplayedPreviewText = normalized
            observation.previewUpdateCount += 1
        }
    }

    private func compactObservationReason(_ error: Error) -> String {
        let raw = String(describing: error)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(raw.prefix(160))
    }

    private func currentCloudObservationFields(
        metrics: OrchestratorProcessingMetrics
    ) -> CloudObservationFields {
        guard currentRecognitionMode() == .cloud else {
            return CloudObservationFields(
                previewTransport: nil,
                recordingToPreviewFirstTextMs: nil,
                previewUpdateCount: nil,
                previewUpdateIntervalP50Ms: nil,
                previewUpdateIntervalP95Ms: nil,
                previewStreamingAttempted: nil,
                previewStreamingSucceeded: nil,
                previewStreamingFallbackToPolling: nil,
                previewStreamingFallbackReason: nil,
                finalizationPath: nil,
                stopToFinalRecognitionMs: nil,
                finalRecognitionRoute: nil,
                finalRecognitionFallbackUsed: nil
            )
        }

        guard let observation = activeCloudObservation else {
            return CloudObservationFields(
                previewTransport: nil,
                recordingToPreviewFirstTextMs: nil,
                previewUpdateCount: nil,
                previewUpdateIntervalP50Ms: nil,
                previewUpdateIntervalP95Ms: nil,
                previewStreamingAttempted: nil,
                previewStreamingSucceeded: nil,
                previewStreamingFallbackToPolling: nil,
                previewStreamingFallbackReason: nil,
                finalizationPath: "batch_asr",
                stopToFinalRecognitionMs: max(0, metrics.stopRecordingMs + metrics.asrMs),
                finalRecognitionRoute: metrics.asrRoute,
                finalRecognitionFallbackUsed: metrics.asrFallbackUsed
            )
        }

        let firstPreviewMs = observation.firstPreviewVisibleAt.map {
            max(0, Int($0.timeIntervalSince(observation.recordingStartedAt) * 1000.0))
        }
        let intervals = observation.previewUpdateIntervalsMs
        return CloudObservationFields(
            previewTransport: observation.previewTransport,
            recordingToPreviewFirstTextMs: firstPreviewMs,
            previewUpdateCount: observation.previewUpdateCount,
            previewUpdateIntervalP50Ms: intervals.isEmpty ? nil : percentile(intervals, p: 50),
            previewUpdateIntervalP95Ms: intervals.isEmpty ? nil : percentile(intervals, p: 95),
            previewStreamingAttempted: observation.previewStreamingAttempted,
            previewStreamingSucceeded: observation.previewStreamingSucceeded,
            previewStreamingFallbackToPolling: observation.previewStreamingFallbackToPolling,
            previewStreamingFallbackReason: observation.previewStreamingFallbackReason,
            finalizationPath: observation.finalizationPath,
            stopToFinalRecognitionMs: max(0, metrics.stopRecordingMs + metrics.asrMs),
            finalRecognitionRoute: metrics.asrRoute,
            finalRecognitionFallbackUsed: metrics.asrFallbackUsed
        )
    }

    private func beginFloatingProcessingProgress() {
        stopFloatingProcessingProgress(resetVisual: false)
        let estimateMs = estimateProcessingDurationMsForCurrentMode()
        processingProgressExpectedDurationMs = estimateMs
        processingProgressStartedAt = Date()
        processingProgressCurrentValue = 0
        processingProgressActive = true
        floatingBall?.setState(.processing)
        floatingBall?.setProcessingProgress(0)
        print("FloatingProgress start estimate=\(estimateMs)ms mode=\(currentRecognitionMode().rawValue)")
        let timer = Timer.scheduledTimer(
            timeInterval: Self.processingProgressUpdateIntervalSeconds,
            target: self,
            selector: #selector(pollFloatingProcessingProgress),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        processingProgressTimer = timer
    }

    private func beginProcessingRequest() -> UUID {
        let requestID = UUID()
        activeProcessingRequestID = requestID
        return requestID
    }

    private func isProcessingRequestCanceled(_ requestID: UUID) -> Bool {
        canceledProcessingRequestIDs.contains(requestID)
    }

    private func finishProcessingRequest(_ requestID: UUID, orchestrator: IMEOrchestrator) {
        let canceled = isProcessingRequestCanceled(requestID)
        canceledProcessingRequestIDs.remove(requestID)

        guard activeProcessingRequestID == requestID else {
            return
        }
        activeProcessingRequestID = nil

        if canceled {
            stopFloatingProcessingProgress(resetVisual: true)
            return
        }
        completeFloatingProcessingProgress(andResetOrchestrator: orchestrator)
    }

    private func cancelCurrentProcessingRequest(orchestrator: IMEOrchestrator) {
        guard let requestID = activeProcessingRequestID else {
            stopTransitionActive = false
            stopFloatingProcessingProgress(resetVisual: true)
            dismissRetainedProcessingPreviewIfNeeded()
            cloudLivePreviewStreamer?.stop()
            cloudLivePreviewStreamer = nil
            resetCloudObservationSession()
            orchestrator.forceResetToIdle(stopRecordingIfNeeded: true)
            print("Processing canceled.")
            return
        }
        canceledProcessingRequestIDs.insert(requestID)
        activeProcessingRequestID = nil
        stopTransitionActive = false
        stopFloatingProcessingProgress(resetVisual: true)
        stopCorrectionMonitor()
        dismissRetainedProcessingPreviewIfNeeded()
        cloudLivePreviewStreamer?.stop()
        cloudLivePreviewStreamer = nil
        resetLiveCommitState()
        resetCloudObservationSession()
        orchestrator.forceResetToIdle(stopRecordingIfNeeded: true)
        print("Processing canceled: this round input will be discarded.")
    }

    private func stopFloatingProcessingProgress(resetVisual: Bool) {
        processingProgressTimer?.invalidate()
        processingProgressTimer = nil
        processingProgressStartedAt = nil
        processingProgressExpectedDurationMs = Self.processingProgressFallbackEstimateMs
        processingProgressCurrentValue = 0
        processingProgressActive = false
        if resetVisual {
            floatingBall?.setProcessingProgress(0)
        }
    }

    private func completeFloatingProcessingProgress(andResetOrchestrator orchestrator: IMEOrchestrator) {
        let wasActive = processingProgressActive
        let elapsedMs = processingProgressStartedAt.map { Int(Date().timeIntervalSince($0) * 1000.0) } ?? 0
        stopFloatingProcessingProgress(resetVisual: false)
        guard wasActive else {
            orchestrator.completeProcessingAndReturnToIdle()
            return
        }

        floatingBall?.setState(.processing)
        floatingBall?.setProcessingProgress(1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.processingProgressCompletionHoldMs)) { [weak self] in
            orchestrator.completeProcessingAndReturnToIdle()
            self?.floatingBall?.setProcessingProgress(0)
        }
        print("FloatingProgress complete elapsed=\(max(0, elapsedMs))ms")
    }

    @objc
    private func pollFloatingProcessingProgress() {
        guard processingProgressActive else {
            stopFloatingProcessingProgress(resetVisual: false)
            return
        }
        guard let startedAt = processingProgressStartedAt else {
            stopFloatingProcessingProgress(resetVisual: false)
            return
        }

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000.0
        let expectedMs = max(600.0, Double(processingProgressExpectedDurationMs))
        let normalized = min(1.0, elapsedMs / expectedMs)
        let eased = 1.0 - pow(1.0 - normalized, 1.35)
        let targetProgress = min(Self.processingProgressAutoCap, eased * Self.processingProgressAutoCap)
        if targetProgress <= processingProgressCurrentValue {
            return
        }

        processingProgressCurrentValue = targetProgress
        floatingBall?.setProcessingProgress(targetProgress)
    }

    private func estimateProcessingDurationMsForCurrentMode() -> Int {
        let mode = currentRecognitionMode()
        let entries = loadPipelinePerformanceEntries()
            .filter { $0.recognitionMode == mode.rawValue }
            .suffix(30)
        let modeFallback: Int
        switch mode {
        case .local:
            modeFallback = 1400
        case .cloud, .hybrid, .auto:
            modeFallback = 2300
        }
        guard !entries.isEmpty else {
            return modeFallback
        }
        let totals = entries.map(\.totalMs)
        let estimated: Int
        if totals.count < 5 {
            let p50 = percentile(totals, p: 50)
            estimated = Int((Double(p50) * 0.6) + (Double(modeFallback) * 0.4))
        } else {
            estimated = percentile(totals, p: 75)
        }
        return min(max(estimated, 700), Self.processingProgressEstimateCapMs)
    }

    private func recordPipelinePerformance(
        metrics: OrchestratorProcessingMetrics,
        recordingSeconds: Double?,
        polishMs: Int,
        polishTimedOut: Bool,
        polishFallbackUsed: Bool,
        polishSkipped: Bool,
        polishAdopted: Bool,
        polishStrategy: String,
        polishTimeoutBudgetMs: Int,
        insertionMs: Int,
        totalMs: Int,
        textLength: Int,
        insertedAtStop: Bool,
        liveInserted: Bool,
        firstOutputMs: Int?,
        firstOutputSource: String?,
        previewRawText: String,
        previewVisibleText: String,
        finalRecognitionRawText: String,
        finalProcessedText: String,
        finalPolishedText: String,
        protectedSpanGuardApplied: Bool,
        protectedSpanGuardReason: String
    ) {
        let mode = currentRecognitionMode()
        let previewSource = currentEffectivePreviewSource()
        let cloudFields = currentCloudObservationFields(metrics: metrics)
        let entry = PipelinePerformanceEntry(
            timestamp: Self.perfDateFormatter.string(from: Date()),
            recognitionMode: mode.rawValue,
            previewSource: previewSource.rawValue,
            previewTransport: cloudFields.previewTransport,
            recordingSeconds: recordingSeconds,
            stopRecordingMs: max(0, metrics.stopRecordingMs),
            asrMs: max(0, metrics.asrMs),
            asrEngineReportedMs: max(0, metrics.asrEngineReportedMs),
            textProcessMs: max(0, metrics.textProcessMs),
            finalPolishMs: max(0, polishMs),
            insertionMs: max(0, insertionMs),
            totalMs: max(0, totalMs),
            textLength: max(0, textLength),
            insertedAtStop: insertedAtStop,
            liveInserted: liveInserted,
            firstOutputMs: firstOutputMs,
            firstOutputSource: firstOutputSource,
            recordingToPreviewFirstTextMs: cloudFields.recordingToPreviewFirstTextMs,
            previewUpdateCount: cloudFields.previewUpdateCount,
            previewUpdateIntervalP50Ms: cloudFields.previewUpdateIntervalP50Ms,
            previewUpdateIntervalP95Ms: cloudFields.previewUpdateIntervalP95Ms,
            previewStreamingAttempted: cloudFields.previewStreamingAttempted,
            previewStreamingSucceeded: cloudFields.previewStreamingSucceeded,
            previewStreamingFallbackToPolling: cloudFields.previewStreamingFallbackToPolling,
            previewStreamingFallbackReason: cloudFields.previewStreamingFallbackReason,
            finalizationPath: cloudFields.finalizationPath,
            stopToFinalRecognitionMs: cloudFields.stopToFinalRecognitionMs,
            finalRecognitionRoute: cloudFields.finalRecognitionRoute,
            finalRecognitionFallbackUsed: cloudFields.finalRecognitionFallbackUsed,
            finalPolishTimedOut: polishTimedOut,
            finalPolishFallbackUsed: polishFallbackUsed,
            finalPolishSkipped: polishSkipped,
            finalPolishAdopted: polishAdopted,
            finalPolishGuardRejected: (!polishTimedOut && !polishSkipped && !polishAdopted),
            finalPolishStrategy: polishStrategy,
            finalPolishTimeoutBudgetMs: max(0, polishTimeoutBudgetMs),
            previewRawTextSample: stageTraceSample(previewRawText),
            previewVisibleTextSample: stageTraceSample(previewVisibleText),
            finalRecognitionRawTextSample: stageTraceSample(finalRecognitionRawText),
            finalProcessedTextSample: stageTraceSample(finalProcessedText),
            finalPolishedTextSample: stageTraceSample(finalPolishedText),
            protectedSpanGuardApplied: protectedSpanGuardApplied,
            protectedSpanGuardReason: protectedSpanGuardReason
        )
        appendPipelinePerformanceEntry(entry)
        print(
            "PipelinePerf mode=\(entry.recognitionMode) preview=\(entry.previewSource) "
                + "stop=\(entry.stopRecordingMs)ms asr=\(entry.asrMs)ms "
                + "asr_engine=\(entry.asrEngineReportedMs)ms process=\(entry.textProcessMs)ms "
                + "polish=\(entry.finalPolishMs)ms timeout=\(entry.finalPolishTimedOut == true ? 1 : 0) "
                + "fallback=\(entry.finalPolishFallbackUsed == true ? 1 : 0) "
                + "skip=\(entry.finalPolishSkipped == true ? 1 : 0) "
                + "adopt=\(entry.finalPolishAdopted == true ? 1 : 0) "
                + "guard_reject=\(entry.finalPolishGuardRejected == true ? 1 : 0) "
                + "strategy=\(entry.finalPolishStrategy ?? "unknown") "
                + "budget=\(entry.finalPolishTimeoutBudgetMs ?? -1)ms "
                + "first_output=\(entry.firstOutputMs ?? -1)ms source=\(entry.firstOutputSource ?? "none") "
                + "insert=\(entry.insertionMs)ms total=\(entry.totalMs)ms"
        )
        if mode == .cloud {
            print(
                "CloudSessionPerf preview_transport=\(entry.previewTransport ?? "none") "
                    + "recording_to_preview=\(entry.recordingToPreviewFirstTextMs ?? -1)ms "
                    + "preview_updates=\(entry.previewUpdateCount ?? 0) "
                    + "preview_gap_p50=\(entry.previewUpdateIntervalP50Ms ?? -1)ms "
                    + "preview_gap_p95=\(entry.previewUpdateIntervalP95Ms ?? -1)ms "
                    + "stream_attempt=\(entry.previewStreamingAttempted == true ? 1 : 0) "
                    + "stream_ok=\(entry.previewStreamingSucceeded == true ? 1 : 0) "
                    + "stream_fallback=\(entry.previewStreamingFallbackToPolling == true ? 1 : 0) "
                    + "stream_reason=\(entry.previewStreamingFallbackReason ?? "none") "
                    + "final_path=\(entry.finalizationPath ?? "none") "
                    + "stop_to_final_recognition=\(entry.stopToFinalRecognitionMs ?? -1)ms "
                    + "final_route=\(entry.finalRecognitionRoute ?? "none") "
                    + "final_fallback=\(entry.finalRecognitionFallbackUsed == true ? 1 : 0) "
                    + "protected_guard=\(entry.protectedSpanGuardApplied == true ? 1 : 0) "
                    + "guard_reason=\(entry.protectedSpanGuardReason ?? "none")"
            )
            if entry.previewRawTextSample != nil
                || entry.previewVisibleTextSample != nil
                || entry.finalRecognitionRawTextSample != nil {
                print(
                    "CloudStageTrace preview_raw=\"\(entry.previewRawTextSample ?? "")\" "
                        + "preview_visible=\"\(entry.previewVisibleTextSample ?? "")\" "
                        + "final_raw=\"\(entry.finalRecognitionRawTextSample ?? "")\" "
                        + "final_processed=\"\(entry.finalProcessedTextSample ?? "")\" "
                        + "final_polished=\"\(entry.finalPolishedTextSample ?? "")\""
                )
            }
        }
        printPipelinePerformanceSummary(for: mode)
        if mode == .cloud {
            printCloudPerformanceSummary(entries: loadPipelinePerformanceEntries())
        }
    }

    private func appendPipelinePerformanceEntry(_ entry: PipelinePerformanceEntry) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entry),
              let serialized = String(data: data, encoding: .utf8) else {
            return
        }
        var logs = settings.stringArray(forKey: SettingsKeys.pipelinePerformanceLogs, default: [])
        logs.append(serialized)
        if logs.count > Self.maxPipelinePerformanceLogEntries {
            logs.removeFirst(logs.count - Self.maxPipelinePerformanceLogEntries)
        }
        settings.set(logs, forKey: SettingsKeys.pipelinePerformanceLogs)
    }

    private func appendHistoryInputRecordIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let policyRaw = settings.string(forKey: SettingsKeys.historyRetentionPolicy, default: HistoryRetentionPolicy.forever.rawValue)
        let policy = HistoryRetentionPolicy.fromStored(policyRaw)
        guard policy != .never else {
            settings.set([], forKey: SettingsKeys.historyInputRecords)
            return
        }

        let encoder = JSONEncoder()
        let record = HistoryInputRecord(
            id: UUID().uuidString,
            timestamp: Self.historyDateFormatter.string(from: Date()),
            text: trimmed
        )

        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else {
            return
        }

        var lines = settings.stringArray(forKey: SettingsKeys.historyInputRecords, default: [])
        lines.append(line)
        lines = prunedHistoryInputLines(lines, policy: policy)
        if lines.count > Self.maxHistoryInputRecords {
            lines.removeFirst(lines.count - Self.maxHistoryInputRecords)
        }
        settings.set(lines, forKey: SettingsKeys.historyInputRecords)
    }
    private func removeAllHistoryInputRecords() {
        settings.set([], forKey: SettingsKeys.historyInputRecords)
    }

    private func pruneHistoryInputRecordsByCurrentPolicy() {
        let lines = settings.stringArray(forKey: SettingsKeys.historyInputRecords, default: [])
        guard !lines.isEmpty else { return }
        let policyRaw = settings.string(
            forKey: SettingsKeys.historyRetentionPolicy,
            default: HistoryRetentionPolicy.forever.rawValue
        )
        let policy = HistoryRetentionPolicy.fromStored(policyRaw)
        let pruned = prunedHistoryInputLines(lines, policy: policy)
        if pruned.count != lines.count {
            settings.set(pruned, forKey: SettingsKeys.historyInputRecords)
        }
    }

    private func prunedHistoryInputLines(
        _ lines: [String],
        policy: HistoryRetentionPolicy
    ) -> [String] {
        guard let days = policy.retentionDays else { return lines }
        guard days > 0 else { return [] }

        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let decoder = JSONDecoder()
        return lines.filter { line in
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(HistoryInputRecord.self, from: data),
                  let timestamp = Self.historyDateFormatter.date(from: record.timestamp) else {
                return false
            }
            return timestamp >= cutoff
        }
    }

    private func loadPipelinePerformanceEntries() -> [PipelinePerformanceEntry] {
        let decoder = JSONDecoder()
        let logs = settings.stringArray(forKey: SettingsKeys.pipelinePerformanceLogs, default: [])
        return logs.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(PipelinePerformanceEntry.self, from: data),
                  Self.perfDateFormatter.date(from: entry.timestamp) != nil else {
                return nil
            }
            return entry
        }
    }

    private func currentEffectivePreviewSource() -> LivePreviewSource {
        let mode = currentRecognitionMode()
        if isPreviewForcedToLocal(for: mode) {
            return .local
        }
        let sourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        return LivePreviewSource(rawValue: sourceRaw) ?? .local
    }

    private func printPipelinePerformanceReportIfAny() {
        let entries = loadPipelinePerformanceEntries()
        guard !entries.isEmpty else { return }
        print("PipelinePerf historical report available: entries=\(entries.count)")
        for mode in [RecognitionMode.local, .cloud, .hybrid] {
            printPipelinePerformanceSummary(for: mode, entries: entries)
        }
        printCloudPerformanceSummary(entries: entries)
    }

    private func printPipelinePerformanceSummary(
        for mode: RecognitionMode,
        entries sourceEntries: [PipelinePerformanceEntry]? = nil
    ) {
        let entries = (sourceEntries ?? loadPipelinePerformanceEntries())
            .filter { $0.recognitionMode == mode.rawValue }
        guard !entries.isEmpty else { return }

        let now = Date()
        let windows: [(label: String, days: TimeInterval)] = [
            ("today", 1),
            ("7d", 7),
            ("30d", 30)
        ]
        for window in windows {
            let start = now.addingTimeInterval(-window.days * 24 * 3600)
            let filtered = entries.filter {
                guard let date = Self.perfDateFormatter.date(from: $0.timestamp) else { return false }
                return date >= start
            }
            guard let summary = summarizePipelinePerformance(filtered) else { continue }
            let timeoutCount = filtered.filter { $0.finalPolishTimedOut == true }.count
            let fallbackCount = filtered.filter { $0.finalPolishFallbackUsed == true }.count
            let skippedCount = filtered.filter { $0.finalPolishSkipped == true }.count
            let adoptedCount = filtered.filter { $0.finalPolishAdopted == true }.count
            let guardRejectedCount = filtered.filter { $0.finalPolishGuardRejected == true }.count
            let denominator = Double(max(1, filtered.count))
            let timeoutRate = (Double(timeoutCount) / denominator) * 100.0
            let fallbackRate = (Double(fallbackCount) / denominator) * 100.0
            let skippedRate = (Double(skippedCount) / denominator) * 100.0
            let adoptedRate = (Double(adoptedCount) / denominator) * 100.0
            let guardRejectedRate = (Double(guardRejectedCount) / denominator) * 100.0
            print(
                "PipelinePerfSummary \(window.label) mode=\(mode.rawValue) "
                    + "n=\(summary.sampleCount) total_p50=\(summary.totalP50)ms total_p95=\(summary.totalP95)ms "
                    + "asr_p50=\(summary.asrP50)ms asr_p95=\(summary.asrP95)ms "
                    + "polish_timeout_rate=\(String(format: "%.1f", timeoutRate))% "
                    + "polish_fallback_rate=\(String(format: "%.1f", fallbackRate))% "
                    + "polish_skipped_rate=\(String(format: "%.1f", skippedRate))% "
                    + "polish_adopted_rate=\(String(format: "%.1f", adoptedRate))% "
                    + "polish_guard_reject_rate=\(String(format: "%.1f", guardRejectedRate))%"
            )
        }
    }

    private func printCloudPerformanceSummary(entries sourceEntries: [PipelinePerformanceEntry]? = nil) {
        let entries = (sourceEntries ?? loadPipelinePerformanceEntries())
            .filter { $0.recognitionMode == RecognitionMode.cloud.rawValue }
        guard !entries.isEmpty else { return }

        let now = Date()
        let windows: [(label: String, days: TimeInterval)] = [
            ("today", 1),
            ("7d", 7),
            ("30d", 30)
        ]

        for window in windows {
            let start = now.addingTimeInterval(-window.days * 24 * 3600)
            let filtered = entries.filter {
                guard let date = Self.perfDateFormatter.date(from: $0.timestamp) else { return false }
                return date >= start
            }
            guard !filtered.isEmpty else { continue }

            let previewFirst = filtered.compactMap(\.recordingToPreviewFirstTextMs)
            let previewGap = filtered.compactMap(\.previewUpdateIntervalP95Ms)
            let stopToFinal = filtered.compactMap(\.stopToFinalRecognitionMs)
            let firstOutput = filtered.compactMap(\.firstOutputMs)
            let total = filtered.map(\.totalMs)
            let streamingFallbackCount = filtered.filter { $0.previewStreamingFallbackToPolling == true }.count
            let batchFinalCount = filtered.filter { self.isBatchFinalizationPath($0.finalizationPath) }.count
            let denominator = Double(max(1, filtered.count))

            print(
                "CloudPerfSummary \(window.label) "
                    + "n=\(filtered.count) "
                    + "preview_first_p50=\(previewFirst.isEmpty ? -1 : percentile(previewFirst, p: 50))ms "
                    + "preview_first_p95=\(previewFirst.isEmpty ? -1 : percentile(previewFirst, p: 95))ms "
                    + "preview_gap_p95=\(previewGap.isEmpty ? -1 : percentile(previewGap, p: 95))ms "
                    + "stop_to_final_p50=\(stopToFinal.isEmpty ? -1 : percentile(stopToFinal, p: 50))ms "
                    + "stop_to_final_p95=\(stopToFinal.isEmpty ? -1 : percentile(stopToFinal, p: 95))ms "
                    + "first_output_p50=\(firstOutput.isEmpty ? -1 : percentile(firstOutput, p: 50))ms "
                    + "first_output_p95=\(firstOutput.isEmpty ? -1 : percentile(firstOutput, p: 95))ms "
                    + "total_p50=\(percentile(total, p: 50))ms "
                    + "total_p95=\(percentile(total, p: 95))ms "
                    + "stream_fallback_rate=\(String(format: "%.1f", (Double(streamingFallbackCount) / denominator) * 100.0))% "
                    + "batch_final_rate=\(String(format: "%.1f", (Double(batchFinalCount) / denominator) * 100.0))%"
            )
        }
    }

    private func summarizePipelinePerformance(_ entries: [PipelinePerformanceEntry]) -> PipelinePerformanceSummary? {
        guard !entries.isEmpty else { return nil }
        let totals = entries.map(\.totalMs)
        let asr = entries.map(\.asrMs)
        return PipelinePerformanceSummary(
            sampleCount: entries.count,
            totalP50: percentile(totals, p: 50),
            totalP95: percentile(totals, p: 95),
            asrP50: percentile(asr, p: 50),
            asrP95: percentile(asr, p: 95)
        )
    }

    private func percentile(_ values: [Int], p: Int) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let bounded = min(max(p, 0), 100)
        if sorted.count == 1 || bounded == 0 {
            return sorted[0]
        }
        let index = Int(ceil((Double(bounded) / 100.0) * Double(sorted.count))) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func printLexiconHitsIfEnabled() {
        guard settings.bool(forKey: SettingsKeys.lexiconHitVisibility, default: false) else {
            return
        }
        let hits = textProcessor?.lastLexiconHits ?? []
        guard !hits.isEmpty else {
            print("Lexicon hits: none")
            return
        }

        let totalCount = hits.reduce(0) { $0 + max(0, $1.count) }
        print("Lexicon hits: \(hits.count) rules, total replacements \(totalCount)")
        for hit in hits {
            let source: String
            switch hit.source {
            case .learnedRule:
                source = "learned"
            case .manualTerm:
                source = "manual"
            case .pronunciationRule:
                source = "pron"
            }
            print("  [\(source)] \(hit.original) -> \(hit.replacement) x\(hit.count)")
        }
    }

    private func printCloudASRHintIfNeeded(_ error: Error) {
        guard case let CloudASREngineError.httpStatus(code, body) = error else { return }
        guard code == 400 || code == 403 else { return }

        let lower = body.lowercased()
        let resourceMentioned = lower.contains("resourceid")
            || lower.contains("resource id")
            || lower.contains("resource_id")
            || lower.contains("resource")
        let deniedSemantics = lower.contains("not allowed")
            || lower.contains("is not allowed")
            || lower.contains("not granted")
            || lower.contains("未开通")
            || lower.contains("无权限")
        let isResourceDenied = lower.contains("requested resource not granted")
            || (resourceMentioned && deniedSemantics)
        guard isResourceDenied else { return }

        print("Cloud ASR hint: 当前是云端资源权限问题（resource_id 未开通或与账号不匹配），不是录音故障。")
        if lower.contains("tried_resource_ids=") {
            print("Cloud ASR hint: 已自动尝试多个 resource_id，仍被拒绝。请到豆包/火山控制台开通 ASR 资源后重试。")
        }
    }

    private func initializeDefaults() {
        if settings.string(forKey: SettingsKeys.asrModel, default: "").isEmpty {
            settings.set(ASRModelSize.small.rawValue, forKey: SettingsKeys.asrModel)
        }
        if settings.string(forKey: SettingsKeys.recognitionMode, default: "").isEmpty {
            settings.set(RecognitionMode.local.rawValue, forKey: SettingsKeys.recognitionMode)
        } else if settings.string(forKey: SettingsKeys.recognitionMode, default: "") == RecognitionMode.auto.rawValue {
            // Migrate legacy "auto" to explicit "hybrid" mode.
            settings.set(RecognitionMode.hybrid.rawValue, forKey: SettingsKeys.recognitionMode)
        }
        if settings.string(forKey: SettingsKeys.livePreviewSource, default: "").isEmpty {
            settings.set(LivePreviewSource.local.rawValue, forKey: SettingsKeys.livePreviewSource)
        }
        if settings.string(forKey: SettingsKeys.recordingDurationLimit, default: "").isEmpty {
            settings.set(RecordingDurationLimit.s120.rawValue, forKey: SettingsKeys.recordingDurationLimit)
        }
        if settings.string(forKey: SettingsKeys.cloudAPIModel, default: "").isEmpty {
            settings.set("whisper-1", forKey: SettingsKeys.cloudAPIModel)
        }
        if settings.string(forKey: SettingsKeys.cloudAPIResourceID, default: "").isEmpty {
            settings.set("volc.bigasr.auc_turbo", forKey: SettingsKeys.cloudAPIResourceID)
        }
        if settings.string(forKey: SettingsKeys.cloudAPIPricePerMinute, default: "").isEmpty {
            settings.set("0", forKey: SettingsKeys.cloudAPIPricePerMinute)
        }
        if settings.string(forKey: SettingsKeys.historyRetentionPolicy, default: "").isEmpty {
            settings.set(HistoryRetentionPolicy.forever.rawValue, forKey: SettingsKeys.historyRetentionPolicy)
        }
        if settings.string(forKey: SettingsKeys.punctuationStyle, default: "").isEmpty {
            settings.set(PunctuationStyle.auto.rawValue, forKey: SettingsKeys.punctuationStyle)
        }
        if let defaultsStore = settings as? UserDefaultsSettingsStore,
           !defaultsStore.hasStoredValue(forKey: SettingsKeys.sentenceEndingPunctuationEnabled) {
            settings.set(true, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
        }
        if !settings.bool(forKey: SettingsKeys.enableAdaptivePunctuation, default: false) {
            settings.set(false, forKey: SettingsKeys.enableAdaptivePunctuation)
        }
        if !settings.bool(forKey: SettingsKeys.punctuationLearningEnabled, default: false) {
            settings.set(false, forKey: SettingsKeys.punctuationLearningEnabled)
        }
        if !settings.bool(forKey: SettingsKeys.punctuationDebugLogEnabled, default: false) {
            settings.set(false, forKey: SettingsKeys.punctuationDebugLogEnabled)
        }
        if !settings.bool(forKey: SettingsKeys.preserveCloudRawPunctuation, default: false) {
            // keep default explicit to stabilize behavior across app upgrades
            settings.set(false, forKey: SettingsKeys.preserveCloudRawPunctuation)
        }
        // Ship visual-only live preview by default, even for users carrying legacy settings.
        settings.set(false, forKey: SettingsKeys.cloudStablePreviewCommitEnabled)
        if settings.string(forKey: SettingsKeys.chineseScriptMode, default: "").isEmpty {
            settings.set(ChineseScriptMode.simplified.rawValue, forKey: SettingsKeys.chineseScriptMode)
        }
        if settings.string(forKey: SettingsKeys.shortcutInputMode, default: "").isEmpty {
            settings.set(ShortcutInputMode.holdToTalk.rawValue, forKey: SettingsKeys.shortcutInputMode)
        }
        if settings.string(forKey: SettingsKeys.shortcutHoldToTalk, default: "").isEmpty {
            settings.set(ShortcutBinding.defaultPrimary.serialized(), forKey: SettingsKeys.shortcutHoldToTalk)
        } else if let currentHold = ShortcutBinding.parse(
            settings.string(forKey: SettingsKeys.shortcutHoldToTalk, default: "")
        ),
        currentHold == ShortcutBinding(kind: .modifier, keyCode: 61, modifiers: []) {
            // Migrate legacy default Right Alt -> Fn.
            settings.set(ShortcutBinding.defaultPrimary.serialized(), forKey: SettingsKeys.shortcutHoldToTalk)
        }
        // Migrate legacy hands-free shortcut to unified primary shortcut when primary was disabled.
        let holdRaw = settings.string(forKey: SettingsKeys.shortcutHoldToTalk, default: "")
        let handsFreeRaw = settings.string(forKey: SettingsKeys.shortcutHandsFreeToggle, default: "")
        let holdBinding = ShortcutBinding.parse(holdRaw)
        let handsFreeBinding = ShortcutBinding.parse(handsFreeRaw)
        if holdBinding == nil, handsFreeBinding != nil {
            settings.set(handsFreeRaw, forKey: SettingsKeys.shortcutHoldToTalk)
            settings.set(ShortcutInputMode.continuous.rawValue, forKey: SettingsKeys.shortcutInputMode)
        }
        pruneHistoryInputRecordsByCurrentPolicy()
        enforcePreviewSourceForRecognitionModeIfNeeded()
    }

    private func setupFillerBlacklistStore() {
        do {
            let store = try FillerBlacklistStore()
            try store.seedIfNeeded(defaultPhrases: ["嗯", "呃", "啊", "em"])
            let phrases = try store.fetchEnabledPhrases()
            settings.set(phrases, forKey: SettingsKeys.fillerBlacklist)
            fillerBlacklistStore = store
            print("Filler blacklist loaded from SQLite: \(phrases)")
        } catch {
            let fallback = settings.stringArray(
                forKey: SettingsKeys.fillerBlacklist,
                default: ["嗯", "呃", "啊", "em"]
            )
            settings.set(fallback, forKey: SettingsKeys.fillerBlacklist)
            fputs("Filler blacklist SQLite init failed: \(error)\n", stderr)
        }
    }

    private func currentFillerBlacklist() -> [String] {
        if let store = fillerBlacklistStore, let phrases = try? store.fetchEnabledPhrases() {
            return phrases
        }
        return settings.stringArray(
            forKey: SettingsKeys.fillerBlacklist,
            default: ["嗯", "呃", "啊", "em"]
        )
    }

    private func updateFillerBlacklist(_ phrases: [String]) {
        let normalized = FillerBlacklistStore.normalize(phrases)
        settings.set(normalized, forKey: SettingsKeys.fillerBlacklist)

        guard let store = fillerBlacklistStore else {
            print("Filler blacklist saved to Settings only (SQLite unavailable).")
            return
        }

        do {
            try store.replaceAll(with: normalized)
            print("Filler blacklist updated: \(normalized)")
        } catch {
            fputs("Filler blacklist SQLite update failed: \(error)\n", stderr)
        }
    }

    private func beginCorrectionMonitor() {
        stopCorrectionMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let snapshot = self.textInjector.focusedTextSnapshot() else {
                return
            }
            self.correctionMonitorBaselineText = snapshot.text
            self.correctionMonitorTargetPID = snapshot.appPID
            self.correctionMonitorExpiry = Date().addingTimeInterval(20)

            let timer = Timer.scheduledTimer(
                timeInterval: 1.2,
                target: self,
                selector: #selector(self.pollCorrectionMonitor),
                userInfo: nil,
                repeats: true
            )
            self.correctionMonitorTimer = timer
        }
    }

    private func startLivePreview() {
        stopLivePreview()
        resetLiveCommitState()
        enforcePreviewSourceForRecognitionModeIfNeeded()
        guard settings.bool(forKey: SettingsKeys.livePreviewEnabled, default: false) else {
            return
        }
        print("Live preview started.")
        if isLowLatencyCloudPreviewMode() {
            print("Cloud live preview: low-latency preview mode enabled.")
            if currentLivePreviewCommitMode() == .experimentalDirectInsert {
                print(
                    "Cloud live output: experimental direct insert enabled via "
                        + Self.experimentalLivePreviewCommitEnvironmentKey
                )
            }
        }
        if livePreviewWindow == nil {
            livePreviewWindow = LivePreviewWindow()
        }
        livePreviewWindow?.updateText("正在识别...", near: floatingBall?.frameInScreen())

        if startCloudStreamingPreviewIfPossible() {
            return
        }

        startPollingLivePreviewTimer()
    }

    private func startPollingLivePreviewTimer() {
        notePollingPreviewStarted()
        let interval = livePreviewIntervalSeconds()
        print(
            "Live preview polling interval=\(String(format: "%.2f", interval))s "
                + "first_kick=\(String(format: "%.2f", Self.livePreviewFirstPollDelaySeconds))s"
        )
        livePreviewTimer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(pollLivePreview),
            userInfo: nil,
            repeats: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.livePreviewFirstPollDelaySeconds) { [weak self] in
            guard let self else { return }
            guard self.livePreviewTimer != nil else { return }
            self.pollLivePreview()
        }
    }

    private func startCloudStreamingPreviewIfPossible() -> Bool {
        guard isLowLatencyCloudPreviewMode() else { return false }
        guard let orchestrator, orchestrator.state == .recording else { return false }
        guard let recordingURL = orchestrator.currentRecordingURL() else { return false }

        noteCloudStreamingPreviewAttempt()
        let streamer = CloudLivePreviewStreamer(settings: settings)
        do {
            try streamer.start(
                recordingURL: recordingURL,
                onText: { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.orchestrator?.state == .recording else { return }
                        self.lastLivePreviewRawText = self.normalizeLivePreviewText(text)
                        let preview = self.prepareLivePreviewText(text, lowLatencyCloudPreview: true)
                        guard !preview.isEmpty else { return }
                        let merged = self.mergeLowLatencyPreviewText(preview)
                        self.livePreviewAccumulatedText = merged
                        self.lastLivePreviewText = preview
                        self.livePreviewWindow?.updateText(merged, near: self.floatingBall?.frameInScreen())
                        self.noteVisiblePreviewText(merged)
                        self.recordLowLatencyStreamingPreviewObservation(merged)
                        if self.currentLivePreviewCommitMode() == .experimentalDirectInsert {
                            self.commitLowLatencyStreamingStablePrefixIfNeeded()
                        }
                    }
                },
                onError: { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.orchestrator?.state == .recording else { return }
                        fputs("Cloud streaming preview failed: \(error)\n", stderr)
                        self.noteCloudStreamingPreviewFallback(reason: self.compactObservationReason(error))
                        self.lowLatencyStreamingPreviewHistory.removeAll(keepingCapacity: true)
                        self.cloudLivePreviewStreamer?.stop()
                        self.cloudLivePreviewStreamer = nil
                        // Fallback to polling preview to avoid losing UI feedback.
                        if self.livePreviewTimer == nil {
                            self.startPollingLivePreviewTimer()
                        }
                    }
                }
            )
            cloudLivePreviewStreamer = streamer
            noteCloudStreamingPreviewActivated()
            print("Cloud live preview: true streaming mode enabled.")
            return true
        } catch {
            fputs("Cloud streaming preview setup failed: \(error)\n", stderr)
            noteCloudStreamingPreviewFallback(reason: "setup_failed:\(compactObservationReason(error))")
            cloudLivePreviewStreamer = nil
            return false
        }
    }

    @discardableResult
    private func stopLivePreview(
        preserveLiveCommitState: Bool = false,
        retainWindowDuringProcessing: Bool = false,
        preserveStreamingSessionForFinalization: Bool = false
    ) -> LivePreviewStopSnapshot {
        let visibleText = currentVisibleLivePreviewText()
        let shouldRetainWindow = retainWindowDuringProcessing && !visibleText.isEmpty
        let snapshot = LivePreviewStopSnapshot(
            committedText: liveCommittedText,
            hasSuccessfulInsertion: liveHasSuccessfulInsertion,
            previewRawText: normalizeLivePreviewText(lastLivePreviewRawText),
            visibleText: visibleText,
            retainedWindowDuringProcessing: shouldRetainWindow
        )

        livePreviewTimer?.invalidate()
        livePreviewTimer = nil
        livePreviewInFlight = false
        if preserveStreamingSessionForFinalization {
            print("Cloud live preview streamer retained for stop finalization.")
        } else {
            cloudLivePreviewStreamer?.stop()
            cloudLivePreviewStreamer = nil
        }
        if shouldRetainWindow {
            retainedProcessingPreviewText = visibleText
            livePreviewWindow?.updateText(visibleText, near: floatingBall?.frameInScreen())
            print("Live preview retained during processing: chars=\(visibleText.count)")
        } else {
            dismissRetainedProcessingPreviewIfNeeded()
        }

        if !preserveLiveCommitState {
            resetLiveCommitState()
        }
        return snapshot
    }

    private func recordLowLatencyStreamingPreviewObservation(_ text: String) {
        let normalized = normalizeLivePreviewText(text)
        guard !normalized.isEmpty else { return }
        lowLatencyStreamingPreviewHistory.append(normalized)
        if lowLatencyStreamingPreviewHistory.count > Self.cloudStablePreviewCommitObservationWindow {
            lowLatencyStreamingPreviewHistory.removeFirst(
                lowLatencyStreamingPreviewHistory.count - Self.cloudStablePreviewCommitObservationWindow
            )
        }
    }

    private func commitLowLatencyStreamingStablePrefixIfNeeded() {
        guard shouldEnableStablePrefixLiveOutput() else { return }
        guard canCommitLivePreviewInsertion() else { return }
        let decision = CloudStreamingStableCommitGuard.evaluate(
            committedText: liveCommittedText,
            recentPreviewTexts: lowLatencyStreamingPreviewHistory
        )
        guard decision.shouldCommit else { return }
        guard tryLiveInsert(decision.deltaText) else { return }
        liveCommittedText = decision.nextCommittedText
        liveHasSuccessfulInsertion = true
        print(
            "Cloud live output committed stable prefix: reason=\(decision.reason) "
                + "delta_chars=\(decision.deltaText.count) committed_chars=\(decision.nextCommittedText.count)"
        )
    }

    private func processStoppedRecording(
        _ context: DeferredRecordingContext,
        liveSnapshot: LivePreviewStopSnapshot,
        shouldAttemptStreamFinalization: Bool,
        orchestrator: IMEOrchestrator
    ) async throws -> OrchestratorProcessingResult {
        let recognitionStartedNs = DispatchTime.now().uptimeNanoseconds
        let hedgedBatchTask = shouldAttemptStreamFinalization
            ? makeHedgedBatchRecognitionTask(context: context, orchestrator: orchestrator)
            : nil

        if shouldAttemptStreamFinalization {
            let outcome = await finalizeRecognitionViaActiveStreamIfPossible(liveSnapshot: liveSnapshot)
            switch outcome {
            case .accepted(let recognition, let asrMs):
                hedgedBatchTask?.cancel()
                return try await orchestrator.processDeferredRecordingDetailedAsync(
                    context,
                    recognitionOverride: recognition,
                    asrMsOverride: asrMs,
                    keepProcessingStateUntilCallerResets: true
                )
            case .fallback(let extraAsrMs):
                let batchRecognition = try await awaitHedgedBatchRecognition(
                    hedgedBatchTask,
                    context: context,
                    orchestrator: orchestrator
                )
                let fallbackAsrMs = Int(
                    (DispatchTime.now().uptimeNanoseconds - recognitionStartedNs) / 1_000_000
                )
                if extraAsrMs > 0 {
                    print(
                        "Cloud batch fallback completed after hedged wait: "
                            + "final_wait=\(max(0, fallbackAsrMs))ms stream_attempt=\(extraAsrMs)ms"
                    )
                }
                return try await orchestrator.processDeferredRecordingDetailedAsync(
                    context,
                    recognitionOverride: batchRecognition,
                    asrMsOverride: max(0, fallbackAsrMs),
                    keepProcessingStateUntilCallerResets: true
                )
            }
        }

        hedgedBatchTask?.cancel()
        return try await orchestrator.processDeferredRecordingDetailedAsync(
            context,
            keepProcessingStateUntilCallerResets: true
        )
    }

    private func makeHedgedBatchRecognitionTask(
        context: DeferredRecordingContext,
        orchestrator: IMEOrchestrator
    ) -> Task<RecognitionResult, Error> {
        Task {
            try await Task.sleep(
                nanoseconds: UInt64(Self.cloudBatchFallbackHedgeDelayMs) * 1_000_000
            )
            try Task.checkCancellation()
            print(
                "Cloud batch hedge started after "
                    + "\(Self.cloudBatchFallbackHedgeDelayMs)ms guard window."
            )
            return try await orchestrator.transcribeDeferredRecordingAsync(context)
        }
    }

    private func awaitHedgedBatchRecognition(
        _ task: Task<RecognitionResult, Error>?,
        context: DeferredRecordingContext,
        orchestrator: IMEOrchestrator
    ) async throws -> RecognitionResult {
        guard let task else {
            return try await orchestrator.transcribeDeferredRecordingAsync(context)
        }

        do {
            return try await task.value
        } catch is CancellationError {
            return try await orchestrator.transcribeDeferredRecordingAsync(context)
        } catch {
            fputs("Cloud batch hedge failed: \(error)\n", stderr)
            return try await orchestrator.transcribeDeferredRecordingAsync(context)
        }
    }

    private func finalizeRecognitionViaActiveStreamIfPossible(
        liveSnapshot: LivePreviewStopSnapshot
    ) async -> StreamFinalizationAttemptOutcome {
        guard let streamer = cloudLivePreviewStreamer else {
            setCloudFinalizationPath("stream_finalize_error_fallback_batch")
            print("Cloud stream finalization unavailable: active streamer missing, fallback to batch ASR.")
            return .fallback(extraAsrMs: 0)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let streamedText = try await streamer.finish(
                timeoutMs: Self.cloudStreamFinalizeTimeoutMs,
                quietPeriodMs: Self.cloudStreamFinalizeQuietPeriodMs
            )
            let asrMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let streamedPreviewText = prepareLivePreviewText(
                streamedText,
                lowLatencyCloudPreview: true
            )
            let decision = CloudStreamingFinalizationGuard.evaluate(
                previewText: liveSnapshot.visibleText,
                streamedPreviewText: streamedPreviewText
            )
            guard decision.accept else {
                if let reused = conservativeStreamReuseAfterMiss(
                    streamer: streamer,
                    liveSnapshot: liveSnapshot,
                    asrMs: asrMs,
                    pathOnLatestReuse: "stream_finalize_guard_reject_latest_reuse",
                    pathOnPreviewReuse: "stream_finalize_guard_reject_preview_reuse"
                ) {
                    print(
                        "Cloud stream finalization recovered after guard reject: \(decision.reason). "
                            + "preview_chars=\(liveSnapshot.visibleText.count) streamed_chars=\(streamedPreviewText.count)"
                    )
                    return reused
                }
                setCloudFinalizationPath("stream_finalize_guard_reject_fallback_batch")
                print(
                    "Cloud stream finalization rejected by guard: \(decision.reason). "
                        + "preview_chars=\(liveSnapshot.visibleText.count) streamed_chars=\(streamedPreviewText.count)"
                )
                return .fallback(extraAsrMs: max(0, asrMs))
            }

            setCloudFinalizationPath("stream_finalize")
            print(
                "Cloud stream finalization accepted: reason=\(decision.reason) "
                    + "asr=\(max(0, asrMs))ms chars=\(streamedPreviewText.count)"
            )
            return .accepted(
                recognition: RecognitionResult(
                    rawText: streamedText,
                    latencyMs: max(0, asrMs),
                    engineRoute: "cloud_doubao_sauc_stream_finalize",
                    requestedRoute: "cloud",
                    fallbackUsed: false
                ),
                asrMs: max(0, asrMs)
            )
        } catch let error as CloudLivePreviewStreamer.CloudStreamingFinalizationError {
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            switch error {
            case .noPostFinalizeTranscript:
                if let reused = conservativeStreamReuseAfterMiss(
                    streamer: streamer,
                    liveSnapshot: liveSnapshot,
                    asrMs: elapsedMs,
                    pathOnLatestReuse: "stream_finalize_timeout_latest_reuse",
                    pathOnPreviewReuse: "stream_finalize_timeout_preview_reuse"
                ) {
                    print("Cloud stream finalization recovered after timeout with conservative reuse.")
                    return reused
                }
                setCloudFinalizationPath("stream_finalize_timeout_fallback_batch")
            case .alreadyInProgress, .sessionUnavailable:
                setCloudFinalizationPath("stream_finalize_error_fallback_batch")
            }
            print("Cloud stream finalization fallback: \(error.localizedDescription)")
            return .fallback(extraAsrMs: max(0, elapsedMs))
        } catch {
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            setCloudFinalizationPath("stream_finalize_error_fallback_batch")
            fputs("Cloud stream finalization failed: \(error)\n", stderr)
            return .fallback(extraAsrMs: max(0, elapsedMs))
        }
    }

    private func conservativeStreamReuseAfterMiss(
        streamer: CloudLivePreviewStreamer,
        liveSnapshot: LivePreviewStopSnapshot,
        asrMs: Int,
        pathOnLatestReuse: String,
        pathOnPreviewReuse: String
    ) -> StreamFinalizationAttemptOutcome? {
        let latestRawText = streamer.latestTranscriptText()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !latestRawText.isEmpty {
            let latestPreviewText = prepareLivePreviewText(
                latestRawText,
                lowLatencyCloudPreview: true
            )
            let latestDecision = CloudStreamingFinalizationGuard.evaluate(
                previewText: liveSnapshot.visibleText,
                streamedPreviewText: latestPreviewText
            )
            if latestDecision.accept {
                setCloudFinalizationPath(pathOnLatestReuse)
                print(
                    "Cloud stream reused latest transcript snapshot: reason=\(latestDecision.reason) "
                        + "chars=\(latestPreviewText.count)"
                )
                return .accepted(
                    recognition: RecognitionResult(
                        rawText: latestRawText,
                        latencyMs: max(0, asrMs),
                        engineRoute: "cloud_doubao_sauc_stream_latest_reuse",
                        requestedRoute: "cloud",
                        fallbackUsed: false
                    ),
                    asrMs: max(0, asrMs)
                )
            }
        }

        let previewDecision = CloudStreamingFinalizationGuard.evaluatePreviewReuse(
            previewText: liveSnapshot.visibleText,
            recentPreviewTexts: lowLatencyStreamingPreviewHistory
        )
        guard previewDecision.accept else { return nil }
        setCloudFinalizationPath(pathOnPreviewReuse)
        print(
            "Cloud stream reused stable preview snapshot: reason=\(previewDecision.reason) "
                + "chars=\(liveSnapshot.visibleText.count)"
        )
        return .accepted(
            recognition: RecognitionResult(
                rawText: liveSnapshot.visibleText,
                latencyMs: max(0, asrMs),
                engineRoute: "cloud_doubao_sauc_stream_preview_reuse",
                requestedRoute: "cloud",
                fallbackUsed: false
            ),
            asrMs: max(0, asrMs)
        )
    }

    private func startRecordingLimitGuard() {
        stopRecordingLimitGuard()
        guard let limitSeconds = currentRecordingLimit().seconds else {
            return
        }

        recordingDeadline = Date().addingTimeInterval(limitSeconds)
        let timer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(pollRecordingLimit),
            userInfo: nil,
            repeats: true
        )
        recordingLimitTimer = timer
    }

    private func stopRecordingLimitGuard() {
        recordingLimitTimer?.invalidate()
        recordingLimitTimer = nil
        recordingDeadline = nil
        countdownWindow?.hide()
    }

    @objc
    private func pollRecordingLimit() {
        guard orchestrator?.state == .recording else {
            stopRecordingLimitGuard()
            return
        }
        guard let deadline = recordingDeadline else {
            stopRecordingLimitGuard()
            return
        }

        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            stopRecordingLimitGuard()
            print("Recording timed out. Auto stopping.")
            handleFloatingBallTap()
            return
        }

        let secondsLeft = Int(ceil(remaining))
        if secondsLeft <= 10 {
            if countdownWindow == nil {
                countdownWindow = RecordingCountdownWindow()
            }
            countdownWindow?.updateRemainingSeconds(secondsLeft, near: floatingBall?.frameInScreen())
        } else {
            countdownWindow?.hide()
        }
    }

    private func resetLiveCommitState() {
        lastLivePreviewRawText = ""
        lastLivePreviewText = ""
        livePreviewAccumulatedText = ""
        liveCommittedText = ""
        liveHasSuccessfulInsertion = false
        lowLatencyStreamingPreviewHistory.removeAll(keepingCapacity: true)
    }

    @objc
    private func pollLivePreview() {
        guard !livePreviewInFlight else { return }
        guard let orchestrator, orchestrator.state == .recording else {
            stopLivePreview()
            return
        }
        guard let recordingURL = orchestrator.currentRecordingURL() else {
            return
        }
        guard let snapshotURL = makeLivePreviewSnapshot(from: recordingURL) else {
            return
        }

        livePreviewInFlight = true
        let engine = selectedLivePreviewEngine()
        let lowLatencyCloudPreview = isLowLatencyCloudPreviewMode()
        livePreviewQueue.async { [weak self] in
            defer { try? FileManager.default.removeItem(at: snapshotURL) }
            let transcribed: String
            let previewError: Error?
            do {
                transcribed = try engine.transcribe(audioFileURL: snapshotURL).rawText
                previewError = nil
            } catch {
                transcribed = ""
                previewError = error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.livePreviewInFlight = false
                guard self.orchestrator?.state == .recording else { return }

                if let previewError {
                    if self.shouldDisableLivePreviewAfterError(previewError) {
                        self.settings.set(false, forKey: SettingsKeys.livePreviewEnabled)
                        self.stopLivePreview()
                        print("Live preview disabled automatically: local model unavailable. Enable again after local model setup.")
                        return
                    }
                    if !self.isIgnorableLivePreviewError(previewError) {
                        fputs("Live preview ASR failed: \(previewError)\n", stderr)
                    }
                }

                self.lastLivePreviewRawText = self.normalizeLivePreviewText(transcribed)
                let preview = self.prepareLivePreviewText(
                    transcribed,
                    lowLatencyCloudPreview: lowLatencyCloudPreview
                )
                guard !preview.isEmpty else { return }

                // Default runtime keeps preview visual-only; direct insert remains opt-in and experimental.
                if lowLatencyCloudPreview {
                    let merged = self.mergeLowLatencyPreviewText(preview)
                    self.livePreviewAccumulatedText = merged
                    self.lastLivePreviewText = preview
                    self.livePreviewWindow?.updateText(merged, near: self.floatingBall?.frameInScreen())
                    self.noteVisiblePreviewText(merged)
                } else {
                    if self.currentLivePreviewCommitMode() == .experimentalDirectInsert {
                        if self.lastLivePreviewText.isEmpty {
                            self.commitInitialLivePreviewIfNeeded(preview)
                        } else if preview != self.lastLivePreviewText {
                            self.commitLivePreviewIncrement(from: self.lastLivePreviewText, to: preview)
                        }
                    }
                    self.lastLivePreviewText = preview
                    self.livePreviewWindow?.updateText(preview, near: self.floatingBall?.frameInScreen())
                    self.noteVisiblePreviewText(preview)
                }
            }
        }
    }

    private func shouldDisableLivePreviewAfterError(_ error: Error) -> Bool {
        let sourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        let source = LivePreviewSource(rawValue: sourceRaw) ?? .local
        guard source == .local else { return false }

        let text = String(describing: error).lowercased()
        return text.contains("download_model")
            || text.contains("huggingface_hub")
            || text.contains("remoteprotocolerror")
    }

    private func isIgnorableLivePreviewError(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("streaming response missing text")
    }

    private func selectedLivePreviewEngine() -> ASREngine {
        if isPreviewForcedToLocal(for: currentRecognitionMode()) {
            return localPreviewASREngine
        }

        let sourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        let source = LivePreviewSource(rawValue: sourceRaw) ?? .local
        switch source {
        case .local:
            return localPreviewASREngine
        case .cloud:
            return cloudASREngine
        }
    }

    private func livePreviewIntervalSeconds() -> TimeInterval {
        if isPreviewForcedToLocal(for: currentRecognitionMode()) {
            return Self.livePreviewLocalIntervalSeconds
        }

        let sourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        let source = LivePreviewSource(rawValue: sourceRaw) ?? .local
        guard source == .cloud else { return Self.livePreviewLocalIntervalSeconds }

        let endpoint = settings.string(forKey: SettingsKeys.cloudAPIEndpoint, default: "").lowercased()
        if endpoint.contains("openspeech.bytedance.com") && endpoint.contains("/api/v3/sauc/bigmodel") {
            return Self.livePreviewCloudFastIntervalSeconds
        }
        return Self.livePreviewCloudDefaultIntervalSeconds
    }

    private func currentRecordingLimit() -> RecordingDurationLimit {
        let raw = settings.string(
            forKey: SettingsKeys.recordingDurationLimit,
            default: RecordingDurationLimit.s120.rawValue
        )
        return RecordingDurationLimit(rawValue: raw) ?? .s120
    }

    private func makeLivePreviewSnapshot(from recordingURL: URL) -> URL? {
        if isLowLatencyCloudPreviewMode() {
            return makeLivePreviewTailSnapshot(from: recordingURL, seconds: 1.1)
        }
        return makeLivePreviewSnapshotByCopy(from: recordingURL)
    }

    private func makeLivePreviewSnapshotByCopy(from recordingURL: URL) -> URL? {
        let ext = recordingURL.pathExtension.isEmpty ? "caf" : recordingURL.pathExtension
        let snapshotURL = AudioCacheStore.makeFileURL(
            prefix: "mytype-live-preview",
            fileExtension: ext
        )
        do {
            try FileManager.default.copyItem(at: recordingURL, to: snapshotURL)
            return snapshotURL
        } catch {
            return nil
        }
    }

    private func makeLivePreviewTailSnapshot(from recordingURL: URL, seconds: Double) -> URL? {
        guard seconds > 0.5 else { return makeLivePreviewSnapshotByCopy(from: recordingURL) }
        do {
            let inputFile = try AVAudioFile(forReading: recordingURL)
            let totalFrames = inputFile.length
            let sampleRate = inputFile.processingFormat.sampleRate
            guard sampleRate > 0 else { return makeLivePreviewSnapshotByCopy(from: recordingURL) }

            let targetFrames = AVAudioFramePosition(sampleRate * seconds)
            let startFrame = max(0, totalFrames - targetFrames)
            inputFile.framePosition = startFrame

            let ext = recordingURL.pathExtension.isEmpty ? "caf" : recordingURL.pathExtension
            let outputURL = AudioCacheStore.makeFileURL(
                prefix: "mytype-live-preview-tail",
                fileExtension: ext
            )
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: inputFile.fileFormat.settings)

            let bufferCapacity: AVAudioFrameCount = 2048
            while inputFile.framePosition < totalFrames {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFile.processingFormat,
                    frameCapacity: bufferCapacity
                ) else { break }
                try inputFile.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try outputFile.write(from: buffer)
            }
            return outputURL
        } catch {
            return makeLivePreviewSnapshotByCopy(from: recordingURL)
        }
    }

    private func isLowLatencyCloudPreviewMode() -> Bool {
        if isPreviewForcedToLocal(for: currentRecognitionMode()) {
            return false
        }

        let sourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        let source = LivePreviewSource(rawValue: sourceRaw) ?? .local
        guard source == .cloud else { return false }

        let endpoint = settings.string(forKey: SettingsKeys.cloudAPIEndpoint, default: "").lowercased()
        return endpoint.contains("openspeech.bytedance.com")
            && endpoint.contains("/api/v3/sauc/bigmodel")
    }

    private func needsSeparatorBetween(left: String, right: String) -> Bool {
        guard let leftScalar = left.unicodeScalars.last, let rightScalar = right.unicodeScalars.first else {
            return false
        }
        let isLeftHan = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains(leftScalar)
        let isRightHan = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains(rightScalar)
        return !(isLeftHan && isRightHan)
    }

    private func normalizeLivePreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareLivePreviewText(
        _ rawText: String,
        lowLatencyCloudPreview: Bool
    ) -> String {
        let processed: String
        if lowLatencyCloudPreview {
            processed = textProcessor?.processForPreview(rawText) ?? rawText
        } else {
            processed = textProcessor?.process(rawText) ?? rawText
        }
        return normalizeLivePreviewText(processed)
    }

    private func stageTraceSample(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        let normalized = normalizeLivePreviewText(text)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
    }

    private func mergeLowLatencyPreviewText(_ incoming: String) -> String {
        let right = normalizeLivePreviewText(incoming)
        guard !right.isEmpty else { return livePreviewAccumulatedText }

        let left = normalizeLivePreviewText(livePreviewAccumulatedText)
        guard !left.isEmpty else {
            return collapsePreviewRepetition(in: right)
        }

        if left == right || left.contains(right) {
            return left
        }
        if right.hasPrefix(left) || right.contains(left) {
            return collapsePreviewRepetition(in: right)
        }

        let overlap = suffixPrefixOverlapLength(left: left, right: right)
        if overlap >= 2 {
            let start = right.index(right.startIndex, offsetBy: overlap)
            let merged = normalizeLivePreviewText(left + String(right[start...]))
            return collapsePreviewRepetition(in: merged)
        }

        // Cloud hypotheses may revise the entire sentence. Prefer replacement to avoid duplicated paragraphs.
        let sharedPrefixCount = commonPrefix(left, right).count
        let sharedPrefixRatio = Double(sharedPrefixCount) / Double(max(1, min(left.count, right.count)))
        if right.count >= 18 && sharedPrefixRatio >= 0.45 {
            return collapsePreviewRepetition(in: right)
        }

        // Append only very short non-overlap chunks as potential new tail tokens.
        if right.count <= 18 {
            let separator = needsSeparatorBetween(left: left, right: right) ? " " : ""
            return collapsePreviewRepetition(in: normalizeLivePreviewText(left + separator + right))
        }

        return left
    }

    private func collapsePreviewRepetition(in text: String) -> String {
        var out = normalizeLivePreviewText(text)
        guard !out.isEmpty else { return out }

        // Collapse severe stutter-like repeats in preview text only.
        out = out.replacingOccurrences(
            of: "(.{2,20}?)(?:\\s*\\1){2,}",
            with: "$1",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\p{Han}{2,8})(?:\\1){2,}",
            with: "$1",
            options: .regularExpression
        )
        return normalizeLivePreviewText(out)
    }

    private func commitLivePreviewIncrement(from previous: String, to current: String) {
        guard !previous.isEmpty else { return }

        let stablePrefix = commonPrefix(previous, current)
        guard !stablePrefix.isEmpty else { return }
        guard stablePrefix.count > liveCommittedText.count else { return }
        guard stablePrefix.hasPrefix(liveCommittedText) else { return }

        let deltaStart = stablePrefix.index(stablePrefix.startIndex, offsetBy: liveCommittedText.count)
        let delta = String(stablePrefix[deltaStart...])
        guard !delta.isEmpty else { return }

        restoreTargetAppFocusIfNeeded()
        if tryLiveInsert(delta) {
            liveCommittedText = stablePrefix
            liveHasSuccessfulInsertion = true
            print("Live inserted delta: \(delta)")
        }
    }

    private func commitInitialLivePreviewIfNeeded(_ preview: String) {
        guard liveCommittedText.isEmpty else { return }
        guard preview.count >= 8 else { return }

        restoreTargetAppFocusIfNeeded()
        if tryLiveInsert(preview) {
            liveCommittedText = preview
            liveHasSuccessfulInsertion = true
            print("Live inserted initial: \(preview)")
        }
    }

    private func tryLiveInsert(_ text: String) -> Bool {
        if shouldSuppressDuplicateInsertion(text, source: "live_preview") {
            print("Live insert skipped: duplicate delta suppressed in current session.")
            return true
        }

        if textInjector.insertAccessibilityOnly(text) {
            recordInsertedTextForDedup(text)
            return true
        }

        do {
            var options = insertionOptionsForCurrentTarget()
            options.restoreClipboard = true
            options.restoreDelay = max(options.restoreDelay, 1.0)
            try textInjector.insert(text, options: options)
            recordInsertedTextForDedup(text)
            return true
        } catch {
            fputs("Live insert failed: \(error)\n", stderr)
            return false
        }
    }

    private func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        let chars = zip(lhs, rhs).prefix { $0 == $1 }.map(\.0)
        return String(chars)
    }

    private func isBatchFinalizationPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path == "batch_asr" || path.hasSuffix("_fallback_batch")
    }

    private func currentLivePreviewCommitMode() -> LivePreviewCommitMode {
        LivePreviewCommitPolicy.resolveMode(
            storedDirectInsertEnabled: settings.bool(
                forKey: SettingsKeys.cloudStablePreviewCommitEnabled,
                default: false
            ),
            experimentalOverrideEnabled: ProcessInfo.processInfo.environment[
                Self.experimentalLivePreviewCommitEnvironmentKey
            ] == "1"
        )
    }

    private func canCommitLivePreviewInsertion() -> Bool {
        LivePreviewCommitPolicy.shouldCommitDirectly(
            mode: currentLivePreviewCommitMode(),
            stopTransitionActive: stopTransitionActive
        )
    }

    private func resolveEffectiveLiveCommitState(snapshot: LivePreviewStopSnapshot) -> EffectiveLiveCommitState {
        LivePreviewCommitPolicy.resolveEffectiveLiveCommitState(
            mode: currentLivePreviewCommitMode(),
            snapshotCommittedText: snapshot.committedText,
            snapshotHasSuccessfulInsertion: snapshot.hasSuccessfulInsertion,
            latestCommittedText: liveCommittedText,
            latestHasSuccessfulInsertion: liveHasSuccessfulInsertion
        )
    }

    private func pendingFinalInsertionText(
        finalText: String,
        liveCommittedText: String,
        liveHasSuccessfulInsertion: Bool
    ) -> String {
        FinalInsertionGuard.pendingFinalInsertionText(
            finalText: finalText,
            liveCommittedText: liveCommittedText,
            liveHasSuccessfulInsertion: liveHasSuccessfulInsertion
        )
    }

    private func suffixPrefixOverlapLength(left: String, right: String) -> Int {
        let maxOverlap = min(left.count, right.count)
        guard maxOverlap > 0 else { return 0 }

        for length in stride(from: maxOverlap, through: 1, by: -1) {
            let leftStart = left.index(left.endIndex, offsetBy: -length)
            let rightEnd = right.index(right.startIndex, offsetBy: length)
            if left[leftStart...] == right[..<rightEnd] {
                return length
            }
        }
        return 0
    }

    private func shouldSkipFinalAppendForNearEquivalentTexts(
        liveCommittedText: String,
        finalText: String
    ) -> Bool {
        FinalInsertionGuard.shouldSkipFinalInsertForNearEquivalentTexts(
            liveCommittedText: liveCommittedText,
            finalText: finalText
        )
    }

    private func shouldSkipFinalInsertBecauseTextAlreadyPresent(_ pendingText: String) -> Bool {
        guard let snapshot = textInjector.focusedTextSnapshot() else { return false }
        return InsertionStabilityGuard.shouldSkipBecauseAlreadyPresent(
            focusedText: snapshot.text,
            pendingText: pendingText
        )
    }

    private func resetInsertionDedupSession() {
        insertionGuardSessionID = UUID().uuidString
        lastInsertedDedupToken = ""
        lastInsertedAt = nil
    }

    private func shouldSuppressDuplicateInsertion(_ text: String, source: String) -> Bool {
        let token = InsertionStabilityGuard.makeDedupToken(
            text: text,
            appBundleID: lastTargetAppBundleID,
            appPID: lastTargetAppPID,
            sessionID: insertionGuardSessionID
        )
        guard !token.isEmpty else { return false }

        let suppressed = InsertionStabilityGuard.shouldSuppressDuplicateInsert(
            lastToken: lastInsertedDedupToken,
            lastInsertedAt: lastInsertedAt,
            incomingToken: token,
            now: Date(),
            windowSeconds: Self.duplicateInsertSuppressionWindowSeconds
        )
        if suppressed {
            print("Insertion guard: source=\(source) duplicate token suppressed.")
        }
        return suppressed
    }

    private func recordInsertedTextForDedup(_ text: String) {
        let token = InsertionStabilityGuard.makeDedupToken(
            text: text,
            appBundleID: lastTargetAppBundleID,
            appPID: lastTargetAppPID,
            sessionID: insertionGuardSessionID
        )
        guard !token.isEmpty else { return }
        lastInsertedDedupToken = token
        lastInsertedAt = Date()
    }

    private func canonicalComparableText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[^\\p{Han}A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
    }

    private func commonSuffixLength(_ lhs: String, _ rhs: String) -> Int {
        let reversedPairs = zip(lhs.reversed(), rhs.reversed())
        var length = 0
        for (l, r) in reversedPairs {
            if l == r {
                length += 1
            } else {
                break
            }
        }
        return length
    }

    @objc
    private func pollCorrectionMonitor() {
        guard let expiry = correctionMonitorExpiry else {
            stopCorrectionMonitor()
            return
        }
        guard Date() <= expiry else {
            stopCorrectionMonitor()
            return
        }

        guard let targetPID = correctionMonitorTargetPID else {
            stopCorrectionMonitor()
            return
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            stopCorrectionMonitor()
            return
        }

        guard let snapshot = textInjector.focusedTextSnapshot(),
              snapshot.appPID == targetPID,
              let baseline = correctionMonitorBaselineText else {
            return
        }

        guard snapshot.text != baseline else { return }
        let pairs = CorrectionDiffDetector.detectPairs(from: baseline, to: snapshot.text)
        for pair in pairs {
            lexiconService?.recordCorrection(wrong: pair.wrongTerm, corrected: pair.correctedTerm)
            let count = lexiconService?.correctionCount(
                wrong: pair.wrongTerm,
                corrected: pair.correctedTerm
            ) ?? 0
            print("Correction captured: \(pair.wrongTerm) -> \(pair.correctedTerm), count=\(count)")
        }

        let appIdentifier = NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
        let punctuationEvents = CorrectionDiffDetector.detectPunctuationEvents(
            from: baseline,
            to: snapshot.text,
            appIdentifier: appIdentifier,
            timestamp: Date()
        )
        if !punctuationEvents.isEmpty {
            let learningEnabled = settings.bool(forKey: SettingsKeys.punctuationLearningEnabled, default: false)
            let debugEnabled = settings.bool(forKey: SettingsKeys.punctuationDebugLogEnabled, default: false)
            for event in punctuationEvents {
                let adaptedEvent = PunctuationEditEvent(
                    sourcePunctuation: event.sourcePunctuation,
                    targetPunctuation: event.targetPunctuation,
                    contextBefore: event.contextBefore,
                    contextAfter: event.contextAfter,
                    timestamp: event.timestamp,
                    appIdentifier: event.appIdentifier,
                    confidence: event.confidence
                )
                _ = punctuationLearningStore?.record(
                    event: adaptedEvent,
                    learningEnabled: learningEnabled
                )
            }

            _ = incrementLocalCounter(
                forKey: SettingsKeys.punctuationUserCorrectionEventCount,
                delta: punctuationEvents.count
            )
            _ = punctuationLearningStore?.incrementQualityMetric(
                .userCorrectionEventCount,
                delta: punctuationEvents.count
            )

            if debugEnabled {
                print(
                    "Punctuation events captured: count=\(punctuationEvents.count), "
                        + "learning=\(learningEnabled ? "on" : "off"), app=\(appIdentifier ?? "unknown")"
                )
            }
        }
        correctionMonitorBaselineText = snapshot.text
    }

    private func stopCorrectionMonitor() {
        correctionMonitorTimer?.invalidate()
        correctionMonitorTimer = nil
        correctionMonitorBaselineText = nil
        correctionMonitorTargetPID = nil
        correctionMonitorExpiry = nil
    }

    @discardableResult
    private func incrementLocalCounter(forKey key: String, delta: Int = 1) -> Int {
        guard delta > 0 else {
            return Int(settings.string(forKey: key, default: "0")) ?? 0
        }
        let current = Int(settings.string(forKey: key, default: "0")) ?? 0
        let next = current + delta
        settings.set(String(next), forKey: key)
        return next
    }

    private func startStabilityMonitor() {
        stopStabilityMonitor()
        lastPermissionSnapshot = currentPermissionSnapshot()
        stabilityMonitorTimer = Timer.scheduledTimer(
            timeInterval: 5.0,
            target: self,
            selector: #selector(pollStabilityMonitor),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopStabilityMonitor() {
        stabilityMonitorTimer?.invalidate()
        stabilityMonitorTimer = nil
        lastPermissionSnapshot = nil
    }

    @objc
    private func pollStabilityMonitor() {
        auditPermissionChanges()
        repairRuntimeInconsistencyIfNeeded()
    }

    private func auditPermissionChanges() {
        let snapshot = currentPermissionSnapshot()
        defer { lastPermissionSnapshot = snapshot }
        guard let previous = lastPermissionSnapshot, previous != snapshot else { return }

        if previous.accessibilityTrusted != snapshot.accessibilityTrusted {
            print("Permission change: accessibility=\(snapshot.accessibilityTrusted ? "granted" : "not-granted")")
        }
        if previous.listenEventTrusted != snapshot.listenEventTrusted {
            print("Permission change: input-monitoring=\(snapshot.listenEventTrusted ? "granted" : "not-granted")")
            if snapshot.listenEventTrusted, !previous.listenEventTrusted {
                globalShortcutManager?.stop()
                globalShortcutManager?.start()
                print("Global shortcut monitor restarted after input monitoring permission granted.")
            }
        }
        if previous.microphoneStatus != snapshot.microphoneStatus {
            print("Permission change: microphone=\(microphoneStatusDescription(snapshot.microphoneStatus))")
        }

        if snapshot.microphoneStatus != .authorized, orchestrator?.state == .recording {
            recoverPipelineFromRuntimeIssue(reason: "microphone permission changed while recording")
        }
    }

    private func repairRuntimeInconsistencyIfNeeded() {
        guard let orchestrator else { return }

        switch orchestrator.state {
        case .idle:
            if livePreviewTimer != nil || cloudLivePreviewStreamer != nil || livePreviewInFlight {
                stopLivePreview()
            }
            if recordingLimitTimer != nil || recordingDeadline != nil {
                stopRecordingLimitGuard()
            }
        case .recording:
            if orchestrator.currentRecordingURL() == nil {
                recoverPipelineFromRuntimeIssue(reason: "recording state has no audio URL")
            }
        case .processing:
            // Processing now includes async ASR + polish + final insertion.
            // Keep state until caller explicitly resets to idle.
            break
        }
    }

    private func recoverPipelineFromRuntimeIssue(reason: String) {
        fputs("Stability recovery triggered: \(reason)\n", stderr)
        if let requestID = activeProcessingRequestID {
            canceledProcessingRequestIDs.insert(requestID)
            activeProcessingRequestID = nil
        }
        stopLivePreview()
        stopFloatingProcessingProgress(resetVisual: true)
        stopRecordingLimitGuard()
        stopCorrectionMonitor()
        activeRecordingStartedAt = nil
        stopTransitionActive = false
        orchestrator?.forceResetToIdle(stopRecordingIfNeeded: true)
        resetLiveCommitState()
    }

    private func currentPermissionSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibilityTrusted: FocusedTextInjector.isAccessibilityTrusted(promptIfNeeded: false),
            listenEventTrusted: CGPreflightListenEventAccess(),
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    private func microphoneStatusDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not-determined"
        @unknown default:
            return "unknown"
        }
    }

    private func observeLocalASRAssetState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLocalASRAssetNotification(_:)),
            name: LocalASRAssetManager.stateDidChangeNotification,
            object: LocalASRAssetManager.shared
        )
    }

    @objc
    private func handleLocalASRAssetNotification(_ notification: Notification) {
        let snapshot = notification.userInfo?["snapshot"] as? LocalASRAssetManager.Snapshot
            ?? LocalASRAssetManager.shared.snapshot
        handleLocalASRAssetSnapshotChange(snapshot)
    }

    private func handleLocalASRAssetSnapshotChange(_ snapshot: LocalASRAssetManager.Snapshot) {
        switch snapshot.kind {
        case .installing:
            return
        case .ready:
            let config = refreshLocalASREngineConfiguration()
            scheduleLocalASRWarmup(
                model: config.model,
                scriptMode: config.scriptMode,
                reason: "local-assets-updated"
            )
        case .notInstalled, .failed, .unavailable:
            _ = refreshLocalASREngineConfiguration()
        }
    }

    private func refreshLocalASREngineConfiguration() -> (model: ASRModelSize, scriptMode: ChineseScriptMode) {
        localASREngine.refreshConfiguration()
        localPreviewASREngine.refreshConfiguration()
        return applyModelFromSettings()
    }

    private func prepareAudioCache() {
        do {
            let directory = try AudioCacheStore.ensureCacheDirectory()
            let removed = AudioCacheStore.pruneExpiredFiles(
                olderThan: AudioCacheStore.defaultRetentionSeconds
            )
            print("Audio cache directory: \(directory.path)")
            if removed > 0 {
                print("Audio cache cleanup on launch: removed \(removed) expired files.")
            }
        } catch {
            fputs("Audio cache init failed: \(error)\n", stderr)
        }
    }

    private func openAudioCacheDirectoryFromSettings() {
        let directory = (try? AudioCacheStore.ensureCacheDirectory()) ?? AudioCacheStore.cacheDirectoryURL()
        NSWorkspace.shared.open(directory)
    }

    private func clearAudioCacheFilesFromSettings() -> Int {
        if let orchestrator, orchestrator.state != .idle {
            print("Audio cache clear skipped: stop recording first.")
            return 0
        }
        do {
            let removed = try AudioCacheStore.removeAllCachedFiles()
            print("Audio cache cleared manually: removed \(removed) files.")
            return removed
        } catch {
            fputs("Audio cache clear failed: \(error)\n", stderr)
            return 0
        }
    }

    private func requestPermissionsFlow(
        openSystemSettingsIfDenied: Bool,
        promptAccessibility: Bool = true,
        promptInputMonitoring: Bool = true,
        promptMicrophoneIfNeeded: Bool = true
    ) {
        let axTrusted = FocusedTextInjector.isAccessibilityTrusted(promptIfNeeded: promptAccessibility)
        if axTrusted {
            print("Accessibility permission already granted.")
        } else {
            if promptAccessibility {
                print("Requested accessibility permission. Please allow MyType in System Settings.")
            } else {
                print("Accessibility permission not granted yet.")
            }
            if openSystemSettingsIfDenied {
                openSystemSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }

        let listenTrusted = CGPreflightListenEventAccess()
        if listenTrusted {
            print("Input monitoring permission already granted.")
        } else {
            if promptInputMonitoring {
                CGRequestListenEventAccess()
                print("Requested input monitoring permission. Please allow MyType in System Settings.")
            } else {
                print("Input monitoring permission not granted yet.")
            }
            if openSystemSettingsIfDenied {
                openSystemSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.requestMicrophonePermission(
                openSystemSettingsIfDenied: openSystemSettingsIfDenied,
                promptIfNeeded: promptMicrophoneIfNeeded
            )
        }
    }

    private func ensurePermissionsReadyForVoiceInput() -> Bool {
        guard !hasAllRequiredPermissions() else { return true }
        requestPermissionsFlow(
            openSystemSettingsIfDenied: false,
            promptAccessibility: false,
            promptInputMonitoring: false,
            promptMicrophoneIfNeeded: false
        )
        print(
            "Voice input blocked until microphone, accessibility and input monitoring permissions are granted. " +
                "Use the status bar menu '重新申请权限' if you need to reopen the system permission flow."
        )
        return false
    }

    private func requestMicrophonePermission(
        openSystemSettingsIfDenied: Bool,
        promptIfNeeded: Bool
    ) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("Microphone permission already granted.")
        case .notDetermined:
            if !promptIfNeeded {
                print("Microphone permission not determined yet.")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    print("Microphone permission granted.")
                } else {
                    print("Microphone permission denied.")
                }
            }
        case .denied:
            print("Microphone permission denied. Enable it in System Settings -> Privacy & Security -> Microphone.")
            if openSystemSettingsIfDenied {
                openSystemSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
        case .restricted:
            print("Microphone permission restricted by system policy.")
        @unknown default:
            print("Unknown microphone authorization status.")
        }
    }

    private func openSystemSettings(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func hasAllRequiredPermissions() -> Bool {
        let axTrusted = FocusedTextInjector.isAccessibilityTrusted(promptIfNeeded: false)
        let listenTrusted = CGPreflightListenEventAccess()
        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return axTrusted && listenTrusted && micAuthorized
    }

    private func requestInitialPermissionsIfNeeded() {
        if hasAllRequiredPermissions() {
            markInitialPermissionPromptCompleted()
            return
        }

        // Launch-time prompting should happen only once. After that, users can
        // manually re-open the permission flow from the status menu when needed.
        let hasStablePromptedMarker = hasInitialPermissionPromptMarker()
        let hasPrompted = settings.bool(
            forKey: SettingsKeys.didRunInitialPermissionPrompt,
            default: false
        )
        guard !hasStablePromptedMarker && !hasPrompted else { return }

        markInitialPermissionPromptCompleted()
        requestPermissionsFlow(
            openSystemSettingsIfDenied: false,
            promptAccessibility: true,
            promptMicrophoneIfNeeded: true
        )
    }

    private func markInitialPermissionPromptCompleted() {
        settings.set(true, forKey: SettingsKeys.didRunInitialPermissionPrompt)
        persistInitialPermissionPromptMarker()
    }

    private func hasInitialPermissionPromptMarker() -> Bool {
        guard let markerURL = initialPermissionPromptMarkerURL() else { return false }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    private func persistInitialPermissionPromptMarker() {
        guard let markerURL = initialPermissionPromptMarkerURL() else { return }
        let fm = FileManager.default
        do {
            let dir = markerURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: markerURL.path) {
                try Data("1".utf8).write(to: markerURL, options: .atomic)
            }
        } catch {
            fputs("Persist initial permission marker failed: \(error)\n", stderr)
        }
    }

    private func initialPermissionPromptMarkerURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("MyType", isDirectory: true)
            .appendingPathComponent("initial_permission_prompt_done.flag")
    }

    private func showSettingsPanel(anchorToFloatingBall: Bool = true) {
        if settingsPanelController == nil {
            settingsPanelController = SettingsPanelController(
                settings: settings,
                onModelChanged: { [weak self] model in
                    self?.localASREngine.setModelSize(model)
                    print("ASR model switched to: \(model.rawValue)")
                    if let scriptMode = self?.currentChineseScriptModeFromSettings() {
                        self?.scheduleLocalASRWarmup(
                            model: model,
                            scriptMode: scriptMode,
                            reason: "model-changed"
                        )
                    }
                },
                onChineseScriptModeChanged: { [weak self] mode in
                    self?.localASREngine.setChineseScriptMode(mode)
                    self?.localPreviewASREngine.setChineseScriptMode(mode)
                    print("Chinese script mode: \(mode.rawValue)")
                    if let model = self?.currentASRModelFromSettings() {
                        self?.scheduleLocalASRWarmup(
                            model: model,
                            scriptMode: mode,
                            reason: "script-mode-changed"
                        )
                    }
                },
                onRecognitionModeChanged: { [weak self] mode in
                    self?.settings.set(mode.rawValue, forKey: SettingsKeys.recognitionMode)
                    self?.enforcePreviewSourceForRecognitionModeIfNeeded()
                    print("Recognition mode: \(mode.rawValue)")
                },
                onReapplyPermissions: { [weak self] in
                    self?.requestPermissionsFlow(openSystemSettingsIfDenied: true)
                },
                fillerBlacklistProvider: { [weak self] in
                    self?.currentFillerBlacklist() ?? []
                },
                onFillerBlacklistChanged: { [weak self] phrases in
                    self?.updateFillerBlacklist(phrases)
                },
                onClearPersonalLexicon: { [weak self] in
                    self?.clearPersonalLexiconDataFromSettings()
                },
                allLexiconProvider: { [weak self] in
                    self?.lexiconService?.listPersonalTermsForDisplay() ?? []
                },
                learnedLexiconProvider: { [weak self] in
                    self?.lexiconService?.listLearnedTermsForDisplay() ?? []
                },
                manualLexiconProvider: { [weak self] in
                    self?.lexiconService?.listManualTerms() ?? []
                },
                onAddManualLexiconTerms: { [weak self] terms in
                    self?.lexiconService?.addManualTerms(terms)
                    print("Manual lexicon terms added: \(terms)")
                },
                onDeleteManualLexiconTerm: { [weak self] term in
                    self?.lexiconService?.removePersonalTerm(term)
                    print("Personal lexicon term removed: \(term)")
                },
                onOpenAudioCacheDirectory: { [weak self] in
                    self?.openAudioCacheDirectoryFromSettings()
                },
                onClearAudioCacheFiles: { [weak self] in
                    self?.clearAudioCacheFilesFromSettings() ?? 0
                },
                onClearAllHistory: { [weak self] in
                    self?.removeAllHistoryInputRecords()
                },
                onShortcutSettingsChanged: { [weak self] in
                    self?.reloadGlobalShortcuts()
                }
            )
        }
        let anchorRect = anchorToFloatingBall ? floatingBall?.frameInScreen() : nil
        settingsPanelController?.showPanel(near: anchorRect)
    }

    private func clearPersonalLexiconDataFromSettings() {
        stopCorrectionMonitor()
        lexiconService?.clearPersonalLexiconData(resetCorrectionCounts: true)
        let resetResult = PunctuationResetCoordinator(
            store: punctuationLearningStore,
            settings: settings
        ).runResetForLexiconClear()
        switch resetResult {
        case .success:
            print("Personal lexicon cleared (including correction counts and punctuation learning data).")
        case .failure(let error):
            fputs("Punctuation learning reset failed: \(error)\n", stderr)
            print("Personal lexicon cleared (including correction counts).")
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MyType")
        icon?.isTemplate = true
        button.image = icon
        if button.image == nil {
            button.title = "MyType"
        }
        button.toolTip = "MyType"
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusMenu.removeAllItems()
        let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettingsFromStatusMenu), keyEquivalent: "")
        settingsItem.target = self
        let permissionsItem = NSMenuItem(title: "重新申请权限", action: #selector(reapplyPermissionsFromStatusMenu), keyEquivalent: "")
        permissionsItem.target = self
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromStatusMenu), keyEquivalent: "")
        quitItem.target = self
        statusMenu.addItem(settingsItem)
        statusMenu.addItem(permissionsItem)
        statusMenu.addItem(quitItem)

        statusItem = item
    }

    @objc
    private func handleStatusItemClick() {
        guard let statusItem, let button = statusItem.button else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
            return
        }

        showSettingsPanel(anchorToFloatingBall: false)
    }

    @objc
    private func openSettingsFromStatusMenu() {
        showSettingsPanel(anchorToFloatingBall: false)
    }

    @objc
    private func reapplyPermissionsFromStatusMenu() {
        requestPermissionsFlow(openSystemSettingsIfDenied: true)
    }

    @objc
    private func quitFromStatusMenu() {
        NSApplication.shared.terminate(nil)
    }

    @discardableResult
    private func applyModelFromSettings() -> (model: ASRModelSize, scriptMode: ChineseScriptMode) {
        let rawValue = settings.string(forKey: SettingsKeys.asrModel, default: ASRModelSize.small.rawValue)
        let model = ASRModelSize(rawValue: rawValue) ?? .small
        localASREngine.setModelSize(model)
        // Preview uses tiny model to reduce local preview latency.
        localPreviewASREngine.setModelSize(.tiny)

        let scriptModeRawValue = settings.string(
            forKey: SettingsKeys.chineseScriptMode,
            default: ChineseScriptMode.simplified.rawValue
        )
        let scriptMode = ChineseScriptMode(rawValue: scriptModeRawValue) ?? .simplified
        localASREngine.setChineseScriptMode(scriptMode)
        localPreviewASREngine.setChineseScriptMode(scriptMode)
        return (model, scriptMode)
    }

    private func currentASRModelFromSettings() -> ASRModelSize {
        let rawValue = settings.string(forKey: SettingsKeys.asrModel, default: ASRModelSize.small.rawValue)
        return ASRModelSize(rawValue: rawValue) ?? .small
    }

    private func currentChineseScriptModeFromSettings() -> ChineseScriptMode {
        let rawValue = settings.string(
            forKey: SettingsKeys.chineseScriptMode,
            default: ChineseScriptMode.simplified.rawValue
        )
        return ChineseScriptMode(rawValue: rawValue) ?? .simplified
    }

    private func scheduleLocalASRWarmup(
        model: ASRModelSize,
        scriptMode: ChineseScriptMode,
        reason: String
    ) {
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                guard let warmupURL = createSilentWarmupAudioFileURL() else { return }
                defer { try? FileManager.default.removeItem(at: warmupURL) }

                let engine = FasterWhisperASREngine()
                engine.setModelSize(model)
                engine.setChineseScriptMode(scriptMode)

                let startedAt = Date()
                do {
                    _ = try engine.transcribe(audioFileURL: warmupURL)
                    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                    print("ASR warmup(\(reason)) finished: model=\(model.rawValue), script=\(scriptMode.rawValue), latency=\(elapsedMs)ms")
                } catch {
                    fputs("ASR warmup(\(reason)) skipped: \(error)\n", stderr)
                }
            }
        }
    }

    private func loadFloatingBallOrigin() -> NSPoint {
        let raw = settings.string(forKey: SettingsKeys.floatingBallOrigin, default: "")
        let components = raw.split(separator: ",")
        guard components.count == 2,
              let x = Double(components[0]),
              let y = Double(components[1]) else {
            return NSPoint(x: 80, y: 480)
        }
        return NSPoint(x: x, y: y)
    }

    private func saveFloatingBallOrigin(_ origin: NSPoint) {
        settings.set("\(origin.x),\(origin.y)", forKey: SettingsKeys.floatingBallOrigin)
    }

    private func handleFloatingBallMoved(_ origin: NSPoint) {
        saveFloatingBallOrigin(origin)
        let anchor = floatingBall?.frameInScreen()
        livePreviewWindow?.move(near: anchor)
        countdownWindow?.move(near: anchor)
    }

    private func currentRecognitionMode() -> RecognitionMode {
        let modeRaw = settings.string(
            forKey: SettingsKeys.recognitionMode,
            default: RecognitionMode.local.rawValue
        )
        let mode = RecognitionMode(rawValue: modeRaw) ?? .local
        if mode == .auto {
            return .hybrid
        }
        return mode
    }

    private func enforcePreviewSourceForRecognitionModeIfNeeded() {
        let mode = currentRecognitionMode()
        guard isPreviewForcedToLocal(for: mode) else { return }
        let sourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        if LivePreviewSource(rawValue: sourceRaw) != .local {
            settings.set(LivePreviewSource.local.rawValue, forKey: SettingsKeys.livePreviewSource)
            print("Preview source forced to local because recognition mode is \(mode.rawValue).")
        }
    }

    private func isPreviewForcedToLocal(for mode: RecognitionMode) -> Bool {
        mode == .local || mode == .hybrid || mode == .auto
    }

    private func captureTargetAppBeforeRecording() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            lastTargetAppPID = nil
            lastTargetAppBundleID = nil
            lastTargetAppName = nil
            return
        }
        if frontmost.processIdentifier == currentPID {
            lastTargetAppPID = nil
            lastTargetAppBundleID = nil
            lastTargetAppName = nil
            return
        }
        lastTargetAppPID = frontmost.processIdentifier
        lastTargetAppBundleID = frontmost.bundleIdentifier
        lastTargetAppName = frontmost.localizedName

        let profile = currentTargetCompatibilityProfile()
        print(
            "Target app captured: name=\(lastTargetAppName ?? "-"), "
                + "bundle=\(lastTargetAppBundleID ?? "-"), profile=\(profile.rawValue)"
        )
    }

    private func restoreTargetAppFocusIfNeeded() {
        guard let targetPID = lastTargetAppPID else { return }
        guard let app = NSRunningApplication(processIdentifier: targetPID) else { return }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmostPID != targetPID {
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            // Allow focus transition to settle before injection.
            usleep(targetFocusSettleMicroseconds())
        }
    }

    private func currentTargetCompatibilityProfile() -> AppCompatibilityProfile {
        AppCompatibilityResolver.resolve(
            bundleID: lastTargetAppBundleID,
            appName: lastTargetAppName
        )
    }

    private func createStandardDockIcon(from image: NSImage) -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let result = NSImage(size: size)
        result.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .high
            
            // Standard macOS squircle padding
            let inset: CGFloat = 80
            let rect = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            
            // Draw drop shadow
            ctx.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -20)
            shadow.shadowBlurRadius = 40
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            let shadowPath = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
            NSColor.white.set()
            shadowPath.fill()
            ctx.restoreGraphicsState()
            
            // Draw image with rounded clipping
            let clipPath = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
            clipPath.addClip()
            image.draw(in: rect)
        }
        result.unlockFocus()
        return result
    }

    private func targetFocusSettleMicroseconds() -> useconds_t {
        switch currentTargetCompatibilityProfile() {
        case .iPhoneMirroring:
            return 300_000
        case .notion, .browser, .electronLike:
            return 120_000
        case .wechat, .generic:
            return 80_000
        }
    }

    private func insertionOptionsForCurrentTarget() -> TextInsertionOptions {
        TextInsertionOptions.compatibilityPreset(currentTargetCompatibilityProfile())
    }
}

private func createSilentWarmupAudioFileURL(durationSeconds: Double = 0.35) -> URL? {
    guard durationSeconds > 0 else { return nil }
    let sampleRate = 16_000.0
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        return nil
    }

    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    guard frameCount > 0 else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
    }
    buffer.frameLength = frameCount
    if let channel = buffer.floatChannelData?.pointee {
        channel.update(repeating: 0, count: Int(frameCount))
    }

    let finalURL = AudioCacheStore.makeFileURL(prefix: "mytype-asr-warmup", fileExtension: "wav")

    do {
        let file = try AVAudioFile(forWriting: finalURL, settings: format.settings)
        try file.write(from: buffer)
        return finalURL
    } catch {
        fputs("Create warmup audio failed: \(error)\n", stderr)
        return nil
    }
}

let app = NSApplication.shared
app.appearance = MyTypeAppearance.fixedLightMode
let delegate = DemoAppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
