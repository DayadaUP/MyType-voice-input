import Foundation
import AVFoundation
import Common
import Settings

public protocol ASREngine: Sendable {
    func transcribe(audioFileURL: URL) throws -> RecognitionResult
}

public enum ASREngineError: LocalizedError {
    case audioFileMissing(URL)
    case scriptMissing(URL)
    case pythonExecutionFailed(String)
    case processFailed(code: Int32, stderr: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .audioFileMissing(let url):
            return "Audio file does not exist: \(url.path)"
        case .scriptMissing(let url):
            return "ASR script not found: \(url.path)"
        case .pythonExecutionFailed(let details):
            return "Failed to run python process: \(details)"
        case .processFailed(let code, let stderr):
            return "ASR process failed with code \(code): \(stderr)"
        case .invalidResponse(let value):
            return "ASR output is not valid JSON: \(value)"
        }
    }
}

public struct FasterWhisperConfiguration: Sendable {
    public var pythonPath: String
    public var scriptURL: URL
    public var modelSize: String
    public var device: String
    public var computeType: String
    public var beamSize: Int
    public var language: String?
    public var modelDirectoryURL: URL?

    public init(
        pythonPath: String,
        scriptURL: URL,
        modelSize: String = "small",
        device: String = "auto",
        computeType: String = "int8",
        beamSize: Int = 5,
        language: String? = nil,
        modelDirectoryURL: URL? = nil
    ) {
        self.pythonPath = pythonPath
        self.scriptURL = scriptURL
        self.modelSize = modelSize
        self.device = device
        self.computeType = computeType
        self.beamSize = beamSize
        self.language = language
        self.modelDirectoryURL = modelDirectoryURL
    }

    public static func defaultForPackage() -> FasterWhisperConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let packageRoot = sourcePackageRootURL()
        let applicationSupportASRRoot = applicationSupportASRRootURL()
        let bundledASRRoot = bundledASRRootURL()
        let scriptURL = resolvedScriptURL(
            environment: environment,
            bundledASRRoot: bundledASRRoot,
            packageRoot: packageRoot
        )
        let pythonPath = resolvedPythonPath(
            environment: environment,
            applicationSupportASRRoot: applicationSupportASRRoot,
            bundledASRRoot: bundledASRRoot,
            packageRoot: packageRoot
        )
        let modelDirectoryURL = resolvedModelDirectoryURL(
            environment: environment,
            applicationSupportASRRoot: applicationSupportASRRoot,
            bundledASRRoot: bundledASRRoot,
            packageRoot: packageRoot
        )
        return FasterWhisperConfiguration(
            pythonPath: pythonPath,
            scriptURL: scriptURL,
            modelSize: environment["MYTYPE_ASR_MODEL"] ?? "small",
            device: environment["MYTYPE_ASR_DEVICE"] ?? "auto",
            computeType: environment["MYTYPE_ASR_COMPUTE_TYPE"] ?? "int8",
            beamSize: Int(environment["MYTYPE_ASR_BEAM_SIZE"] ?? "5") ?? 5,
            language: environment["MYTYPE_ASR_LANGUAGE"],
            modelDirectoryURL: modelDirectoryURL
        )
    }

    public static func sourcePackageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ASRAdapter
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // mac-ime
    }

    public static func bundledASRRootURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("ASR", isDirectory: true),
            resourceURL
        ]
        return firstExistingDirectory(in: candidates) ?? candidates.first
    }

    public static func applicationSupportASRRootURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL
            .appendingPathComponent("MyType", isDirectory: true)
            .appendingPathComponent("ASR", isDirectory: true)
    }

    private static func resolvedScriptURL(
        environment: [String: String],
        bundledASRRoot: URL?,
        packageRoot: URL
    ) -> URL {
        if let overridePath = normalizedEnvironmentValue(environment["MYTYPE_ASR_SCRIPT"]) {
            return URL(fileURLWithPath: overridePath)
        }

        let candidates = [
            bundledASRRoot?.appendingPathComponent("faster_whisper_transcribe.py"),
            packageRoot.appendingPathComponent("Scripts/faster_whisper_transcribe.py")
        ].compactMap { $0 }

        return firstExistingFile(in: candidates)
            ?? candidates.last
            ?? packageRoot.appendingPathComponent("Scripts/faster_whisper_transcribe.py")
    }

    private static func resolvedPythonPath(
        environment: [String: String],
        applicationSupportASRRoot: URL?,
        bundledASRRoot: URL?,
        packageRoot: URL
    ) -> String {
        if let overridePath = normalizedEnvironmentValue(environment["MYTYPE_ASR_PYTHON"]) {
            return overridePath
        }

        var candidates: [String] = []
        if let applicationSupportASRRoot {
            candidates.append(
                applicationSupportASRRoot
                    .appendingPathComponent(".venv/bin/python3")
                    .path(percentEncoded: false)
            )
        }
        if let bundledASRRoot {
            candidates.append(
                bundledASRRoot
                    .appendingPathComponent(".venv/bin/python3")
                    .path(percentEncoded: false)
            )
        }
        candidates.append(
            packageRoot
                .appendingPathComponent(".venv/bin/python3")
                .path(percentEncoded: false)
        )
        candidates.append("/usr/bin/python3")

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3"
    }

    private static func resolvedModelDirectoryURL(
        environment: [String: String],
        applicationSupportASRRoot: URL?,
        bundledASRRoot: URL?,
        packageRoot: URL
    ) -> URL? {
        if let overridePath = normalizedEnvironmentValue(environment["MYTYPE_ASR_MODEL_DIR"]) {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }

        let candidates = [
            applicationSupportASRRoot?.appendingPathComponent(".models", isDirectory: true),
            bundledASRRoot?.appendingPathComponent(".models", isDirectory: true),
            packageRoot.appendingPathComponent(".models", isDirectory: true)
        ].compactMap { $0 }

        return firstExistingDirectory(in: candidates)
    }

    private static func firstExistingFile(in candidates: [URL]) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func firstExistingDirectory(in candidates: [URL]) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func normalizedEnvironmentValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum ASRModelSize: String, CaseIterable, Sendable {
    case tiny
    case small
}

