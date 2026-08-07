import XCTest

final class SpeechRecognitionAdapterTests: XCTestCase {
    func testAssetInventoryStatesAreRepresentedExplicitly() {
        XCTAssertEqual(SpeechAssetState(.unsupported), .unsupported)
        XCTAssertEqual(SpeechAssetState(.supported), .supported)
        XCTAssertEqual(SpeechAssetState(.downloading), .downloading)
        XCTAssertEqual(SpeechAssetState(.installed), .installed)
    }

    func testUnavailableLocaleAndAssetsPreventAnalyzerCreation() async throws {
        let unsupportedLocale = SpeechRecognitionAvailability(
            transcriberIsAvailable: true,
            requestedLocaleIdentifier: "xx-XX",
            resolvedLocaleIdentifier: nil,
            installedLocale: false,
            assetState: .unsupported
        )
        let unsupportedFactory = TestSpeechRecognitionSessionFactory()
        let unsupportedAdapter = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: "xx-XX",
            availabilityProvider: FixedSpeechAvailabilityProvider(
                value: unsupportedLocale
            ),
            sessionFactory: unsupportedFactory
        )

        do {
            _ = try await unsupportedAdapter.recognize(audio: emptyAudioStream())
            XCTFail("Unsupported locales must prevent analyzer creation")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .unavailable(.speechLocaleUnsupported(identifier: "xx-XX"))
            )
        }
        XCTAssertEqual(unsupportedFactory.makeCount, 0)

        let assetsNotReady = SpeechRecognitionAvailability(
            transcriberIsAvailable: true,
            requestedLocaleIdentifier: "en-US",
            resolvedLocaleIdentifier: "en-US",
            installedLocale: true,
            assetState: .downloading
        )
        let assetsFactory = TestSpeechRecognitionSessionFactory()
        let assetsAdapter = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: "en-US",
            availabilityProvider: FixedSpeechAvailabilityProvider(value: assetsNotReady),
            sessionFactory: assetsFactory
        )

        do {
            _ = try await assetsAdapter.recognize(audio: emptyAudioStream())
            XCTFail("Unavailable assets must prevent analyzer creation")
        } catch let failure {
            XCTAssertEqual(failure, .unavailable(.speechAssetsNotReady))
        }
        XCTAssertEqual(assetsFactory.makeCount, 0)
    }

    func testSupportedAssetsArePreparedBeforeRecognition() async throws {
        let provider = RecordingSpeechAvailabilityProvider(
            initial: SpeechRecognitionAvailability(
                transcriberIsAvailable: true,
                requestedLocaleIdentifier: "en-US",
                resolvedLocaleIdentifier: "en-US",
                installedLocale: true,
                assetState: .supported
            ),
            prepared: availableSpeech(locale: "en-US")
        )
        let adapter = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: "en-US",
            availabilityProvider: provider,
            sessionFactory: TestSpeechRecognitionSessionFactory()
        )

        try await adapter.prepare()

        let prepareCount = await provider.prepareCount
        let availability = await adapter.availability()
        XCTAssertEqual(prepareCount, 1)
        XCTAssertNil(availability.failure)
    }

    func testSyntheticAudioSelectsCompatibleFormatAndDeliversFinalResultsOnly() async throws {
        let session = TestSpeechRecognitionSession(
            analysisFormat: MicrophoneAudioFormat(sampleRate: 16_000, channelCount: 1),
            results: [
                SpeechTranscriptionResult(
                    text: "partial",
                    startOffset: .zero,
                    endOffset: .milliseconds(20),
                    isFinal: false
                ),
                SpeechTranscriptionResult(
                    text: " hello ",
                    startOffset: .zero,
                    endOffset: .milliseconds(40),
                    isFinal: true
                ),
                SpeechTranscriptionResult(
                    text: "   ",
                    startOffset: .milliseconds(40),
                    endOffset: .milliseconds(60),
                    isFinal: true
                ),
                SpeechTranscriptionResult(
                    text: "world",
                    startOffset: .milliseconds(60),
                    endOffset: .milliseconds(80),
                    isFinal: true
                ),
            ]
        )
        let factory = TestSpeechRecognitionSessionFactory(session: session)
        let adapter = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: "en-US",
            availabilityProvider: FixedSpeechAvailabilityProvider(
                value: availableSpeech(locale: "en-US")
            ),
            sessionFactory: factory
        )

        let speechStream = try await adapter.recognize(
            audio: syntheticAudioStream(count: 2)
        )
        var segments: [FinalizedSpeechSegment] = []
        for try await segment in speechStream {
            segments.append(segment)
        }

        XCTAssertEqual(
            segments,
            [
                FinalizedSpeechSegment(
                    sequenceNumber: 0,
                    text: "hello",
                    startOffset: .zero,
                    endOffset: .milliseconds(40)
                ),
                FinalizedSpeechSegment(
                    sequenceNumber: 1,
                    text: "world",
                    startOffset: .milliseconds(60),
                    endOffset: .milliseconds(80)
                ),
            ]
        )
        let preparedFormat = await session.preparedFormat
        let receivedInputs = await session.receivedInputs
        let didStart = await session.didStart
        let didCancel = await session.didCancel
        XCTAssertEqual(preparedFormat, .init(sampleRate: 16_000, channelCount: 1))
        XCTAssertEqual(receivedInputs.count, 2)
        XCTAssertEqual(receivedInputs.map(\.analysisFormat), [
            .init(sampleRate: 16_000, channelCount: 1),
            .init(sampleRate: 16_000, channelCount: 1),
        ])
        XCTAssertTrue(didStart)
        XCTAssertFalse(didCancel)
    }

    func testAnalyzerFailureIsForwardedAndTeardownRuns() async throws {
        let session = TestSpeechRecognitionSession(
            analysisFormat: MicrophoneAudioFormat(sampleRate: 16_000, channelCount: 1),
            prepareFailure: .stage(.speechRecognition, .failed),
            results: []
        )
        let adapter = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: "en-US",
            availabilityProvider: FixedSpeechAvailabilityProvider(
                value: availableSpeech(locale: "en-US")
            ),
            sessionFactory: TestSpeechRecognitionSessionFactory(session: session)
        )

        let stream = try await adapter.recognize(audio: syntheticAudioStream(count: 1))
        do {
            for try await _ in stream { }
            XCTFail("Analyzer preparation failure must be surfaced")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure, .stage(.speechRecognition, .failed))
        }
        let didCancel = await session.didCancel
        XCTAssertTrue(didCancel)
    }

    func testCancellationStopsInputAndTearsDownAnalyzerIdempotently() async throws {
        let session = TestSpeechRecognitionSession(
            analysisFormat: MicrophoneAudioFormat(sampleRate: 16_000, channelCount: 1),
            results: [],
            waitsForInputToFinish: true
        )
        let adapter = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: "en-US",
            availabilityProvider: FixedSpeechAvailabilityProvider(
                value: availableSpeech(locale: "en-US")
            ),
            sessionFactory: TestSpeechRecognitionSessionFactory(session: session)
        )
        let audioContinuation = LockedContinuation<AudioChunk>()
        let audio = AsyncThrowingStream<AudioChunk, any Error>(
            bufferingPolicy: .bufferingOldest(2)
        ) { continuation in
            audioContinuation.store(continuation)
        }

        let speechStream = try await adapter.recognize(audio: audio)
        let consumer = Task { () -> PipelineFailure? in
            do {
                for try await _ in speechStream { }
                return nil
            } catch let failure as PipelineFailure {
                return failure
            } catch {
                return .stage(.speechRecognition, .failed)
            }
        }
        audioContinuation.yield(syntheticChunk(sequenceNumber: 1))
        await waitUntil { await session.didStart }

        await adapter.cancel()
        await adapter.cancel()

        let consumerResult = await consumer.value
        let cancelCount = await session.cancelCount
        let didCancel = await session.didCancel
        XCTAssertEqual(consumerResult, .cancelled)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(didCancel)
    }

    private func availableSpeech(locale: String) -> SpeechRecognitionAvailability {
        SpeechRecognitionAvailability(
            transcriberIsAvailable: true,
            requestedLocaleIdentifier: locale,
            resolvedLocaleIdentifier: locale,
            installedLocale: true,
            assetState: .installed
        )
    }

    private func emptyAudioStream() -> AudioStream {
        AudioStream { continuation in
            continuation.finish()
        }
    }

    private func syntheticAudioStream(count: Int) -> AudioStream {
        AudioStream { continuation in
            for sequenceNumber in 0..<UInt64(count) {
                continuation.yield(syntheticChunk(sequenceNumber: sequenceNumber))
            }
            continuation.finish()
        }
    }

    private func syntheticChunk(sequenceNumber: UInt64) -> AudioChunk {
        AudioChunk(
            sequenceNumber: sequenceNumber,
            duration: .milliseconds(20),
            sampleRate: 48_000,
            channelCount: 1,
            samples: Array(repeating: Float(sequenceNumber) / 10, count: 960)
        )
    }

    private func waitUntil(
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<1000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic test state")
    }
}

