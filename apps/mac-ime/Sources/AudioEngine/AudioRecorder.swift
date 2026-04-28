import Foundation
@preconcurrency import AVFoundation
import Common

public enum AudioRecorderError: Error {
    case permissionDenied
    case alreadyRecording
    case notRecording
    case failedToStart
    case outputMissing
}

private final class PermissionBox: @unchecked Sendable {
    var granted = false
}

public final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    public private(set) var currentRecordingURL: URL?
    public private(set) var isRecording = false

    public init() {}

    public func startRecording() throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }
        guard Self.requestMicrophonePermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let outputURL = Self.makeOutputURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecorderError.failedToStart
        }

        self.recorder = recorder
        currentRecordingURL = outputURL
        isRecording = true
    }

    public func stopRecording() throws -> URL {
        guard isRecording, let recorder else {
            throw AudioRecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        isRecording = false

        guard let url = currentRecordingURL else {
            throw AudioRecorderError.outputMissing
        }
        return url
    }

    private static func requestMicrophonePermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let box = PermissionBox()
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { result in
                box.granted = result
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            return box.granted
        @unknown default:
            return false
        }
    }

    private static func makeOutputURL() -> URL {
        AudioCacheStore.makeFileURL(prefix: "mytype", fileExtension: "caf")
    }
}
