import Foundation
import XCTest

@MainActor
final class SessionLifecycleTests: XCTestCase {
    func testPermissionDeniedStopsBeforeStartingPipeline() async throws {
        let capture = TestSessionAudioCapture(
            permission: .denied,
            availability: .unavailable(.microphonePermissionDenied)
        )
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator()
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator,
            state: state
        )

        let availability = await coordinator.checkAvailability()
        XCTAssertEqual(availability, .unavailable(.microphonePermissionDenied))
        do {
            try await coordinator.start()
            XCTFail("Permission denial must stop startup")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .unavailable(.microphonePermissionDenied)
            )
        }

        XCTAssertEqual(coordinator.status, .unavailable)
        let captureStarts = await capture.startCount()
        let generatorStarts = await generator.startSessionCount()
        XCTAssertEqual(captureStarts, 0)
        XCTAssertEqual(generatorStarts, 0)
    }

    func testSpeechUnavailableStopsBeforeCapture() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer(
            availability: SpeechRecognitionAvailability(
                transcriberIsAvailable: false,
                requestedLocaleIdentifier: "en-US",
                resolvedLocaleIdentifier: nil,
                installedLocale: false,
                assetState: .unsupported
            )
        )
        let generator = TestSessionInsightGenerator()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator
        )

        do {
            try await coordinator.start()
            XCTFail("Speech unavailability must stop startup")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .unavailable(.speechRecognitionUnavailable)
            )
        }

        XCTAssertEqual(coordinator.status, .unavailable)
        let captureStarts = await capture.startCount()
        let generatorStarts = await generator.startSessionCount()
        XCTAssertEqual(captureStarts, 0)
        XCTAssertEqual(generatorStarts, 0)
    }

    func testUnsupportedSpeechLocaleStopsBeforeCapture() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer(
            availability: SpeechRecognitionAvailability(
                transcriberIsAvailable: true,
                requestedLocaleIdentifier: "zz-ZZ",
                resolvedLocaleIdentifier: nil,
                installedLocale: false,
                assetState: .unsupported
            )
        )
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech
        )

        do {
            try await coordinator.start()
            XCTFail("An unsupported locale must stop startup")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .unavailable(.speechLocaleUnsupported(identifier: "zz-ZZ"))
            )
        }

        let captureStarts = await capture.startCount()
        XCTAssertEqual(captureStarts, 0)
    }

    func testModelUnavailableStopsBeforeCapture() async throws {
        let capture = TestSessionAudioCapture()
        let generator = TestSessionInsightGenerator(
            availability: .unavailable(.languageModelNotReady)
        )
        let coordinator = makeCoordinator(
            capture: capture,
            generator: generator
        )

        do {
            try await coordinator.start()
            XCTFail("Model unavailability must stop startup")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .unavailable(.languageModelNotReady)
            )
        }

        let captureStarts = await capture.startCount()
        let generatorStarts = await generator.startSessionCount()
        XCTAssertEqual(captureStarts, 0)
        XCTAssertEqual(generatorStarts, 0)
    }

    func testCaptureStartFailureCleansPartialStartup() async throws {
        let capture = TestSessionAudioCapture(
            startFailure: .stage(.audioCapture, .failed)
        )
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator()
        let contextFactory = TestMeetingContextFactory()
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator,
            contextFactory: contextFactory,
            state: state
        )

        do {
            try await coordinator.start()
            XCTFail("Capture startup failure must propagate")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .stage(.audioCapture, .failed)
            )
        }

        XCTAssertEqual(coordinator.status, .unavailable)
        let captureCancellations = await capture.cancelCount()
        let speechCancellations = await speech.cancelCount()
        let generatorCancellations = await generator.cancelCount()
        let contexts = contextFactory.contexts()
        let contextCancellations = await contexts[0].cancelCount()
        XCTAssertEqual(captureCancellations, 1)
        XCTAssertEqual(speechCancellations, 1)
        XCTAssertEqual(generatorCancellations, 1)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contextCancellations, 1)
        XCTAssertEqual(state.resetCount, 2)
    }

    func testSpeechFailureWhileListeningPropagatesAndCleans() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator()
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator,
            state: state
        )

        try await coordinator.start()
        let speechStream = await speech.lastStream()
        speechStream?.finish(
            throwing: PipelineFailure.stage(.speechRecognition, .failed)
        )
        await waitUntil { coordinator.status == .unavailable }

        let captureCancellations = await capture.cancelCount()
        let speechCancellations = await speech.cancelCount()
        let generatorCancellations = await generator.cancelCount()
        XCTAssertEqual(captureCancellations, 1)
        XCTAssertEqual(speechCancellations, 1)
        XCTAssertEqual(generatorCancellations, 1)
        XCTAssertEqual(state.resetCount, 2)
    }

    func testGenerationFailurePropagatesAfterFinalizedSpeech() async throws {
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            generateFailure: .stage(.insightGeneration, .failed)
        )
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            speech: speech,
            generator: generator,
            state: state
        )

        try await coordinator.start()
        let speechStream = await speech.lastStream()
        speechStream?.yield(makeSegment(sequence: 1, text: "synthetic generation failure"))
        await waitUntil { coordinator.status == .unavailable }

        XCTAssertTrue(state.appliedContexts.isEmpty)
        let generatorCancellations = await generator.cancelCount()
        XCTAssertEqual(generatorCancellations, 1)
    }

    func testStopWhileProcessingCancelsGenerationAndClearsState() async throws {
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            delay: .seconds(5),
            updates: [makeUpdate(text: "late synthetic result")]
        )
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            speech: speech,
            generator: generator,
            state: state
        )

        try await coordinator.start()
        let speechStream = await speech.lastStream()
        speechStream?.yield(makeSegment(sequence: 1, text: "synthetic stop while processing"))
        await waitUntil { coordinator.status == SessionStatus.processing }

        await coordinator.stop()

        XCTAssertEqual(coordinator.status, .stopped)
        XCTAssertTrue(state.appliedContexts.isEmpty)
        let generatorStops = await generator.stopCount()
        XCTAssertEqual(generatorStops, 1)
    }

    func testExplicitCancellationClearsEveryActiveComponent() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            delay: .seconds(5),
            updates: [makeUpdate(text: "late cancellation result")]
        )
        let contextFactory = TestMeetingContextFactory()
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator,
            contextFactory: contextFactory,
            state: state
        )

        try await coordinator.start()
        let speechStream = await speech.lastStream()
        speechStream?.yield(makeSegment(sequence: 1, text: "synthetic cancellation"))
        await waitUntil { coordinator.status == SessionStatus.processing }

        await coordinator.cancel()

        XCTAssertEqual(coordinator.status, .stopped)
        let captureCancellations = await capture.cancelCount()
        let speechCancellations = await speech.cancelCount()
        let generatorCancellations = await generator.cancelCount()
        XCTAssertEqual(captureCancellations, 1)
        XCTAssertEqual(speechCancellations, 1)
        XCTAssertEqual(generatorCancellations, 1)
        XCTAssertTrue(state.appliedContexts.isEmpty)
    }

    func testGenerationRequestsRemainSerializedAcrossBatches() async throws {
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            delay: .milliseconds(10),
            updates: [makeUpdate(text: "serialized result")]
        )
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            speech: speech,
            generator: generator,
            state: state
        )

        try await coordinator.start()
        let speechStream = await speech.lastStream()
        speechStream?.yield(makeSegment(sequence: 1, text: "first batch"))
        speechStream?.yield(makeSegment(sequence: 2, text: "second batch"))
        await waitUntil { state.appliedContexts.count == 2 }

        let maximumConcurrentRequests = await generator.maximumConcurrentRequests()
        XCTAssertEqual(maximumConcurrentRequests, 1)
        await coordinator.stop()
    }

    func testCaptureInterruptionPropagatesAsInterrupted() async throws {
        let capture = TestSessionAudioCapture()
        let coordinator = makeCoordinator(capture: capture)

        try await coordinator.start()
        let audioStream = await capture.lastStream()
        audioStream?.finish(
            throwing: PipelineFailure.stage(.audioCapture, .interrupted)
        )
        await waitUntil { coordinator.status == .interrupted }

        let captureCancellations = await capture.cancelCount()
        XCTAssertEqual(captureCancellations, 1)
    }

    func testRapidStartStopRestartUsesIsolatedSessionAndRejectsStaleResults() async throws {
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            delay: .milliseconds(50),
            updates: [makeUpdate(text: "synthetic stale result")],
            ignoresCancellation: true
        )
        let contextFactory = TestMeetingContextFactory()
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            speech: speech,
            generator: generator,
            contextFactory: contextFactory,
            state: state
        )

        try await coordinator.start()
        let firstSpeechStream = await speech.lastStream()
        firstSpeechStream?.yield(makeSegment(sequence: 1, text: "old session"))
        await waitUntil { coordinator.status == SessionStatus.processing }
        await coordinator.stop()

        try await coordinator.start()
        let secondSpeechStream = await speech.lastStream()
        secondSpeechStream?.yield(makeSegment(sequence: 1, text: "new session"))
        await waitUntil { state.appliedContexts.count == 1 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.appliedContexts.count, 1)
        XCTAssertEqual(state.appliedContexts[0].segments[0].text, "new session")
        let contexts = contextFactory.contexts()
        let firstContextSegments = await contexts[0].storedSegments()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(firstContextSegments.isEmpty)
        await coordinator.stop()
    }

    func testMultipleStopRequestsAreIdempotent() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator
        )

        try await coordinator.start()
        async let firstStop: Void = coordinator.stop()
        async let secondStop: Void = coordinator.stop()
        _ = await (firstStop, secondStop)

        XCTAssertEqual(coordinator.status, .stopped)
        let captureStops = await capture.stopCount()
        let speechStops = await speech.stopCount()
        let generatorStops = await generator.stopCount()
        XCTAssertEqual(captureStops, 1)
        XCTAssertEqual(speechStops, 1)
        XCTAssertEqual(generatorStops, 1)
    }

    func testCleanupAfterSpeechStartupFailureResetsEveryComponent() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer(
            recognizeFailure: .stage(.speechRecognition, .failed)
        )
        let generator = TestSessionInsightGenerator()
        let contextFactory = TestMeetingContextFactory()
        let state = TestSessionInsightState()
        let coordinator = makeCoordinator(
            capture: capture,
            speech: speech,
            generator: generator,
            contextFactory: contextFactory,
            state: state
        )

        do {
            try await coordinator.start()
            XCTFail("Speech startup failure must propagate")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .stage(.speechRecognition, .failed)
            )
        }

        let captureCancellations = await capture.cancelCount()
        let speechCancellations = await speech.cancelCount()
        let generatorCancellations = await generator.cancelCount()
        let context = contextFactory.contexts()[0]
        let contextCancellations = await context.cancelCount()
        let storedSegments = await context.storedSegments()
        XCTAssertEqual(captureCancellations, 1)
        XCTAssertEqual(speechCancellations, 1)
        XCTAssertEqual(generatorCancellations, 1)
        XCTAssertEqual(contextCancellations, 1)
        XCTAssertTrue(storedSegments.isEmpty)
        XCTAssertTrue(state.appliedContexts.isEmpty)
    }

    func testInsightStateFailureCleansActiveSession() async throws {
        let speech = TestSessionSpeechRecognizer()
        let state = TestSessionInsightState(
            applyFailure: .stage(.insightState, .invalidState)
        )
        let coordinator = makeCoordinator(speech: speech, state: state)

        try await coordinator.start()
        let speechStream = await speech.lastStream()
        speechStream?.yield(makeSegment(sequence: 1, text: "synthetic state failure"))
        await waitUntil { coordinator.status == .unavailable }

        XCTAssertEqual(coordinator.status, .unavailable)
        XCTAssertTrue(state.appliedContexts.isEmpty)
        let speechCancellations = await speech.cancelCount()
        XCTAssertEqual(speechCancellations, 1)
    }

    private func makeCoordinator(
        capture: TestSessionAudioCapture = TestSessionAudioCapture(),
        speech: TestSessionSpeechRecognizer = TestSessionSpeechRecognizer(),
        generator: TestSessionInsightGenerator = TestSessionInsightGenerator(),
        contextFactory: TestMeetingContextFactory = TestMeetingContextFactory(),
        state: TestSessionInsightState = TestSessionInsightState()
    ) -> SessionLifecycleCoordinator {
        SessionLifecycleCoordinator(
            localeIdentifier: "en-US",
            capture: capture,
            speechRecognizer: speech,
            contextFactory: contextFactory,
            insightGenerator: generator,
            insightState: state
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for lifecycle transition")
    }

    private func makeSegment(sequence: UInt64, text: String) -> FinalizedSpeechSegment {
        FinalizedSpeechSegment(
            sequenceNumber: sequence,
            text: text,
            startOffset: .zero,
            endOffset: .seconds(1)
        )
    }

    private func makeUpdate(text: String) -> InsightUpdate {
        InsightUpdate(
            stableKey: text,
            operation: .add,
            category: .important,
            text: text,
            explicitOwner: nil
        )
    }

}