public enum ChineseScriptMode: String, CaseIterable, Sendable {
    case simplified
    case traditional
}

public enum RecognitionMode: String, CaseIterable, Sendable {
    case local
    case cloud
    case hybrid
    case auto
}

public enum LivePreviewSource: String, CaseIterable, Sendable {
    case local
    case cloud
}

public enum RecordingDurationLimit: String, CaseIterable, Sendable {
    case s60
    case s120
    case s180
    case unlimited

    public var seconds: TimeInterval? {
        switch self {
        case .s60:
            return 60
        case .s120:
            return 120
        case .s180:
            return 180
        case .unlimited:
            return nil
        }
    }
}

private struct ASRScriptOutput: Decodable {
    let text: String
    let latencyMs: Int?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case text
        case latencyMs = "latency_ms"
        case language
    }
}

public final class FasterWhisperASREngine: ASREngine, @unchecked Sendable {
    private var configuration: FasterWhisperConfiguration
    private var overrideModelSize: ASRModelSize?
    private var chineseScriptMode: ChineseScriptMode = .simplified

    public init(configuration: FasterWhisperConfiguration = .defaultForPackage()) {
        self.configuration = configuration
    }

    public func setModelSize(_ modelSize: ASRModelSize) {
        overrideModelSize = modelSize
    }

    public func setChineseScriptMode(_ mode: ChineseScriptMode) {
        chineseScriptMode = mode
    }

    public func refreshConfiguration(_ configuration: FasterWhisperConfiguration = .defaultForPackage()) {
        self.configuration = configuration
    }

    public func transcribe(audioFileURL: URL) throws -> RecognitionResult {
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw ASREngineError.audioFileMissing(audioFileURL)
        }
        guard FileManager.default.fileExists(atPath: configuration.scriptURL.path) else {
            throw ASREngineError.scriptMissing(configuration.scriptURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.pythonPath)
        process.arguments = buildArguments(audioFileURL: audioFileURL)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let started = Date()
        do {
            try process.run()
        } catch {
            throw ASREngineError.pythonExecutionFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw ASREngineError.processFailed(code: process.terminationStatus, stderr: stderrText)
        }

        guard let outputText = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !outputText.isEmpty else {
            throw ASREngineError.invalidResponse("Empty output")
        }

        let parsed: ASRScriptOutput
        do {
            parsed = try JSONDecoder().decode(ASRScriptOutput.self, from: stdoutData)
        } catch {
            throw ASREngineError.invalidResponse(outputText)
        }

        let measuredLatencyMs = Int(Date().timeIntervalSince(started) * 1000.0)
        let latency = parsed.latencyMs ?? measuredLatencyMs
        _ = parsed.language // reserved for follow-up UI display

        return RecognitionResult(
            rawText: parsed.text.trimmingCharacters(in: .whitespacesAndNewlines),
            latencyMs: max(0, latency),
            engineRoute: "local_faster_whisper"
        )
    }

    private func buildArguments(audioFileURL: URL) -> [String] {
        var args = [
            configuration.scriptURL.path,
            "--audio", audioFileURL.path,
            "--model", (overrideModelSize?.rawValue ?? configuration.modelSize),
            "--device", configuration.device,
            "--compute-type", configuration.computeType,
            "--beam-size", String(configuration.beamSize),
            "--chinese-script", chineseScriptMode.rawValue
        ]

        if let language = configuration.language, !language.isEmpty {
            args.append(contentsOf: ["--language", language])
        }
        if let modelDirectoryURL = configuration.modelDirectoryURL {
            args.append(contentsOf: ["--model-dir", modelDirectoryURL.path])
        }

        return args
    }
}

public enum CloudASREngineError: LocalizedError {
    case invalidEndpoint(String)
    case unsupportedEndpointScheme(String)
    case missingConfiguration(String)
    case audioReadFailed(String)
    case requestFailed(String)
    case httpStatus(code: Int, body: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Cloud endpoint is invalid: \(endpoint)"
        case .unsupportedEndpointScheme(let scheme):
            return "Cloud endpoint scheme '\(scheme)' is not supported. Use http/https endpoint, or Doubao endpoints under openspeech.bytedance.com (/api/v3/sauc/bigmodel[_async] or /api/v3/auc/bigmodel/*)."
        case .missingConfiguration(let message):
            return "Cloud ASR configuration missing: \(message)"
        case .audioReadFailed(let details):
            return "Failed to read audio file: \(details)"
        case .requestFailed(let details):
            return "Cloud ASR request failed: \(details)"
        case .httpStatus(let code, let body):
            return "Cloud ASR returned HTTP \(code): \(body)"
        case .invalidResponse(let details):
            return "Cloud ASR response is invalid: \(details)"
        }
    }
}

