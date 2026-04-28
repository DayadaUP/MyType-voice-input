import Foundation
import Common
import Settings
import Lexicon
import TextProcessor
import AudioEngine
import ASRAdapter
import FloatingUI

public enum IMEOrchestratorError: Error {
    case invalidStateTransition(from: RecordingState, to: RecordingState)
}

public struct OrchestratorProcessingMetrics: Sendable {
    public let stopRecordingMs: Int
    public let asrMs: Int
    public let asrEngineReportedMs: Int
    public let textProcessMs: Int
    public let asrRoute: String
    public let asrFallbackUsed: Bool

    public init(
        stopRecordingMs: Int,
        asrMs: Int,
        asrEngineReportedMs: Int,
        textProcessMs: Int,
        asrRoute: String,
        asrFallbackUsed: Bool
    ) {
        self.stopRecordingMs = stopRecordingMs
        self.asrMs = asrMs
        self.asrEngineReportedMs = asrEngineReportedMs
        self.textProcessMs = textProcessMs
        self.asrRoute = asrRoute
        self.asrFallbackUsed = asrFallbackUsed
    }
}

public struct OrchestratorProcessingResult: Sendable {
    public let rawRecognitionText: String
    public let processedText: String
    public let metrics: OrchestratorProcessingMetrics

    public init(rawRecognitionText: String, processedText: String, metrics: OrchestratorProcessingMetrics) {
        self.rawRecognitionText = rawRecognitionText
        self.processedText = processedText
        self.metrics = metrics
    }
}

public struct DeferredRecordingContext: Sendable {
    public let audioURL: URL
    public let stopRecordingMs: Int
    public let processingStartedNs: UInt64

    public init(audioURL: URL, stopRecordingMs: Int, processingStartedNs: UInt64) {
        self.audioURL = audioURL
        self.stopRecordingMs = stopRecordingMs
        self.processingStartedNs = processingStartedNs
    }
}

@MainActor
public final class IMEOrchestrator {
    private static let minimumProcessingIndicatorNs: UInt64 = 200_000_000

    private let floatingBall: FloatingBallWindow
    private let recorder: AudioRecorder
    private let asr: ASREngine
    private let processor: TextProcessor
    public private(set) var state: RecordingState = .idle

    public init(
        floatingBall: FloatingBallWindow,
        recorder: AudioRecorder,
        asr: ASREngine,
        processor: TextProcessor
    ) {
        self.floatingBall = floatingBall
        self.recorder = recorder
        self.asr = asr
        self.processor = processor
    }

    @discardableResult
    public func startRecording() throws -> RecordingState {
        guard state == .idle else {
            throw IMEOrchestratorError.invalidStateTransition(from: state, to: .recording)
        }

        try recorder.startRecording()
        state = .recording
        floatingBall.setState(.recording)
        return state
    }

    public func currentRecordingURL() -> URL? {
        recorder.currentRecordingURL
    }

    public func stopRecordingAndProcessDetailed() throws -> OrchestratorProcessingResult {
        guard state == .recording else {
            throw IMEOrchestratorError.invalidStateTransition(from: state, to: .processing)
        }

        state = .processing
        floatingBall.setState(.processing)
        floatingBall.refreshDisplay()

        do {
            let stopStarted = DispatchTime.now().uptimeNanoseconds
            let audioURL = try recorder.stopRecording()
            defer {
                AudioCacheStore.scheduleDeletion(
                    of: audioURL,
                    after: AudioCacheStore.defaultRetentionSeconds
                )
            }
            let stopRecordingMs = Int((DispatchTime.now().uptimeNanoseconds - stopStarted) / 1_000_000)

            let asrStarted = DispatchTime.now().uptimeNanoseconds
            let asrResult = try asr.transcribe(audioFileURL: audioURL)
            let asrMs = Int((DispatchTime.now().uptimeNanoseconds - asrStarted) / 1_000_000)

            let processStarted = DispatchTime.now().uptimeNanoseconds
            let processed = processor.process(asrResult.rawText)
            let textProcessMs = Int((DispatchTime.now().uptimeNanoseconds - processStarted) / 1_000_000)

            state = .idle
            floatingBall.setState(.idle)
            let metrics = OrchestratorProcessingMetrics(
                stopRecordingMs: max(0, stopRecordingMs),
                asrMs: max(0, asrMs),
                asrEngineReportedMs: max(0, asrResult.latencyMs),
                textProcessMs: max(0, textProcessMs),
                asrRoute: asrResult.engineRoute,
                asrFallbackUsed: asrResult.fallbackUsed
            )
            return OrchestratorProcessingResult(
                rawRecognitionText: asrResult.rawText,
                processedText: processed,
                metrics: metrics
            )
        } catch {
            state = .idle
            floatingBall.setState(.idle)
            throw error
        }
    }