private struct FixedSpeechAvailabilityProvider: SpeechAvailabilityProviding, Sendable {
    let value: SpeechRecognitionAvailability

    func inspect(localeIdentifier: String) async -> SpeechRecognitionAvailability {
        value
    }

    func prepare(localeIdentifier: String) async -> SpeechRecognitionAvailability {
        value
    }
}

private actor RecordingSpeechAvailabilityProvider: SpeechAvailabilityProviding {
    private var current: SpeechRecognitionAvailability
    private let prepared: SpeechRecognitionAvailability
    private(set) var prepareCount = 0

    init(
        initial: SpeechRecognitionAvailability,
        prepared: SpeechRecognitionAvailability
    ) {
        current = initial
        self.prepared = prepared
    }

    func inspect(localeIdentifier: String) async -> SpeechRecognitionAvailability {
        current
    }

    func prepare(localeIdentifier: String) async -> SpeechRecognitionAvailability {
        prepareCount += 1
        current = prepared
        return prepared
    }
}

private final class TestSpeechRecognitionSessionFactory:
    SpeechRecognitionSessionFactory, @unchecked Sendable {
    private let session: TestSpeechRecognitionSession
    private(set) var makeCount = 0

    init(
        session: TestSpeechRecognitionSession = TestSpeechRecognitionSession(
            analysisFormat: MicrophoneAudioFormat(sampleRate: 16_000, channelCount: 1),
            results: []
        )
    ) {
        self.session = session
    }

    func makeSession(localeIdentifier: String) -> any SpeechRecognitionSession {
        makeCount += 1
        return session
    }
}