public final class CloudASREngine: ASREngine, @unchecked Sendable {
    private final class RequestResultBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    private final class WebSocketSendResultBox: @unchecked Sendable {
        var error: Error?
    }

    private final class WebSocketReceiveResultBox: @unchecked Sendable {
        var result: Result<URLSessionWebSocketTask.Message, Error>?
    }

    private let settings: SettingsStore
    private static let maxCloudLogEntries = 6000
    private let hotwordsProvider: () -> [String]
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public init(
        settings: SettingsStore,
        hotwordsProvider: @escaping () -> [String] = { [] }
    ) {
        self.settings = settings
        self.hotwordsProvider = hotwordsProvider
    }

    private func makeRecognitionResult(
        text: String,
        latencyMs: Int,
        engineRoute: String
    ) -> RecognitionResult {
        RecognitionResult(
            rawText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            latencyMs: max(0, latencyMs),
            engineRoute: engineRoute
        )
    }

    public func transcribe(audioFileURL: URL) throws -> RecognitionResult {
        let endpoint = settings.string(forKey: SettingsKeys.cloudAPIEndpoint, default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = settings.string(forKey: SettingsKeys.cloudAPIKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.string(forKey: SettingsKeys.cloudAPIModel, default: "whisper-1").trimmingCharacters(in: .whitespacesAndNewlines)
        let hotwords = normalizedCloudHotwords()

        guard !endpoint.isEmpty else {
            throw CloudASREngineError.missingConfiguration("endpoint")
        }
        guard let url = URL(string: endpoint) else {
            throw CloudASREngineError.invalidEndpoint(endpoint)
        }
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw ASREngineError.audioFileMissing(audioFileURL)
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw CloudASREngineError.audioReadFailed(error.localizedDescription)
        }
        let audioDurationSeconds = estimateAudioDurationSeconds(from: audioFileURL)
        let startedAt = Date()

        if shouldUseDoubaoStreamingAdapter(endpointURL: url) {
            return try transcribeViaDoubaoStreaming(
                sourceEndpointURL: url,
                audioFileURL: audioFileURL,
                fallbackAudioData: audioData,
                accessKey: apiKey,
                model: model,
                hotwords: hotwords,
                audioDurationSeconds: audioDurationSeconds,
                startedAt: startedAt
            )
        }

        if shouldUseDoubaoFlashAdapter(endpointURL: url) {
            return try transcribeViaDoubaoFlash(
                sourceEndpointURL: url,
                audioFileURL: audioFileURL,
                fallbackAudioData: audioData,
                accessKey: apiKey,
                model: model,
                hotwords: hotwords,
                audioDurationSeconds: audioDurationSeconds,
                startedAt: startedAt
            )
        }

        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw CloudASREngineError.unsupportedEndpointScheme(scheme)
        }

        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": model.isEmpty ? "whisper-1" : model,
            "audio_base64": audioData.base64EncodedString(),
            "audio_format": audioFileURL.pathExtension.lowercased()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try performSync(request: request)
        } catch {
            appendCloudRequestLog(
                status: "ERROR",
                durationSeconds: audioDurationSeconds,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
            )
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudASREngineError.invalidResponse("non-http response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            appendCloudRequestLog(
                status: "HTTP\(httpResponse.statusCode)",
                durationSeconds: audioDurationSeconds,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
            )
            throw CloudASREngineError.httpStatus(code: httpResponse.statusCode, body: body)
        }

