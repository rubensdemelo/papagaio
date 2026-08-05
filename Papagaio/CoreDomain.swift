struct SessionID: Hashable, Sendable, Equatable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

enum SessionStatus: Sendable, Equatable {
    case stopped
    case checkingAvailability
    case listening
    case processing
    case interrupted
    case unavailable
}

struct AudioChunk: Sendable, Equatable {
    let sequenceNumber: UInt64
    let duration: Duration
    let sampleRate: Double
    let channelCount: Int
    let samples: [Float]
}

struct FinalizedSpeechSegment: Sendable, Equatable {
    let sequenceNumber: UInt64
    let text: String
    let startOffset: Duration
    let endOffset: Duration
}

enum InsightCategory: Sendable, Equatable {
    case important
    case decision
    case action
    case question
    case risk
}

enum InsightOperation: Sendable, Equatable {
    case add
    case update
    case resolve
}

enum InsightCardState: Sendable, Equatable {
    case new
    case updated
    case resolved
}

struct InsightUpdate: Sendable, Equatable {
    let stableKey: String
    let operation: InsightOperation
    let category: InsightCategory
    let text: String
    let explicitOwner: String?
}

struct InsightCard: Sendable, Equatable {
    let stableKey: String
    let category: InsightCategory
    let text: String
    let explicitOwner: String?
    let state: InsightCardState
}

enum Availability: Sendable, Equatable {
    case available
    case unavailable(UnavailableReason)
}

enum UnavailableReason: Sendable, Equatable {
    case microphonePermissionDenied
    case audioInputUnavailable
    case speechRecognitionUnavailable
    case speechLocaleUnsupported(identifier: String)
    case speechAssetsNotReady
    case languageModelDeviceNotEligible
    case appleIntelligenceDisabled
    case languageModelNotReady
    case languageModelLocaleUnsupported(identifier: String)
}

enum PipelineStage: Sendable, Equatable {
    case audioCapture
    case speechRecognition
    case rollingContext
    case insightGeneration
    case insightState
    case sessionLifecycle
}

enum PipelineFailureReason: Sendable, Equatable {
    case failed
    case interrupted
    case overloaded
    case invalidState
}

enum PipelineFailure: Error, Sendable, Equatable {
    case unavailable(UnavailableReason)
    case stage(PipelineStage, PipelineFailureReason)
    case cancelled
}