private actor TestSpeechRecognitionSession: SpeechRecognitionSession {
    let analysisFormat: MicrophoneAudioFormat
    let prepareFailure: PipelineFailure?
    let waitsForInputToFinish: Bool
    private let resultStream: SpeechTranscriptionStream
    private(set) var preparedFormat: MicrophoneAudioFormat?
    private(set) var receivedInputs: [SpeechAudioInput] = []
    private(set) var didStart = false
    private(set) var didCancel = false
    private(set) var cancelCount = 0

    init(
        analysisFormat: MicrophoneAudioFormat,
        prepareFailure: PipelineFailure? = nil,
        results: [SpeechTranscriptionResult],
        waitsForInputToFinish: Bool = false
    ) {
        self.analysisFormat = analysisFormat
        self.prepareFailure = prepareFailure
        self.waitsForInputToFinish = waitsForInputToFinish
        resultStream = SpeechTranscriptionStream(
            bufferingPolicy: .bufferingOldest(16)
        ) { continuation in
            for result in results {
                continuation.yield(result)
            }
            if !waitsForInputToFinish {
                continuation.finish()
            }
        }
    }

    nonisolated func bestAvailableAudioFormat(
        considering naturalFormat: MicrophoneAudioFormat
    ) async -> MicrophoneAudioFormat? {
        analysisFormat
    }

    func prepare(toAnalyze format: MicrophoneAudioFormat) async throws(PipelineFailure) {
        preparedFormat = format
        if let prepareFailure {
            throw prepareFailure
        }
    }

    func start(input: SpeechAudioInputStream) async throws(PipelineFailure) {
        didStart = true
        do {
            for try await value in input {
                receivedInputs.append(value)
            }
        } catch let failure as PipelineFailure {
            throw failure
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .stage(.speechRecognition, .failed)
        }
    }

    nonisolated func results() -> SpeechTranscriptionStream {
        resultStream
    }

    func cancelAndFinishNow() async {
        cancelCount += 1
        didCancel = true
    }
}

private final class LockedContinuation<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Element, any Error>.Continuation?

    func store(_ continuation: AsyncThrowingStream<Element, any Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ element: Element) {
        lock.lock()
        continuation?.yield(element)
        lock.unlock()
    }
}