        let rawText = try extractText(from: data)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
        appendCloudRequestLog(
            status: "OK",
            durationSeconds: audioDurationSeconds,
            latencyMs: latencyMs,
            estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
        )
        return makeRecognitionResult(
            text: rawText,
            latencyMs: latencyMs,
            engineRoute: "cloud_http_post"
        )
    }

    private func shouldUseDoubaoFlashAdapter(endpointURL: URL) -> Bool {
        let host = endpointURL.host?.lowercased() ?? ""
        guard host.contains("openspeech.bytedance.com") else { return false }

        let path = endpointURL.path.lowercased()
        return path.contains("/api/v3/auc/bigmodel")
    }

    private func shouldUseDoubaoStreamingAdapter(endpointURL: URL) -> Bool {
        let host = endpointURL.host?.lowercased() ?? ""
        guard host.contains("openspeech.bytedance.com") else { return false }

        let path = endpointURL.path.lowercased()
        return path.contains("/api/v3/sauc/bigmodel")
    }

    private func transcribeViaDoubaoStreaming(
        sourceEndpointURL: URL,
        audioFileURL: URL,
        fallbackAudioData: Data,
        accessKey: String,
        model: String,
        hotwords: [String],
        audioDurationSeconds: Double,
        startedAt: Date
    ) throws -> RecognitionResult {
        let appKey = settings.string(forKey: SettingsKeys.cloudAPIAppKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredResourceID = settings.string(
            forKey: SettingsKeys.cloudAPIResourceID,
            default: "volc.seedasr.sauc.duration"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appKey.isEmpty else {
            throw CloudASREngineError.missingConfiguration("app_key")
        }
        guard !accessKey.isEmpty else {
            throw CloudASREngineError.missingConfiguration("access_key")
        }

        let pcmData = prepareDoubaoStreamingPCMData(audioFileURL: audioFileURL, fallbackData: fallbackAudioData)
        guard !pcmData.isEmpty else {
            throw CloudASREngineError.invalidResponse("streaming pcm payload is empty")
        }

        let resourceCandidates = doubaoResourceCandidates(
            configured: configuredResourceID,
            sourceEndpointURL: sourceEndpointURL
        )
        let accessKeyCandidates = doubaoAccessKeyCandidates(accessKey)

        var lastError: CloudASREngineError?
        var triedResources: [String] = []

        for candidateResourceID in resourceCandidates {
            for candidateAccessKey in accessKeyCandidates {
                triedResources.append(candidateResourceID)
                let hotwordVariants: [[String]] = hotwords.isEmpty ? [[]] : [hotwords, []]
                for variant in hotwordVariants {
                    do {
                        let rawText = try performDoubaoStreamingSession(
                            endpointURL: sourceEndpointURL,
                            pcmData: pcmData,
                            appKey: appKey,
                            accessKey: candidateAccessKey,
                            resourceID: candidateResourceID,
                            model: model.isEmpty ? "bigmodel" : model,
                            hotwords: variant
                        )
                        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                        let hotwordSuffix = variant.isEmpty ? "" : "-HW\(variant.count)"
                        appendCloudRequestLog(
                            status: "OK-DOUBAO-STREAM\(hotwordSuffix)(\(candidateResourceID))",
                            durationSeconds: audioDurationSeconds,
                            latencyMs: latencyMs,
                            estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                        )
                        if candidateResourceID != configuredResourceID {
                            settings.set(candidateResourceID, forKey: SettingsKeys.cloudAPIResourceID)
                        }
                        return makeRecognitionResult(
                            text: rawText,
                            latencyMs: latencyMs,
                            engineRoute: "cloud_doubao_sauc_batch"
                        )
                    } catch let error as CloudASREngineError {
                        lastError = error
                        if case let .httpStatus(code, body) = error,
                           (code == 400 || code == 403),
                           isDoubaoResourceNotGranted(body: body) {
                            appendCloudRequestLog(
                                status: "HTTP\(code)-DOUBAO-STREAM-DENIED(\(candidateResourceID))",
                                durationSeconds: audioDurationSeconds,
                                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                                estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                            )
                            break
                        }
                        if !variant.isEmpty,
                           case let .httpStatus(code, body) = error,
                           shouldRetryDoubaoWithoutHotwords(code: code, body: body) {
                            appendCloudRequestLog(
                                status: "HTTP\(code)-DOUBAO-STREAM-HW-RETRY(\(candidateResourceID))",
                                durationSeconds: audioDurationSeconds,
                                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                                estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                            )
                            continue
                        }
                        throw error
                    }
                }
            }
        }

        let defaultBody = "resource not granted"
        let finalError: CloudASREngineError
        if case let .httpStatus(code, body) = lastError {
            finalError = .httpStatus(
                code: code,
                body: "\(body) | tried_resource_ids=" + triedResources.joined(separator: ",")
            )
        } else {
            finalError = .httpStatus(
                code: 403,
                body: defaultBody + " | tried_resource_ids=" + triedResources.joined(separator: ",")
            )
        }

        appendCloudRequestLog(
            status: "HTTP400-DOUBAO-STREAM-ALL-RESOURCE-DENIED",
            durationSeconds: audioDurationSeconds,
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
            estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
        )
        throw finalError
    }

    private func transcribeViaDoubaoFlash(
        sourceEndpointURL: URL,
        audioFileURL: URL,
        fallbackAudioData: Data,
        accessKey: String,
        model: String,
        hotwords: [String],
        audioDurationSeconds: Double,
        startedAt: Date
    ) throws -> RecognitionResult {
        let appKey = settings.string(forKey: SettingsKeys.cloudAPIAppKey, default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredResourceID = settings.string(
            forKey: SettingsKeys.cloudAPIResourceID,
            default: "volc.bigasr.auc_turbo"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appKey.isEmpty else {
            throw CloudASREngineError.missingConfiguration("app_key")
        }
        guard !accessKey.isEmpty else {
            throw CloudASREngineError.missingConfiguration("access_key")
        }

        let flashURL = URL(
            string: "https://\(sourceEndpointURL.host ?? "openspeech.bytedance.com")/api/v3/auc/bigmodel/recognize/flash"
        )!

        let payloadAudio = prepareDoubaoAudioPayload(
            audioFileURL: audioFileURL,
            fallbackData: fallbackAudioData
        )
        let resourceCandidates = doubaoResourceCandidates(
            configured: configuredResourceID,
            sourceEndpointURL: sourceEndpointURL
        )

        var lastHTTPError: (code: Int, body: String)?
        var triedResources: [String] = []
        resourceLoop: for resourceID in resourceCandidates {
            triedResources.append(resourceID)
            let hotwordVariants: [[String]] = hotwords.isEmpty ? [[]] : [hotwords, []]
            for variant in hotwordVariants {
                let requestBody: [String: Any] = [
                    "user": ["uid": appKey],
                    "audio": [
                        "format": payloadAudio.format,
                        "data": payloadAudio.data.base64EncodedString()
                    ],
                    "request": doubaoRequestSection(
                        model: (model.isEmpty || model == "whisper-1") ? "bigmodel" : model,
                        showUtterances: nil,
                        hotwords: variant
                    )
                ]
                let requestBodyData = try JSONSerialization.data(withJSONObject: requestBody, options: [])

                var request = URLRequest(url: flashURL, timeoutInterval: 50)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
                request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
                request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
                request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
                request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
                request.httpBody = requestBodyData

                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try performSync(request: request)
                } catch {
                    appendCloudRequestLog(
                        status: "ERROR-DOUBAO",
                        durationSeconds: audioDurationSeconds,
                        latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                        estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                    )
                    throw error
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CloudASREngineError.invalidResponse("non-http response")
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    let rawText = try extractText(from: data)
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                    let hotwordSuffix = variant.isEmpty ? "" : "-HW\(variant.count)"
                    appendCloudRequestLog(
                        status: "OK-DOUBAO\(hotwordSuffix)(\(resourceID))",
                        durationSeconds: audioDurationSeconds,
                        latencyMs: latencyMs,
                        estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                    )
                    if resourceID != configuredResourceID {
                        settings.set(resourceID, forKey: SettingsKeys.cloudAPIResourceID)
                    }
                    return makeRecognitionResult(
                        text: rawText,
                        latencyMs: latencyMs,
                        engineRoute: "cloud_doubao_flash"
                    )
                }

                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                lastHTTPError = (httpResponse.statusCode, body)
                if !variant.isEmpty,
                   shouldRetryDoubaoWithoutHotwords(code: httpResponse.statusCode, body: body) {
                    appendCloudRequestLog(
                        status: "HTTP\(httpResponse.statusCode)-DOUBAO-HW-RETRY(\(resourceID))",
                        durationSeconds: audioDurationSeconds,
                        latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                        estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                    )
                    continue
                }
                if (httpResponse.statusCode == 400 || httpResponse.statusCode == 403),
                   isDoubaoResourceNotGranted(body: body) {
                    appendCloudRequestLog(
                        status: "HTTP\(httpResponse.statusCode)-DOUBAO-DENIED(\(resourceID))",
                        durationSeconds: audioDurationSeconds,
                        latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                        estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                    )
                    continue resourceLoop
                }
                appendCloudRequestLog(
                    status: "HTTP\(httpResponse.statusCode)-DOUBAO(\(resourceID))",
                    durationSeconds: audioDurationSeconds,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
                    estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
                )
                throw CloudASREngineError.httpStatus(code: httpResponse.statusCode, body: body)
            }
        }

        let code = lastHTTPError?.code ?? 403
        let body = (lastHTTPError?.body ?? "resource not granted") + " | tried_resource_ids=" + triedResources.joined(separator: ",")
        appendCloudRequestLog(
            status: "HTTP\(code)-DOUBAO-ALL-RESOURCE-DENIED",
            durationSeconds: audioDurationSeconds,
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
            estimatedCostCNY: estimatedCostCNY(durationSeconds: audioDurationSeconds)
        )
        throw CloudASREngineError.httpStatus(code: code, body: body)
    }

    private func doubaoResourceCandidates(configured: String, sourceEndpointURL: URL) -> [String] {
        var candidates: [String] = []
        if !configured.isEmpty {
            candidates.append(configured)
        }

        let path = sourceEndpointURL.path.lowercased()
        let isSauc = path.contains("/api/v3/sauc/")
        let isAuc = path.contains("/api/v3/auc/")

        if isSauc {
            let pathToken = sourceEndpointURL.path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
            if !pathToken.isEmpty {
                candidates.append("volc.bigasr.sauc.\(pathToken)")
            }
            if pathToken.contains("bigmodel_a") || path.contains("bigmodel_async") {
                candidates.append("volc.bigasr.sauc.bigmodel_a")
            }
            candidates.append("volc.bigasr.sauc.bigmodel")
            candidates.append("volc.bigasr.sauc.duration")
            candidates.append("volc.seedasr.sauc.duration")
            if configured.contains("concurrent") {
                candidates.append("volc.bigasr.sauc.concurrent")
                candidates.append("volc.seedasr.sauc.concurrent")
            }
        }

        if isAuc || !isSauc {
            candidates.append("volc.bigasr.auc_turbo")
            candidates.append("volc.seedasr.auc")
            candidates.append("volc.bigasr.auc")
        }

        var output: [String] = []
        var seen: Set<String> = []
        for item in candidates {
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if !seen.contains(normalized) {
                seen.insert(normalized)
                output.append(normalized)
            }
        }
        return output
    }

    private func doubaoAccessKeyCandidates(_ rawAccessKey: String) -> [String] {
        let trimmed = rawAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains(";") {
            return [trimmed]
        }
        var candidates: [String] = []
        candidates.append(trimmed)
        candidates.append("Bearer; \(trimmed)")
        candidates.append("Jwt; \(trimmed)")
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private func isDoubaoResourceNotGranted(body: String) -> Bool {
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

        if lower.contains("requested resource not granted") {
            return true
        }
        if (lower.contains("resourceid") || lower.contains("resource id") || lower.contains("resource_id")),
           (lower.contains("not allowed") || lower.contains("is not allowed")) {
            return true
        }
        if resourceMentioned && deniedSemantics && (lower.contains("45000030") || lower.contains("45000000")) {
            return true
        }
        return false
    }

    private func prepareDoubaoStreamingPCMData(audioFileURL: URL, fallbackData: Data) -> Data {
        let payloadAudio = prepareDoubaoAudioPayload(audioFileURL: audioFileURL, fallbackData: fallbackData)
        let format = payloadAudio.format.lowercased()
        if format == "pcm" {
            return payloadAudio.data
        }
        if let pcmFromWav = extractPCMFromWavData(payloadAudio.data) {
            return pcmFromWav
        }
        return payloadAudio.data
    }

    private func extractPCMFromWavData(_ wavData: Data) -> Data? {
        guard wavData.count > 44 else { return nil }
        if wavData.prefix(4) != Data([0x52, 0x49, 0x46, 0x46]) { // RIFF
            return nil
        }

        var offset = 12
        while offset + 8 <= wavData.count {
            let idRange = offset..<(offset + 4)
            let sizeRange = (offset + 4)..<(offset + 8)
            let chunkID = String(data: wavData[idRange], encoding: .ascii) ?? ""
            let chunkSize = Int(littleEndianUInt32(from: wavData[sizeRange]))
            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + chunkSize
            guard chunkDataEnd <= wavData.count else { break }

            if chunkID == "data" {
                return wavData.subdata(in: chunkDataStart..<chunkDataEnd)
            }

            offset = chunkDataEnd
            if offset % 2 != 0 {
                offset += 1
            }
        }
        return wavData.count > 44 ? wavData.subdata(in: 44..<wavData.count) : nil
    }

    private func littleEndianUInt32(from data: Data.SubSequence) -> UInt32 {
        let bytes = Array(data)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    private func performDoubaoStreamingSession(
        endpointURL: URL,
        pcmData: Data,
        appKey: String,
        accessKey: String,
        resourceID: String,
        model: String,
        hotwords: [String]
    ) throws -> String {
        let authedURL = buildDoubaoStreamingURL(
            endpointURL: endpointURL,
            appKey: appKey,
            accessKey: accessKey,
            resourceID: resourceID
        )

        var request = URLRequest(url: authedURL, timeoutInterval: 50)
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
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ],
            "request": doubaoRequestSection(
                model: model.isEmpty ? "bigmodel" : model,
                showUtterances: true,
                hotwords: hotwords
            )
        ]

        let fullRequestData = try JSONSerialization.data(withJSONObject: fullRequest, options: [])
        try sendWebSocketData(task: task, data: encodeDoubaoFullRequest(payload: fullRequestData))

        let chunkSize = 3200 * 2 // ~100ms, 16kHz mono 16bit
        var cursor = 0
        while cursor < pcmData.count {
            let end = min(cursor + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: cursor..<end)
            try sendWebSocketData(task: task, data: encodeDoubaoAudioPacket(payload: chunk))
            cursor = end
            usleep(35_000)
        }

        var latestText = ""
        var sawAnyMessage = false
        var idleCount = 0
        let receiveDeadline = Date().addingTimeInterval(4.0)

        while Date() < receiveDeadline, idleCount < 3 {
            switch receiveWebSocketMessage(task: task, timeout: 1.0) {
            case .timedOut:
                idleCount += 1
                continue
            case .failure(let error):
                if sawAnyMessage {
                    idleCount += 1
                    continue
                }
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                throw CloudASREngineError.requestFailed(error.localizedDescription)
            case .success(let message):
                sawAnyMessage = true
                idleCount = 0
                switch message {
                case .data(let data):
                    if let parsed = try parseDoubaoStreamingResponse(data: data) {
                        if parsed.messageType == 0b1111 {
                            let body = String(data: parsed.payloadJSONData, encoding: .utf8) ?? "<binary>"
                            task.cancel(with: .normalClosure, reason: nil)
                            session.invalidateAndCancel()
                            throw CloudASREngineError.httpStatus(code: 400, body: body)
                        }
                        if let text = extractTextLeniently(from: parsed.payloadJSONData) {
                            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleaned.isEmpty {
                                latestText = cleaned
                            }
                        }
                    }
                case .string(let text):
                    let jsonData = Data(text.utf8)
                    if let extracted = extractTextLeniently(from: jsonData)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !extracted.isEmpty {
                        latestText = extracted
                    }
                @unknown default:
                    continue
                }
            }
        }

        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()

        guard !latestText.isEmpty else {
            throw CloudASREngineError.invalidResponse("streaming response missing text")
        }
        return latestText
    }

    private func buildDoubaoStreamingURL(
        endpointURL: URL,
        appKey: String,
        accessKey: String,
        resourceID: String
    ) -> URL {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var queryItems = components.queryItems ?? []

        func setQuery(_ name: String, _ value: String) {
            if let index = queryItems.firstIndex(where: { $0.name == name }) {
                queryItems[index] = URLQueryItem(name: name, value: value)
            } else {
                queryItems.append(URLQueryItem(name: name, value: value))
            }
        }

        setQuery("api_resource_id", resourceID)
        setQuery("api_app_key", appKey)
        setQuery("api_access_key", accessKey)
        components.queryItems = queryItems
        return components.url ?? endpointURL
    }

    private func encodeDoubaoFullRequest(payload: Data) -> Data {
        encodeDoubaoPacket(messageType: 0b0001, payload: payload)
    }

    private func encodeDoubaoAudioPacket(payload: Data) -> Data {
        encodeDoubaoPacket(messageType: 0b0010, payload: payload)
    }

    private func encodeDoubaoPacket(messageType: UInt8, payload: Data) -> Data {
        var header = Data(repeating: 0, count: 8)
        header[0] = (0b0001 << 4) | 0b0001 // version + header words
        header[1] = (messageType << 4) | 0b0000
        header[2] = (0b0001 << 4) | 0b0000 // JSON + no compression (matches official SDK)
        header[3] = 0
        let payloadLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: payloadLength) { bytes in
            header.replaceSubrange(4..<8, with: bytes)
        }
        return header + payload
    }

    private struct DoubaoStreamingParsedMessage {
        let messageType: UInt8
        let payloadJSONData: Data
    }

    private func parseDoubaoStreamingResponse(data: Data) throws -> DoubaoStreamingParsedMessage? {
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
        return DoubaoStreamingParsedMessage(messageType: messageType, payloadJSONData: payload)
    }

    private func extractTextLeniently(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        do {
            return try extractText(from: data)
        } catch {
            return nil
        }
    }

    private func sendWebSocketData(task: URLSessionWebSocketTask, data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = WebSocketSendResultBox()
        task.send(.data(data)) { error in
            resultBox.error = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        if let sendError = resultBox.error {
            throw CloudASREngineError.requestFailed(sendError.localizedDescription)
        }
    }

    private enum WebSocketReceiveResult {
        case success(URLSessionWebSocketTask.Message)
        case failure(Error)
        case timedOut
    }

    private func receiveWebSocketMessage(
        task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) -> WebSocketReceiveResult {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = WebSocketReceiveResultBox()
        task.receive { result in
            resultBox.result = result
            semaphore.signal()
        }
        let status = semaphore.wait(timeout: .now() + timeout)
        if status == .timedOut {
            return .timedOut
        }
        switch resultBox.result {
        case .success(let message):
            return .success(message)
        case .failure(let error):
            return .failure(error)
        case .none:
            return .timedOut
        }
    }

    private func prepareDoubaoAudioPayload(audioFileURL: URL, fallbackData: Data) -> (data: Data, format: String) {
        let ext = audioFileURL.pathExtension.lowercased()
        if ext == "caf", let wavData = convertCAFToWavData(audioFileURL: audioFileURL) {
            return (wavData, "wav")
        }
        return (fallbackData, ext.isEmpty ? "wav" : ext)
    }

    private func convertCAFToWavData(audioFileURL: URL) -> Data? {
        let tempWavURL = AudioCacheStore.makeFileURL(prefix: "mytype-doubao", fileExtension: "wav")

        do {
            let inputFile = try AVAudioFile(forReading: audioFileURL)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFile.fileFormat.sampleRate,
                AVNumberOfChannelsKey: inputFile.fileFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let outputFile = try AVAudioFile(forWriting: tempWavURL, settings: outputSettings)
            let capacity: AVAudioFrameCount = 2048
            while true {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFile.processingFormat,
                    frameCapacity: capacity
                ) else { break }
                try inputFile.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try outputFile.write(from: buffer)
            }
            let wavData = try Data(contentsOf: tempWavURL)
            try? FileManager.default.removeItem(at: tempWavURL)
            return wavData
        } catch {
            try? FileManager.default.removeItem(at: tempWavURL)
            return nil
        }
    }

    private func performSync(request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = RequestResultBox()

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultBox.data = data
            resultBox.response = response
            resultBox.error = error
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 50)
        if let resultError = resultBox.error {
            throw CloudASREngineError.requestFailed(resultError.localizedDescription)
        }
        guard let resultData = resultBox.data, let resultResponse = resultBox.response else {
            throw CloudASREngineError.requestFailed("empty response")
        }
        return (resultData, resultResponse)
    }

    private func extractText(from data: Data) throws -> String {
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudASREngineError.invalidResponse("response is not JSON object")
        }

        if let text = jsonObject["text"] as? String, !text.isEmpty {
            return text
        }
        if let result = jsonObject["result"] as? [String: Any],
           let text = result["text"] as? String,
           !text.isEmpty {
            return text
        }
        if let choices = jsonObject["choices"] as? [[String: Any]],
           let first = choices.first,
           let text = first["text"] as? String,
           !text.isEmpty {
            return text
        }

        throw CloudASREngineError.invalidResponse("missing 'text' field")
    }

    private func estimateAudioDurationSeconds(from audioFileURL: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: audioFileURL) else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    private func estimatedCostCNY(durationSeconds: Double) -> Double {
        let perMinuteRaw = settings.string(forKey: SettingsKeys.cloudAPIPricePerMinute, default: "0")
        let perMinute = max(0, Double(perMinuteRaw) ?? 0)
        return perMinute * max(0, durationSeconds) / 60.0
    }

    private func normalizedCloudHotwords() -> [String] {
        let rawTerms = hotwordsProvider()
        guard !rawTerms.isEmpty else { return [] }

        var output: [String] = []
        var seen: Set<String> = []
        var totalChars = 0
        for raw in rawTerms {
            let term = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2 else { continue }
            guard !seen.contains(term) else { continue }

            let projected = totalChars + term.count
            if output.count >= 80 || projected > 700 {
                break
            }

            seen.insert(term)
            output.append(term)
            totalChars = projected
        }
        return output
    }

    private func doubaoRequestSection(
        model: String,
        showUtterances: Bool?,
        hotwords: [String]
    ) -> [String: Any] {
        var section: [String: Any] = [
            "model_name": model
        ]
        if let showUtterances {
            section["show_utterances"] = showUtterances
        }
        if !hotwords.isEmpty {
            section["context"] = [
                "hotwords": hotwords
            ]
        }
        return section
    }

    private func shouldRetryDoubaoWithoutHotwords(code: Int, body: String) -> Bool {
        guard code == 400 || code == 422 else { return false }
        if isDoubaoResourceNotGranted(body: body) { return false }

        let lower = body.lowercased()
        let mentionsHotword = lower.contains("hotword")
            || lower.contains("hot_word")
            || lower.contains("context")
            || lower.contains("热词")
        let indicatesInvalidParam = lower.contains("invalid")
            || lower.contains("unknown")
            || lower.contains("unsupported")
            || lower.contains("schema")
            || lower.contains("parameter")
            || lower.contains("字段")
            || lower.contains("参数")
            || lower.contains("格式")
        return mentionsHotword && indicatesInvalidParam
    }

    private func appendCloudRequestLog(
        status: String,
        durationSeconds: Double,
        latencyMs: Int,
        estimatedCostCNY: Double
    ) {
        var logs = settings.stringArray(forKey: SettingsKeys.cloudRequestLogs, default: [])
        let requestIndex = logs.count + 1
        let timestamp = Self.timeFormatter.string(from: Date())
        let roundedDuration = String(format: "%.1f", durationSeconds)
        let roundedCost = String(format: "%.4f", estimatedCostCNY)
        let line = "#\(requestIndex) [\(timestamp)] \(status) | 音频\(roundedDuration)s | 请求\(latencyMs)ms | 估算¥\(roundedCost)"

        logs.insert(line, at: 0)
        if logs.count > Self.maxCloudLogEntries {
            logs = Array(logs.prefix(Self.maxCloudLogEntries))
        }
        settings.set(logs, forKey: SettingsKeys.cloudRequestLogs)
    }
}

