import Foundation

protocol SessionAudioCapture: AudioCapture {
    func permission() async -> MicrophonePermission
    func checkAvailability() async -> Availability
}

protocol SessionSpeechRecognizer: TemporarySpeechRecognizer {
    func availability() async -> SpeechRecognitionAvailability
}

protocol SessionInsightGenerator: InsightGenerator {
    func availability() async -> Availability
    func startSession(localeIdentifier: String) async throws(PipelineFailure)
    func stop() async
}

protocol MeetingContextFactory: Sendable {
    func makeContext() -> any RollingMeetingContext
}

struct BoundedMeetingContextFactory: MeetingContextFactory, Sendable {
    let configuration: MeetingContextConfiguration
    let tokenEstimator: BoundedRollingMeetingContext.TokenEstimator
    let clock: any MeetingContextClock

    init(
        configuration: MeetingContextConfiguration,
        clock: any MeetingContextClock,
        tokenEstimator: @escaping BoundedRollingMeetingContext.TokenEstimator
    ) {
        self.configuration = configuration
        self.clock = clock
        self.tokenEstimator = tokenEstimator
    }

    func makeContext() -> any RollingMeetingContext {
        BoundedRollingMeetingContext(
            configuration: configuration,
            clock: clock,
            tokenEstimator: tokenEstimator
        )
    }
}

@MainActor
final class SessionLifecycleCoordinator: SessionLifecycle {
    private enum CleanupKind {
        case stop
        case cancel
        case failure(PipelineFailure)
    }

    private let localeIdentifier: String
    private let capture: any SessionAudioCapture
    private let speechRecognizer: any SessionSpeechRecognizer
    private let contextFactory: any MeetingContextFactory
    private let insightGenerator: any SessionInsightGenerator
    private let insightState: any InsightState

    private(set) var status: SessionStatus = .stopped
    private(set) var failure: PipelineFailure?

    private var nextSessionID: UInt64 = 0
    private var activeSessionID: UInt64?
    private var activeContext: (any RollingMeetingContext)?
    private var audioForwardingTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?

    init(
        localeIdentifier: String,
        capture: any SessionAudioCapture,
        speechRecognizer: any SessionSpeechRecognizer,
        contextFactory: any MeetingContextFactory,
        insightGenerator: any SessionInsightGenerator,
        insightState: any InsightState
    ) {
        self.localeIdentifier = localeIdentifier
        self.capture = capture
        self.speechRecognizer = speechRecognizer
        self.contextFactory = contextFactory
        self.insightGenerator = insightGenerator
        self.insightState = insightState
    }

    func checkAvailability() async -> Availability {
        let permission = await capture.permission()
        if permission == .denied {
            return .unavailable(.microphonePermissionDenied)
        }
        if permission == .undetermined {
            return .unavailable(.microphonePermissionUndetermined)
        }

        let captureAvailability = await capture.checkAvailability()
        if case .unavailable(let reason) = captureAvailability,
           !(permission == .undetermined && reason == .microphonePermissionUndetermined) {
            return .unavailable(reason)
        }

        let speechAvailability = await speechRecognizer.availability()
        if let failure = speechAvailability.failure {
            return availability(for: failure)
        }

        return await insightGenerator.availability()
    }

    func start() async throws(PipelineFailure) {
        guard activeSessionID == nil, status != .checkingAvailability else {
            throw .stage(.sessionLifecycle, .invalidState)
        }

        nextSessionID &+= 1
        let sessionID = nextSessionID
        activeSessionID = sessionID
        activeContext = contextFactory.makeContext()
        insightState.reset()
        failure = nil
        status = .checkingAvailability

        do {
            try await preflight()
            try ensureActive(sessionID)

            try await insightGenerator.startSession(localeIdentifier: localeIdentifier)
            try ensureActive(sessionID)

            let audio = try await capture.start()
            try ensureActive(sessionID)

            let forwardedAudio = makeForwardedAudioStream(audio, sessionID: sessionID)
            audioForwardingTask = forwardedAudio.task
            let speech = try await speechRecognizer.recognize(audio: forwardedAudio.stream)
            try ensureActive(sessionID)

            speechTask = Task { [weak self] in
                await self?.consumeSpeech(speech, sessionID: sessionID)
            }
            generationTask = Task { [weak self] in
                await self?.generateBatches(sessionID: sessionID)
            }
            status = .listening
        } catch {
            let failure = error
            await cleanup(sessionID: sessionID, kind: .failure(failure))
            throw failure
        }
    }

    func stop() async {
        guard let sessionID = activeSessionID else {
            status = .stopped
            insightState.reset()
            return
        }
        await cleanup(sessionID: sessionID, kind: .stop)
    }

    func cancel() async {
        guard let sessionID = activeSessionID else {
            status = .stopped
            insightState.reset()
            return
        }
        await cleanup(sessionID: sessionID, kind: .cancel)
    }