final class TestStream<Element: Sendable>: @unchecked Sendable {
    let stream: AsyncThrowingStream<Element, any Error>
    private let continuation: AsyncThrowingStream<Element, any Error>.Continuation

    init() {
        var capturedContinuation: AsyncThrowingStream<Element, any Error>.Continuation?
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
    }

    func yield(_ element: Element) {
        continuation.yield(element)
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }
}

actor TestSessionAudioCapture: SessionAudioCapture {
    private let configuredPermission: MicrophonePermission
    private let configuredAvailability: Availability
    private let startFailure: PipelineFailure?
    private var currentStream: TestStream<AudioChunk>?
    private var starts = 0
    private var stops = 0
    private var cancellations = 0

    init(
        permission: MicrophonePermission = .granted,
        availability: Availability = .available,
        startFailure: PipelineFailure? = nil
    ) {
        configuredPermission = permission
        configuredAvailability = availability
        self.startFailure = startFailure
    }

    func permission() async -> MicrophonePermission {
        configuredPermission
    }

    func checkAvailability() async -> Availability {
        configuredAvailability
    }

    func start() async throws(PipelineFailure) -> AudioStream {
        starts += 1
        if let startFailure {
            throw startFailure
        }
        let source = TestStream<AudioChunk>()
        currentStream = source
        return source.stream
    }

    func stop() async {
        stops += 1
        currentStream?.finish(throwing: PipelineFailure.cancelled)
        currentStream = nil
    }

    func cancel() async {
        cancellations += 1
        currentStream?.finish(throwing: PipelineFailure.cancelled)
        currentStream = nil
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
    func cancelCount() -> Int { cancellations }
    func lastStream() -> TestStream<AudioChunk>? { currentStream }
}

actor TestSessionSpeechRecognizer: SessionSpeechRecognizer {
    private let configuredAvailability: SpeechRecognitionAvailability
    private let recognizeFailure: PipelineFailure?
    private var currentStream: TestStream<FinalizedSpeechSegment>?
    private var stops = 0
    private var cancellations = 0

    init(
        availability: SpeechRecognitionAvailability = .available,
        recognizeFailure: PipelineFailure? = nil
    ) {
        configuredAvailability = availability
        self.recognizeFailure = recognizeFailure
    }

    func availability() async -> SpeechRecognitionAvailability {
        configuredAvailability
    }

    func recognize(audio: AudioStream) async throws(PipelineFailure) -> FinalizedSpeechStream {
        if let recognizeFailure {
            throw recognizeFailure
        }
        let source = TestStream<FinalizedSpeechSegment>()
        currentStream = source
        return source.stream
    }

    func stop() async {
        stops += 1
        currentStream?.finish(throwing: PipelineFailure.cancelled)
        currentStream = nil
    }

    func cancel() async {
        cancellations += 1
        currentStream?.finish(throwing: PipelineFailure.cancelled)
        currentStream = nil
    }

    func stopCount() -> Int { stops }
    func cancelCount() -> Int { cancellations }
    func lastStream() -> TestStream<FinalizedSpeechSegment>? { currentStream }
}

final class TestMeetingContextFactory: MeetingContextFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var createdContexts: [TestMeetingContext] = []

    func makeContext() -> any RollingMeetingContext {
        let context = TestMeetingContext()
        lock.lock()
        createdContexts.append(context)
        lock.unlock()
        return context
    }

    func contexts() -> [TestMeetingContext] {
        lock.lock()
        defer { lock.unlock() }
        return createdContexts
    }
}