public final class RoutedASREngine: ASREngine, @unchecked Sendable {
    private let localEngine: ASREngine
    private let cloudEngine: ASREngine
    private let settings: SettingsStore

    public init(
        localEngine: ASREngine,
        cloudEngine: ASREngine,
        settings: SettingsStore
    ) {
        self.localEngine = localEngine
        self.cloudEngine = cloudEngine
        self.settings = settings
    }

    public func transcribe(audioFileURL: URL) throws -> RecognitionResult {
        let modeRaw = settings.string(forKey: SettingsKeys.recognitionMode, default: RecognitionMode.local.rawValue)
        let mode = RecognitionMode(rawValue: modeRaw) ?? .local

        switch mode {
        case .local:
            return transcribeWithFallback(
                audioFileURL: audioFileURL,
                requestedRoute: mode.rawValue,
                primary: localEngine,
                secondary: nil
            )
        case .cloud:
            // Cloud mode still keeps local fallback for resilience.
            return transcribeWithFallback(
                audioFileURL: audioFileURL,
                requestedRoute: mode.rawValue,
                primary: cloudEngine,
                secondary: localEngine
            )
        case .hybrid, .auto:
            // Hybrid strategy: cloud-first for quality, local fallback for resilience.
            return transcribeWithFallback(
                audioFileURL: audioFileURL,
                requestedRoute: mode.rawValue,
                primary: cloudEngine,
                secondary: localEngine
            )
        }
    }