    private func preflight() async throws(PipelineFailure) {
        let permission = await capture.permission()
        guard permission != .denied else {
            throw .unavailable(.microphonePermissionDenied)
        }

        let captureAvailability = await capture.checkAvailability()
        if case .unavailable(let reason) = captureAvailability,
           !(permission == .undetermined && reason == .microphonePermissionUndetermined) {
            throw .unavailable(reason)
        }

        let speechAvailability = await speechRecognizer.availability()
        if let failure = speechAvailability.failure {
            throw failure
        }

        let modelAvailability = await insightGenerator.availability()
        guard modelAvailability == .available else {
            throw availabilityFailure(for: modelAvailability)
        }
    }

    private func consumeSpeech(
        _ stream: FinalizedSpeechStream,
        sessionID: UInt64
    ) async {
        guard let context = activeContext else {
            return
        }

        do {
            for try await segment in stream {
                guard activeSessionID == sessionID else {
                    return
                }
                try await context.append(segment)
                guard activeSessionID == sessionID else {
                    return
                }
            }
        } catch let failure as PipelineFailure {
            await fail(failure, sessionID: sessionID)
        } catch is CancellationError {
            await fail(.cancelled, sessionID: sessionID)
        } catch {
            await fail(.stage(.speechRecognition, .failed), sessionID: sessionID)
        }
    }

    private func generateBatches(sessionID: UInt64) async {
        guard let context = activeContext else {
            return
        }

        do {
            while activeSessionID == sessionID {
                guard let batch = try await context.nextBatch() else {
                    return
                }
                guard activeSessionID == sessionID else {
                    return
                }

                status = .processing
                let updates = try await insightGenerator.generate(from: batch)
                guard activeSessionID == sessionID else {
                    return
                }
                try insightState.apply(updates, supportedBy: batch)
                status = .listening
            }
        } catch {
            await fail(error, sessionID: sessionID)
        }
    }

    private func fail(_ failure: PipelineFailure, sessionID: UInt64) async {
        guard activeSessionID == sessionID else {
            return
        }
        await cleanup(sessionID: sessionID, kind: .failure(failure))
    }

    private func cleanup(sessionID: UInt64, kind: CleanupKind) async {
        guard activeSessionID == sessionID else {
            return
        }

        activeSessionID = nil
        let context = activeContext
        activeContext = nil

        let audioTask = audioForwardingTask
        let speechTask = speechTask
        let generationTask = generationTask
        audioForwardingTask = nil
        self.speechTask = nil
        self.generationTask = nil

        audioTask?.cancel()
        speechTask?.cancel()
        generationTask?.cancel()

        switch kind {
        case .stop:
            await speechRecognizer.stop()
            await capture.stop()
            await insightGenerator.stop()
        case .cancel, .failure:
            await speechRecognizer.cancel()
            await capture.cancel()
            await insightGenerator.cancel()
        }

        await context?.cancel()
        await context?.clear()
        insightState.reset()

        switch kind {
        case .failure(let failure):
            self.failure = failure
            status = status(for: failure)
        case .stop, .cancel:
            failure = nil
            status = .stopped
        }
    }

    private func makeForwardedAudioStream(
        _ source: AudioStream,
        sessionID: UInt64
    ) -> (stream: AudioStream, task: Task<Void, Never>) {
        var continuation: AudioStream.Continuation?
        let stream = AudioStream { continuation = $0 }
        let task = Task { [weak self] in
            do {
                for try await chunk in source {
                    continuation?.yield(chunk)
                }
                continuation?.finish()
            } catch let failure as PipelineFailure {
                continuation?.finish(throwing: failure)
                await self?.fail(failure, sessionID: sessionID)
            } catch is CancellationError {
                continuation?.finish(throwing: PipelineFailure.cancelled)
            } catch {
                let failure = PipelineFailure.stage(.audioCapture, .failed)
                continuation?.finish(throwing: failure)
                await self?.fail(failure, sessionID: sessionID)
            }
        }
        return (stream, task)
    }

    private func ensureActive(_ sessionID: UInt64) throws(PipelineFailure) {
        guard activeSessionID == sessionID, !Task.isCancelled else {
            throw .cancelled
        }
    }

    private func availabilityFailure(for availability: Availability) -> PipelineFailure {
        switch availability {
        case .available:
            return .stage(.sessionLifecycle, .invalidState)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    private func availability(for failure: PipelineFailure) -> Availability {
        switch failure {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .stage, .cancelled:
            return .unavailable(.speechRecognitionUnavailable)
        }
    }

    private func status(for failure: PipelineFailure) -> SessionStatus {
        switch failure {
        case .stage(_, .interrupted):
            return .interrupted
        case .unavailable, .stage, .cancelled:
            return .unavailable
        }
    }
}
