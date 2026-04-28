import Foundation
import AVFoundation
import Settings

public final class CloudLivePreviewStreamer: @unchecked Sendable {
    public typealias TextHandler = @Sendable (String) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    public enum CloudStreamingFinalizationError: LocalizedError {
        case alreadyInProgress
        case sessionUnavailable
        case noPostFinalizeTranscript

        public var errorDescription: String? {
            switch self {
            case .alreadyInProgress:
                return "Cloud streaming finalization is already in progress."
            case .sessionUnavailable:
                return "Cloud streaming session is unavailable for finalization."
            case .noPostFinalizeTranscript:
                return "Cloud streaming finalization produced no post-stop transcript."
            }
        }
    }

    private final class WebSocketSendResultBox: @unchecked Sendable {
        var error: Error?
    }

    private let settings: SettingsStore
    private let queue = DispatchQueue(label: "mytype.cloud.live-preview.stream")
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var feedTimer: DispatchSourceTimer?
    private var recordingURL: URL?
    private var lastSentFrame: AVAudioFramePosition = 0
    private var isRunning = false
    private var latestText = ""
    private var onText: TextHandler?
    private var onError: ErrorHandler?
    private var finalizeContinuation: CheckedContinuation<String, Error>?
    private var finalizeQuietWorkItem: DispatchWorkItem?
    private var finalizeTimeoutWorkItem: DispatchWorkItem?
    private var isFinalizing = false
    private var receivedPostFinalizeTranscript = false

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public func start(
        recordingURL: URL,
        onText: @escaping TextHandler,
        onError: @escaping ErrorHandler
    ) throws {
        guard FileManager.default.fileExists(atPath: recordingURL.path) else {
            throw ASREngineError.audioFileMissing(recordingURL)
        }

        let endpointRaw = settings.string(forKey: SettingsKeys.cloudAPIEndpoint, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointRaw.isEmpty else {
            throw CloudASREngineError.missingConfiguration("endpoint")
        }
        guard let endpointURL = URL(string: endpointRaw) else {
            throw CloudASREngineError.invalidEndpoint(endpointRaw)
        }

        let appKey = settings.string(forKey: SettingsKeys.cloudAPIAppKey, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty else {
            throw CloudASREngineError.missingConfiguration("app_key")
        }
        let accessKey = settings.string(forKey: SettingsKeys.cloudAPIKey, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKey.isEmpty else {
            throw CloudASREngineError.missingConfiguration("access_key")
        }
        let modelRaw = settings.string(forKey: SettingsKeys.cloudAPIModel, default: "bigmodel")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (modelRaw.isEmpty || modelRaw == "whisper-1") ? "bigmodel" : modelRaw
        let resourceID = settings.string(
            forKey: SettingsKeys.cloudAPIResourceID,
            default: "volc.seedasr.sauc.duration"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let wsURL = try websocketURL(from: endpointURL, resourceID: resourceID, appKey: appKey, accessKey: accessKey)
        var request = URLRequest(url: wsURL, timeoutInterval: 50)
        request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        let fullRequest: [String: Any] = [
            "user": ["uid": appKey],
            "audio": [
                "format": "pcm",
                "rate": 16_000,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": model,
                "show_utterances": true
            ]
        ]
        let fullRequestData = try JSONSerialization.data(withJSONObject: fullRequest, options: [])
        try sendDataSync(task: task, data: encodePacket(messageType: 0b0001, payload: fullRequestData))

        queue.sync {
            self.onText = onText
            self.onError = onError
            self.recordingURL = recordingURL
            self.lastSentFrame = 0
            self.latestText = ""
            self.urlSession = session
            self.webSocketTask = task
            self.isRunning = true
        }

        startReceiveLoop()
        startFeedLoop()
    }

    public func stop() {
        queue.async {
            if let continuation = self.finalizeContinuation {
                self.finishStreamingFinalization(
                    result: .failure(CloudASREngineError.requestFailed("stream finalization canceled")),
                    continuation: continuation,
                    clearLatestText: true
                )
                return
            }
            guard self.isRunning else { return }
            self.teardownSession(clearLatestText: true)
        }
    }

    public func latestTranscriptText() -> String {
        queue.sync {
            latestText
        }
    }

    public func finish(timeoutMs: Int = 1500, quietPeriodMs: Int = 260) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.finalizeContinuation == nil else {
                    continuation.resume(throwing: CloudStreamingFinalizationError.alreadyInProgress)
                    return
                }
                guard self.isRunning, self.webSocketTask != nil else {
                    continuation.resume(throwing: CloudStreamingFinalizationError.sessionUnavailable)
                    return
                }

                self.isFinalizing = true
                self.receivedPostFinalizeTranscript = false
                self.finalizeContinuation = continuation
                self.feedTimer?.cancel()
                self.feedTimer = nil

                self.feedIncrementalAudio()

                let timeoutWorkItem = DispatchWorkItem { [weak self] in
                    self?.completeStreamingFinalizationOnTimeout()
                }
                self.finalizeTimeoutWorkItem = timeoutWorkItem
                self.queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeoutWorkItem)

                // If the server quickly echoes a final hypothesis, we resolve after a short quiet window.
                self.scheduleFinalizeQuietResolution(afterMs: quietPeriodMs)
            }
        }
    }