actor TestMeetingContext: RollingMeetingContext {
    private var pendingBatches: [MeetingContextBatch] = []
    private var waiting: CheckedContinuation<MeetingContextBatch?, any Error>?
    private var segments: [FinalizedSpeechSegment] = []
    private var cancelled = false
    private var cancels = 0

    func append(_ segment: FinalizedSpeechSegment) async throws(PipelineFailure) {
        guard !cancelled else {
            throw .cancelled
        }
        segments.append(segment)
        let batch = MeetingContextBatch(segments: [segment])
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: batch)
        } else {
            pendingBatches.append(batch)
        }
    }

    func nextBatch() async throws(PipelineFailure) -> MeetingContextBatch? {
        guard !cancelled else {
            throw .cancelled
        }
        if !pendingBatches.isEmpty {
            return pendingBatches.removeFirst()
        }
        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<MeetingContextBatch?, any Error>) in
                waiting = continuation
            }
        } catch let failure as PipelineFailure {
            throw failure
        } catch {
            throw .stage(.rollingContext, .failed)
        }
    }

    func clear() async {
        pendingBatches.removeAll()
        segments.removeAll()
    }

    func cancel() async {
        cancelled = true
        cancels += 1
        pendingBatches.removeAll()
        segments.removeAll()
        if let waiting {
            self.waiting = nil
            waiting.resume(throwing: PipelineFailure.cancelled)
        }
    }

    func cancelCount() -> Int { cancels }
    func storedSegments() -> [FinalizedSpeechSegment] { segments }
}