    private func transcribeWithFallback(
        audioFileURL: URL,
        requestedRoute: String,
        primary: ASREngine,
        secondary: ASREngine?
    ) -> RecognitionResult {
        do {
            let primaryResult = try primary.transcribe(audioFileURL: audioFileURL)
            return RecognitionResult(
                rawText: primaryResult.rawText,
                latencyMs: primaryResult.latencyMs,
                engineRoute: primaryResult.engineRoute,
                requestedRoute: requestedRoute,
                fallbackUsed: false
            )
        } catch {
            if let secondary {
                do {
                    let fallbackResult = try secondary.transcribe(audioFileURL: audioFileURL)
                    return RecognitionResult(
                        rawText: fallbackResult.rawText,
                        latencyMs: fallbackResult.latencyMs,
                        engineRoute: fallbackResult.engineRoute,
                        requestedRoute: requestedRoute,
                        fallbackUsed: true
                    )
                } catch {
                    return RecognitionResult(
                        rawText: "",
                        latencyMs: 0,
                        engineRoute: "none",
                        requestedRoute: requestedRoute,
                        fallbackUsed: true
                    )
                }
            }
            return RecognitionResult(
                rawText: "",
                latencyMs: 0,
                engineRoute: "none",
                requestedRoute: requestedRoute,
                fallbackUsed: false
            )
        }
    }
}

public final class LocalASRStub: ASREngine, @unchecked Sendable {
    public init() {}

    public func transcribe(audioFileURL: URL) throws -> RecognitionResult {
        // TODO: Replace with local whisper/faster-whisper adapter.
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)
        let size = attrs?[.size] as? NSNumber
        let sizeKB = ((size?.doubleValue ?? 0) / 1024.0).rounded()
        let text = "嗯 这是一个 em 本地识别桩结果，录音文件约\(Int(sizeKB))KB"
        return RecognitionResult(
            rawText: text,
            latencyMs: 1200,
            engineRoute: "local_stub"
        )
    }
}