    private func startFeedLoop() {
        queue.async {
            guard self.isRunning else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(120))
            timer.setEventHandler { [weak self] in
                self?.feedIncrementalAudio()
            }
            self.feedTimer = timer
            timer.resume()
        }
    }

    private func feedIncrementalAudio() {
        guard isRunning, let task = webSocketTask, let recordingURL else { return }

        do {
            let pcmDelta = try readIncrementalPCMData(from: recordingURL)
            guard !pcmDelta.isEmpty else { return }

            let packetSize = 3200 * 2 // 100ms chunk @16kHz/16bit/mono
            var cursor = 0
            while cursor < pcmDelta.count {
                let end = min(cursor + packetSize, pcmDelta.count)
                let chunk = pcmDelta.subdata(in: cursor..<end)
                try sendDataSync(task: task, data: encodePacket(messageType: 0b0010, payload: chunk))
                cursor = end
            }
        } catch {
            reportErrorAndStop(error)
        }
    }

    private func startReceiveLoop() {
        queue.async {
            guard self.isRunning, let task = self.webSocketTask else { return }
            task.receive { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard self.isRunning else { return }
                    switch result {
                    case .failure(let error):
                        self.handleReceiveFailure(error)
                    case .success(let message):
                        self.handleIncomingMessage(message)
                        self.startReceiveLoop()
                    }
                }
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            do {
                guard let parsed = try parseResponsePacket(data) else { return }
                if parsed.messageType == 0b1111 {
                    let body = String(data: parsed.payloadJSONData, encoding: .utf8) ?? "<binary>"
                    reportErrorAndStop(CloudASREngineError.httpStatus(code: 400, body: body))
                    return
                }
                if let text = extractTextLeniently(from: parsed.payloadJSONData) {
                    publishTextIfNeeded(text)
                }
            } catch {
                reportErrorAndStop(error)
            }
        case .string(let text):
            if let extracted = extractTextLeniently(from: Data(text.utf8)) {
                publishTextIfNeeded(extracted)
            }
        @unknown default:
            break
        }
    }

    private func publishTextIfNeeded(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let changed = cleaned != latestText
        latestText = cleaned
        if isFinalizing {
            receivedPostFinalizeTranscript = true
            scheduleFinalizeQuietResolution()
        }
        if changed {
            onText?(cleaned)
        }
    }

    private func reportErrorAndStop(_ error: Error) {
        if finalizeContinuation != nil {
            finishStreamingFinalization(result: .failure(error), clearLatestText: true)
            return
        }
        onError?(error)
        stop()
    }

    private func handleReceiveFailure(_ error: Error) {
        if finalizeContinuation != nil {
            if receivedPostFinalizeTranscript, !latestText.isEmpty {
                finishStreamingFinalization(result: .success(latestText), clearLatestText: false)
            } else {
                finishStreamingFinalization(
                    result: .failure(CloudASREngineError.requestFailed(error.localizedDescription)),
                    clearLatestText: true
                )
            }
            return
        }
        reportErrorAndStop(CloudASREngineError.requestFailed(error.localizedDescription))
    }

    private func scheduleFinalizeQuietResolution(afterMs: Int = 260) {
        guard finalizeContinuation != nil else { return }
        finalizeQuietWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.completeStreamingFinalizationAfterQuietPeriod()
        }
        finalizeQuietWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: workItem)
    }

    private func completeStreamingFinalizationAfterQuietPeriod() {
        guard finalizeContinuation != nil else { return }
        guard receivedPostFinalizeTranscript, !latestText.isEmpty else { return }
        finishStreamingFinalization(result: .success(latestText), clearLatestText: false)
    }

    private func completeStreamingFinalizationOnTimeout() {
        guard finalizeContinuation != nil else { return }
        if receivedPostFinalizeTranscript, !latestText.isEmpty {
            finishStreamingFinalization(result: .success(latestText), clearLatestText: false)
        } else {
            finishStreamingFinalization(
                result: .failure(CloudStreamingFinalizationError.noPostFinalizeTranscript),
                clearLatestText: false
            )
        }
    }

    private func finishStreamingFinalization(
        result: Result<String, Error>,
        continuation: CheckedContinuation<String, Error>? = nil,
        clearLatestText: Bool
    ) {
        let resolvedContinuation = continuation ?? finalizeContinuation
        guard let resolvedContinuation else { return }

        finalizeQuietWorkItem?.cancel()
        finalizeQuietWorkItem = nil
        finalizeTimeoutWorkItem?.cancel()
        finalizeTimeoutWorkItem = nil
        finalizeContinuation = nil
        isFinalizing = false
        receivedPostFinalizeTranscript = false
        teardownSession(clearLatestText: clearLatestText)

        switch result {
        case .success(let text):
            resolvedContinuation.resume(returning: text)
        case .failure(let error):
            resolvedContinuation.resume(throwing: error)
        }
    }

    private func teardownSession(clearLatestText: Bool) {
        isRunning = false
        feedTimer?.cancel()
        feedTimer = nil
        finalizeQuietWorkItem?.cancel()
        finalizeQuietWorkItem = nil
        finalizeTimeoutWorkItem?.cancel()
        finalizeTimeoutWorkItem = nil
        recordingURL = nil
        if clearLatestText {
            latestText = ""
        }
        onText = nil
        onError = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func websocketURL(
        from sourceURL: URL,
        resourceID: String,
        appKey: String,
        accessKey: String
    ) throws -> URL {
        guard var resolved = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw CloudASREngineError.invalidEndpoint(sourceURL.absoluteString)
        }

        let path = resolved.path.lowercased()
        guard path.contains("/api/v3/sauc/bigmodel") else {
            throw CloudASREngineError.invalidEndpoint(sourceURL.absoluteString)
        }

        let scheme = (resolved.scheme ?? "").lowercased()
        switch scheme {
        case "wss", "ws":
            break
        case "https":
            resolved.scheme = "wss"
        case "http":
            resolved.scheme = "ws"
        default:
            throw CloudASREngineError.unsupportedEndpointScheme(scheme)
        }

        var query = resolved.queryItems ?? []
        upsertQueryItem(name: "api_resource_id", value: resourceID, in: &query)
        upsertQueryItem(name: "api_app_key", value: appKey, in: &query)
        upsertQueryItem(name: "api_access_key", value: accessKey, in: &query)
        resolved.queryItems = query

        guard let finalURL = resolved.url else {
            throw CloudASREngineError.invalidEndpoint(sourceURL.absoluteString)
        }
        return finalURL
    }

    private func upsertQueryItem(name: String, value: String, in queryItems: inout [URLQueryItem]) {
        if let index = queryItems.firstIndex(where: { $0.name == name }) {
            queryItems[index] = URLQueryItem(name: name, value: value)
        } else {
            queryItems.append(URLQueryItem(name: name, value: value))
        }
    }

    private func sendDataSync(task: URLSessionWebSocketTask, data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = WebSocketSendResultBox()
        task.send(.data(data)) { error in
            box.error = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        if let error = box.error {
            throw CloudASREngineError.requestFailed(error.localizedDescription)
        }
    }

    private func encodePacket(messageType: UInt8, payload: Data) -> Data {
        var header = Data(repeating: 0, count: 8)
        header[0] = (0b0001 << 4) | 0b0001
        header[1] = (messageType << 4) | 0b0000
        header[2] = (0b0001 << 4) | 0b0000
        header[3] = 0
        let payloadLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: payloadLength) { bytes in
            header.replaceSubrange(4..<8, with: bytes)
        }
        return header + payload
    }

    private struct ParsedMessage {
        let messageType: UInt8
        let payloadJSONData: Data
    }

    private func parseResponsePacket(_ data: Data) throws -> ParsedMessage? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        let headerSizeWords = Int(bytes[0] & 0x0f)
        let messageType = bytes[1] >> 4
        let messageFlags = bytes[1] & 0x0f
        let descriptionLength = messageType == 0b1111 ? 8 : 4
        let sequenceLength = (messageFlags == 0b0001 || messageFlags == 0b0011) ? 4 : 0
        let payloadOffset = headerSizeWords * 4 + descriptionLength + sequenceLength
        guard payloadOffset <= data.count else { return nil }
        let payload = data.subdata(in: payloadOffset..<data.count)
        return ParsedMessage(messageType: messageType, payloadJSONData: payload)
    }

    private func extractTextLeniently(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let text = json["text"] as? String, !text.isEmpty {
            return text
        }
        if let result = json["result"] as? [String: Any], let text = result["text"] as? String, !text.isEmpty {
            return text
        }
        if let utterances = json["utterances"] as? [[String: Any]], let last = utterances.last {
            if let text = last["text"] as? String, !text.isEmpty {
                return text
            }
        }
        if let payload = json["payload_msg"] as? [String: Any], let result = payload["result"] as? [String: Any] {
            if let text = result["text"] as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func readIncrementalPCMData(from recordingURL: URL) throws -> Data {
        let audioFile = try AVAudioFile(forReading: recordingURL)
        let totalFrames = audioFile.length
        if totalFrames <= lastSentFrame {
            return Data()
        }

        audioFile.framePosition = lastSentFrame
        var output = Data()
        let maxFramesPerRead: AVAudioFrameCount = 2048
        while audioFile.framePosition < totalFrames {
            let remaining = totalFrames - audioFile.framePosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(maxFramesPerRead), remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCount
            ) else { break }
            try audioFile.read(into: buffer, frameCount: frameCount)
            if buffer.frameLength == 0 { break }
            output.append(convertBufferToPCM16Mono(buffer))
        }
        lastSentFrame = totalFrames
        return output
    }

    private func convertBufferToPCM16Mono(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return Data() }

        if let int16Channels = buffer.int16ChannelData {
            let channel = int16Channels[0]
            let byteCount = frameCount * MemoryLayout<Int16>.size
            return Data(bytes: channel, count: byteCount)
        }

        if let floatChannels = buffer.floatChannelData {
            let channel = floatChannels[0]
            var pcm = Data(capacity: frameCount * MemoryLayout<Int16>.size)
            for i in 0..<frameCount {
                let sample = max(-1.0, min(1.0, channel[i]))
                var intSample = Int16(sample * 32767.0)
                withUnsafeBytes(of: &intSample) { pcm.append(contentsOf: $0) }
            }
            return pcm
        }

        if let int32Channels = buffer.int32ChannelData {
            let channel = int32Channels[0]
            var pcm = Data(capacity: frameCount * MemoryLayout<Int16>.size)
            for i in 0..<frameCount {
                let shifted = channel[i] >> 16
                var intSample = Int16(clamping: Int(shifted))
                withUnsafeBytes(of: &intSample) { pcm.append(contentsOf: $0) }
            }
            return pcm
        }

        return Data()
    }
}