    public func stopRecordingAndProcessDetailedAsync(
        keepProcessingStateUntilCallerResets: Bool = false
    ) async throws -> OrchestratorProcessingResult {
        let context = try stopRecordingForDeferredProcessing()
        return try await processDeferredRecordingDetailedAsync(
            context,
            keepProcessingStateUntilCallerResets: keepProcessingStateUntilCallerResets
        )
    }

    public func stopRecordingAndProcess() throws -> String {
        try stopRecordingAndProcessDetailed().processedText
    }

    public func completeProcessingAndReturnToIdle() {
        state = .idle
        floatingBall.setState(.idle)
    }

    @discardableResult
    public func cancelCurrentRecordingDiscard() throws -> URL? {
        guard state == .recording else { return nil }

        let discardedURL = try recorder.stopRecording()
        state = .idle
        floatingBall.setState(.idle)
        AudioCacheStore.deleteFileIfExists(discardedURL)
        return discardedURL
    }

    public func stopRecordingForDeferredProcessing() throws -> DeferredRecordingContext {
        guard state == .recording else {
            throw IMEOrchestratorError.invalidStateTransition(from: state, to: .processing)
        }

        let processingStarted = DispatchTime.now().uptimeNanoseconds
        state = .processing
        floatingBall.setState(.processing)
        floatingBall.refreshDisplay()

        let stopStarted = DispatchTime.now().uptimeNanoseconds
        let audioURL = try recorder.stopRecording()
        let stopRecordingMs = Int((DispatchTime.now().uptimeNanoseconds - stopStarted) / 1_000_000)
        return DeferredRecordingContext(
            audioURL: audioURL,
            stopRecordingMs: max(0, stopRecordingMs),
            processingStartedNs: processingStarted
        )
    }

    public func processDeferredRecordingDetailedAsync(
        _ context: DeferredRecordingContext,
        recognitionOverride: RecognitionResult? = nil,
        asrMsOverride: Int? = nil,
        keepProcessingStateUntilCallerResets: Bool = false
    ) async throws -> OrchestratorProcessingResult {
        defer {
            AudioCacheStore.scheduleDeletion(
                of: context.audioURL,
                after: AudioCacheStore.defaultRetentionSeconds
            )
        }

        do {
            let asrResult: RecognitionResult
            let asrMs: Int
            if let recognitionOverride {
                asrResult = recognitionOverride
                asrMs = max(0, asrMsOverride ?? recognitionOverride.latencyMs)
            } else {
                let asrStarted = DispatchTime.now().uptimeNanoseconds
                asrResult = try await transcribeAsync(audioFileURL: context.audioURL)
                asrMs = Int((DispatchTime.now().uptimeNanoseconds - asrStarted) / 1_000_000)
            }

            let processStarted = DispatchTime.now().uptimeNanoseconds
            let processed = processor.process(asrResult.rawText)
            let textProcessMs = Int((DispatchTime.now().uptimeNanoseconds - processStarted) / 1_000_000)

            let visibleNs = DispatchTime.now().uptimeNanoseconds - context.processingStartedNs
            if visibleNs < Self.minimumProcessingIndicatorNs {
                try? await Task.sleep(nanoseconds: Self.minimumProcessingIndicatorNs - visibleNs)
            }

            if !keepProcessingStateUntilCallerResets {
                state = .idle
                floatingBall.setState(.idle)
            }
            let metrics = OrchestratorProcessingMetrics(
                stopRecordingMs: max(0, context.stopRecordingMs),
                asrMs: max(0, asrMs),
                asrEngineReportedMs: max(0, asrResult.latencyMs),
                textProcessMs: max(0, textProcessMs),
                asrRoute: asrResult.engineRoute,
                asrFallbackUsed: asrResult.fallbackUsed
            )
            return OrchestratorProcessingResult(
                rawRecognitionText: asrResult.rawText,
                processedText: processed,
                metrics: metrics
            )
        } catch {
            if !keepProcessingStateUntilCallerResets {
                state = .idle
                floatingBall.setState(.idle)
            }
            throw error
        }
    }

    public func transcribeDeferredRecordingAsync(
        _ context: DeferredRecordingContext
    ) async throws -> RecognitionResult {
        try await transcribeAsync(audioFileURL: context.audioURL)
    }

    private func transcribeAsync(audioFileURL: URL) async throws -> RecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            let engine = asr
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try engine.transcribe(audioFileURL: audioFileURL)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func forceResetToIdle(stopRecordingIfNeeded: Bool = true) {
        if stopRecordingIfNeeded, recorder.isRecording {
            _ = try? recorder.stopRecording()
        }
        state = .idle
        floatingBall.setState(.idle)
    }
}
