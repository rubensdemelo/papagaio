typealias AudioStream = AsyncThrowingStream<AudioChunk, any Error>
typealias FinalizedSpeechStream = AsyncThrowingStream<FinalizedSpeechSegment, any Error>

struct MeetingContextBatch: Sendable, Equatable {
    let segments: [FinalizedSpeechSegment]
}

protocol AudioCapture: Sendable {
    func start() async throws(PipelineFailure) -> AudioStream
    func stop() async
    func cancel() async
}

protocol TemporarySpeechRecognizer: Sendable {
    func recognize(audio: AudioStream) async throws(PipelineFailure) -> FinalizedSpeechStream
    func stop() async
    func cancel() async
}

protocol RollingMeetingContext: Sendable {
    func append(_ segment: FinalizedSpeechSegment) async throws(PipelineFailure)
    func nextBatch() async throws(PipelineFailure) -> MeetingContextBatch?
    func clear() async
    func cancel() async
}

protocol InsightGenerator: Sendable {
    func generate(from batch: MeetingContextBatch) async throws(PipelineFailure) -> [InsightUpdate]
    func cancel() async
}

@MainActor
protocol InsightState: AnyObject {
    var cards: [InsightCard] { get }
    func apply(_ updates: [InsightUpdate])
    func reset()
}

@MainActor
protocol SessionLifecycle: AnyObject {
    var status: SessionStatus { get }
    func checkAvailability() async -> Availability
    func start() async throws(PipelineFailure)
    func stop() async
    func cancel() async
}
