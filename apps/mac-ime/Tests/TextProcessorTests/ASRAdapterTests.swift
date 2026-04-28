import Foundation
import Testing
@testable import ASRAdapter
@testable import Common
@testable import Settings

@Test("parses JSON response from local ASR script")
func parsesJSONFromScript() throws {
    let pythonPath = "/usr/bin/python3"
    guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
        Issue.record("python3 is not available at /usr/bin/python3")
        return
    }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-asr-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let scriptURL = tempDir.appendingPathComponent("mock_asr.py")
    let audioURL = tempDir.appendingPathComponent("sample.m4a")
    try Data([0x00, 0x01, 0x02]).write(to: audioURL)

    let script = """
    import json
    print(json.dumps({"text": "你好 world", "latency_ms": 321, "language": "zh"}))
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)

    let config = FasterWhisperConfiguration(
        pythonPath: pythonPath,
        scriptURL: scriptURL,
        modelSize: "small",
        device: "auto",
        computeType: "int8",
        beamSize: 1,
        language: nil,
        modelDirectoryURL: nil
    )
    let engine = FasterWhisperASREngine(configuration: config)

    let result = try engine.transcribe(audioFileURL: audioURL)
    #expect(result.rawText == "你好 world")
    #expect(result.latencyMs == 321)
    #expect(result.engineRoute == "local_faster_whisper")
    #expect(result.requestedRoute == nil)
    #expect(result.fallbackUsed == false)
}

private final class MockASREngine: ASREngine, @unchecked Sendable {
    enum Behavior {
        case success(RecognitionResult)
        case failure(Error)
    }

    private let behavior: Behavior
    private(set) var callCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(audioFileURL: URL) throws -> RecognitionResult {
        callCount += 1
        switch behavior {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

@Test("hybrid mode prefers cloud result")
func hybridModePrefersCloudResult() throws {
    let settings = InMemorySettingsStore()
    settings.set(RecognitionMode.hybrid.rawValue, forKey: SettingsKeys.recognitionMode)

    let local = MockASREngine(.success(.init(rawText: "local", latencyMs: 10, engineRoute: "local_test")))
    let cloud = MockASREngine(.success(.init(rawText: "cloud", latencyMs: 20, engineRoute: "cloud_test")))
    let routed = RoutedASREngine(localEngine: local, cloudEngine: cloud, settings: settings)

    let dummyAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dummy-\(UUID().uuidString).caf")
    let result = try routed.transcribe(audioFileURL: dummyAudio)

    #expect(result.rawText == "cloud")
    #expect(result.engineRoute == "cloud_test")
    #expect(result.requestedRoute == RecognitionMode.hybrid.rawValue)
    #expect(result.fallbackUsed == false)
    #expect(cloud.callCount == 1)
    #expect(local.callCount == 0)
}

@Test("hybrid mode falls back to local on cloud failure")
func hybridModeFallsBackToLocalOnCloudFailure() throws {
    enum TestError: Error { case cloudDown }

    let settings = InMemorySettingsStore()
    settings.set(RecognitionMode.hybrid.rawValue, forKey: SettingsKeys.recognitionMode)

    let local = MockASREngine(.success(.init(rawText: "local-fallback", latencyMs: 12, engineRoute: "local_test")))
    let cloud = MockASREngine(.failure(TestError.cloudDown))
    let routed = RoutedASREngine(localEngine: local, cloudEngine: cloud, settings: settings)

    let dummyAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dummy-\(UUID().uuidString).caf")
    let result = try routed.transcribe(audioFileURL: dummyAudio)

    #expect(result.rawText == "local-fallback")
    #expect(result.engineRoute == "local_test")
    #expect(result.requestedRoute == RecognitionMode.hybrid.rawValue)
    #expect(result.fallbackUsed == true)
    #expect(cloud.callCount == 1)
    #expect(local.callCount == 1)
}

@Test("cloud mode falls back to local on cloud failure")
func cloudModeFallsBackToLocalOnCloudFailure() throws {
    enum TestError: Error { case cloudDown }

    let settings = InMemorySettingsStore()
    settings.set(RecognitionMode.cloud.rawValue, forKey: SettingsKeys.recognitionMode)

    let local = MockASREngine(.success(.init(rawText: "local-backup", latencyMs: 9, engineRoute: "local_test")))
    let cloud = MockASREngine(.failure(TestError.cloudDown))
    let routed = RoutedASREngine(localEngine: local, cloudEngine: cloud, settings: settings)

    let dummyAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dummy-\(UUID().uuidString).caf")
    let result = try routed.transcribe(audioFileURL: dummyAudio)

    #expect(result.rawText == "local-backup")
    #expect(result.engineRoute == "local_test")
    #expect(result.requestedRoute == RecognitionMode.cloud.rawValue)
    #expect(result.fallbackUsed == true)
    #expect(cloud.callCount == 1)
    #expect(local.callCount == 1)
}

@Test("local mode degrades to empty result when local engine fails")
func localModeReturnsEmptyWhenLocalFails() throws {
    enum TestError: Error { case localDown }

    let settings = InMemorySettingsStore()
    settings.set(RecognitionMode.local.rawValue, forKey: SettingsKeys.recognitionMode)

    let local = MockASREngine(.failure(TestError.localDown))
    let cloud = MockASREngine(.success(.init(rawText: "cloud-should-not-run", latencyMs: 5, engineRoute: "cloud_test")))
    let routed = RoutedASREngine(localEngine: local, cloudEngine: cloud, settings: settings)

    let dummyAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dummy-\(UUID().uuidString).caf")
    let result = try routed.transcribe(audioFileURL: dummyAudio)

    #expect(result.rawText.isEmpty)
    #expect(result.latencyMs == 0)
    #expect(result.engineRoute == "none")
    #expect(result.requestedRoute == RecognitionMode.local.rawValue)
    #expect(result.fallbackUsed == false)
    #expect(local.callCount == 1)
    #expect(cloud.callCount == 0)
}

@Test("hybrid mode degrades to empty result when both engines fail")
func hybridModeReturnsEmptyWhenAllEnginesFail() throws {
    enum TestError: Error { case down }

    let settings = InMemorySettingsStore()
    settings.set(RecognitionMode.hybrid.rawValue, forKey: SettingsKeys.recognitionMode)

    let local = MockASREngine(.failure(TestError.down))
    let cloud = MockASREngine(.failure(TestError.down))
    let routed = RoutedASREngine(localEngine: local, cloudEngine: cloud, settings: settings)

    let dummyAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dummy-\(UUID().uuidString).caf")
    let result = try routed.transcribe(audioFileURL: dummyAudio)

    #expect(result.rawText.isEmpty)
    #expect(result.latencyMs == 0)
    #expect(result.engineRoute == "none")
    #expect(result.requestedRoute == RecognitionMode.hybrid.rawValue)
    #expect(result.fallbackUsed == true)
    #expect(cloud.callCount == 1)
    #expect(local.callCount == 1)
}