actor TestSessionInsightGenerator: SessionInsightGenerator {
    private let configuredAvailability: Availability
    private let startFailure: PipelineFailure?
    private let delay: Duration
    private let updates: [InsightUpdate]
    private let updateProvider: (@Sendable (MeetingContextBatch) -> [InsightUpdate])?
    private let generateFailure: PipelineFailure?
    private var remainingGenerateFailures: Int
    private let ignoresCancellation: Bool
    private var started = false
    private var starts = 0
    private var stops = 0
    private var cancellations = 0
    private var activeRequests = 0
    private var maximumActiveRequests = 0

    init(
        availability: Availability = .available,
        startFailure: PipelineFailure? = nil,
        delay: Duration = .zero,
        updates: [InsightUpdate] = [],
        updateProvider: (@Sendable (MeetingContextBatch) -> [InsightUpdate])? = nil,
        generateFailure: PipelineFailure? = nil,
        generateFailureCount: Int = 1,
        ignoresCancellation: Bool = false
    ) {
        configuredAvailability = availability
        self.startFailure = startFailure
        self.delay = delay
        self.updates = updates
        self.updateProvider = updateProvider
        self.generateFailure = generateFailure
        remainingGenerateFailures = generateFailureCount
        self.ignoresCancellation = ignoresCancellation
    }

    func availability() async -> Availability {
        configuredAvailability
    }

    func startSession(localeIdentifier: String) async throws(PipelineFailure) {
        starts += 1
        if let startFailure {
            throw startFailure
        }
        started = true
    }

    func generate(from batch: MeetingContextBatch) async throws(PipelineFailure) -> [InsightUpdate] {
        guard started else {
            throw .stage(.insightGeneration, .invalidState)
        }
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }

        if delay > .zero {
            try? await Task.sleep(for: delay)
            if !ignoresCancellation, Task.isCancelled {
                throw .cancelled
            }
        }
        if let generateFailure {
            if remainingGenerateFailures > 0 {
                remainingGenerateFailures -= 1
                throw generateFailure
            }
        }
        return updateProvider?(batch) ?? updates
    }

    func stop() async {
        stops += 1
        started = false
    }

    func cancel() async {
        cancellations += 1
        started = false
    }

    func startSessionCount() -> Int { starts }
    func stopCount() -> Int { stops }
    func cancelCount() -> Int { cancellations }
    func maximumConcurrentRequests() -> Int { maximumActiveRequests }
}

@MainActor
final class TestSessionInsightState: InsightState {
    private let applyFailure: PipelineFailure?
    private(set) var cards: [InsightCard] = []
    private(set) var appliedContexts: [MeetingContextBatch] = []
    private(set) var resetCount = 0

    init(applyFailure: PipelineFailure? = nil) {
        self.applyFailure = applyFailure
    }

    func apply(
        _ updates: [InsightUpdate],
        supportedBy sourceContext: MeetingContextBatch
    ) throws(PipelineFailure) {
        appliedContexts.append(sourceContext)
        if let applyFailure {
            throw applyFailure
        }
        cards = updates.map {
            InsightCard(
                stableKey: $0.stableKey,
                category: $0.category,
                text: $0.text,
                explicitOwner: $0.explicitOwner,
                state: .new
            )
        }
    }

    func reset() {
        resetCount += 1
        cards.removeAll()
        appliedContexts.removeAll()
    }
}

private extension SpeechRecognitionAvailability {
    static var available: SpeechRecognitionAvailability {
        SpeechRecognitionAvailability(
            transcriberIsAvailable: true,
            requestedLocaleIdentifier: "en-US",
            resolvedLocaleIdentifier: "en-US",
            installedLocale: true,
            assetState: .installed
        )
    }
}
