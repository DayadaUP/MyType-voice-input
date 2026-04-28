import Foundation

public enum RecordingState: Equatable, Sendable {
    case idle
    case recording
    case processing
}

public struct RecognitionResult: Equatable, Sendable {
    public let rawText: String
    public let latencyMs: Int
    public let engineRoute: String
    public let requestedRoute: String?
    public let fallbackUsed: Bool

    public init(
        rawText: String,
        latencyMs: Int,
        engineRoute: String = "unknown",
        requestedRoute: String? = nil,
        fallbackUsed: Bool = false
    ) {
        self.rawText = rawText
        self.latencyMs = latencyMs
        self.engineRoute = engineRoute
        self.requestedRoute = requestedRoute
        self.fallbackUsed = fallbackUsed
    }
}

public struct ProcessingOptions: Equatable {
    public var removeFillers: Bool
    public var autoPunctuation: Bool

    public init(removeFillers: Bool = true, autoPunctuation: Bool = true) {
        self.removeFillers = removeFillers
        self.autoPunctuation = autoPunctuation
    }
}
