enum DeterministicStreamEvent<Element: Sendable>: Sendable {
    case output(Element)
    case delay(Duration)
    case interruption
    case failure(PipelineFailure)
    case cancellation
}

struct DeterministicStreamPlan<Element: Sendable>: Sendable {
    let stage: PipelineStage
    let events: [DeterministicStreamEvent<Element>]

    init(stage: PipelineStage, events: [DeterministicStreamEvent<Element>]) {
        self.stage = stage
        self.events = events
    }
}

private struct DeterministicStreamHandle<Element: Sendable>: Sendable {
    let stream: AsyncThrowingStream<Element, any Error>
    let control: DeterministicStreamControl
}

private actor DeterministicStreamControl {
    private var task: Task<Void, Never>?

    func store(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
    }

    func waitUntilStored() async {
        while task == nil {
            await Task.yield()
        }
    }
}

private func makeDeterministicStream<Element: Sendable>(
    plan: DeterministicStreamPlan<Element>
) -> DeterministicStreamHandle<Element> {
    let control = DeterministicStreamControl()
    let stream = AsyncThrowingStream<Element, any Error> { streamContinuation in
        let task = Task { @Sendable in
            do {
                for event in plan.events {
                    try Task.checkCancellation()

                    switch event {
                    case .output(let output):
                        streamContinuation.yield(output)
                    case .delay(let duration):
                        try await Task.sleep(for: duration)
                    case .interruption:
                        streamContinuation.finish(
                            throwing: PipelineFailure.stage(plan.stage, .interrupted)
                        )
                        return
                    case .failure(let failure):
                        streamContinuation.finish(throwing: failure)
                        return
                    case .cancellation:
                        streamContinuation.finish(throwing: PipelineFailure.cancelled)
                        return
                    }
                }

                streamContinuation.finish()
            } catch is CancellationError {
                streamContinuation.finish(throwing: PipelineFailure.cancelled)
            } catch {
                streamContinuation.finish(
                    throwing: PipelineFailure.stage(plan.stage, .failed)
                )
            }
        }

        Task {
            await control.store(task)
        }
        streamContinuation.onTermination = { @Sendable _ in
            Task {
                await control.cancel()
            }
        }
    }

    return DeterministicStreamHandle(stream: stream, control: control)
}

actor DeterministicAudioCapture: AudioCapture {
    private let plan: DeterministicStreamPlan<AudioChunk>
    private var activeControl: DeterministicStreamControl?

    init(plan: DeterministicStreamPlan<AudioChunk>) {
        self.plan = plan
    }

    func start() async throws(PipelineFailure) -> AudioStream {
        let handle = makeDeterministicStream(plan: plan)
        activeControl = handle.control
        await handle.control.waitUntilStored()
        return handle.stream
    }

    func stop() async {
        await activeControl?.cancel()
        activeControl = nil
    }

    func cancel() async {
        await activeControl?.cancel()
        activeControl = nil
    }
}

actor DeterministicSpeechRecognizer: TemporarySpeechRecognizer {
    private let plan: DeterministicStreamPlan<FinalizedSpeechSegment>
    private var activeControl: DeterministicStreamControl?

    init(plan: DeterministicStreamPlan<FinalizedSpeechSegment>) {
        self.plan = plan
    }

    func recognize(audio: AudioStream) async throws(PipelineFailure) -> FinalizedSpeechStream {
        let handle = makeDeterministicStream(plan: plan)
        activeControl = handle.control
        await handle.control.waitUntilStored()
        return handle.stream
    }

    func stop() async {
        await activeControl?.cancel()
        activeControl = nil
    }

    func cancel() async {
        await activeControl?.cancel()
        activeControl = nil
    }
}

actor DeterministicRollingMeetingContext: RollingMeetingContext {
    private let batch: MeetingContextBatch?
    private var didCancel = false
    private var segments: [FinalizedSpeechSegment] = []

    init(batch: MeetingContextBatch? = nil) {
        self.batch = batch
    }

    func append(_ segment: FinalizedSpeechSegment) async throws(PipelineFailure) {
        guard !didCancel else {
            throw .cancelled
        }
        segments.append(segment)
    }

    func nextBatch() async throws(PipelineFailure) -> MeetingContextBatch? {
        guard !didCancel else {
            throw .cancelled
        }
        return batch
    }

    func clear() async {
        segments.removeAll()
    }

    func cancel() async {
        didCancel = true
        segments.removeAll()
    }
}

actor DeterministicInsightGenerator: InsightGenerator {
    private let delay: Duration
    private let result: Result<[InsightUpdate], PipelineFailure>
    private var activeTask: Task<Result<[InsightUpdate], PipelineFailure>, Never>?
    private var cancellationRequested = false

    init(
        delay: Duration = .zero,
        result: Result<[InsightUpdate], PipelineFailure>
    ) {
        self.delay = delay
        self.result = result
    }

    func generate(from batch: MeetingContextBatch) async throws(PipelineFailure) -> [InsightUpdate] {
        if cancellationRequested {
            cancellationRequested = false
            throw .cancelled
        }

        let task = Task { () -> Result<[InsightUpdate], PipelineFailure> in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
                return result
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.stage(.insightGeneration, .failed))
            }
        }
        activeTask = task
        let taskResult = await task.value
        activeTask = nil
        return try taskResult.get()
    }

    func cancel() async {
        cancellationRequested = true
        activeTask?.cancel()
        activeTask = nil
    }
}

@MainActor
final class DeterministicInsightState: InsightState {
    private(set) var cards: [InsightCard]
    private(set) var appliedUpdates: [[InsightUpdate]] = []
    private(set) var supportingContexts: [MeetingContextBatch] = []

    init(cards: [InsightCard] = []) {
        self.cards = cards
    }

    func apply(
        _ updates: [InsightUpdate],
        supportedBy sourceContext: MeetingContextBatch
    ) throws(PipelineFailure) {
        appliedUpdates.append(updates)
        supportingContexts.append(sourceContext)
    }

    func reset() {
        cards.removeAll()
        appliedUpdates.removeAll()
        supportingContexts.removeAll()
    }
}

@MainActor
final class DeterministicSessionLifecycle: SessionLifecycle {
    private(set) var status: SessionStatus = .stopped
    private(set) var readiness: SessionReadiness?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    let configuredAvailability: Availability
    let configuredStartFailure: PipelineFailure?

    init(
        availability: Availability = .available,
        startFailure: PipelineFailure? = nil
    ) {
        configuredAvailability = availability
        configuredStartFailure = startFailure
    }

    func checkAvailability() async -> Availability {
        configuredAvailability
    }

    func checkReadiness() async -> SessionReadiness {
        let reason: UnavailableReason?
        switch configuredAvailability {
        case .available:
            reason = nil
        case .unavailable(let configuredReason):
            reason = configuredReason
        }
        let report = SessionReadiness(
            checks: [
                PrerequisiteCheck(kind: .microphone, reason: reason),
                PrerequisiteCheck(kind: .speechRecognition, reason: reason),
                PrerequisiteCheck(kind: .appleIntelligence, reason: reason),
            ]
        )
        readiness = report
        return report
    }

    func start() async throws(PipelineFailure) {
        startCount += 1

        if let configuredStartFailure {
            status = .unavailable
            throw configuredStartFailure
        }

        status = .listening
    }

    func stop() async {
        stopCount += 1
        status = .stopped
    }

    func cancel() async {
        cancelCount += 1
        status = .stopped
    }
}
