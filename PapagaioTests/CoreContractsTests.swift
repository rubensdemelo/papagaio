import XCTest

final class CoreContractsTests: XCTestCase {
    func testDomainValuesHaveStableValueSemantics() {
        let update = InsightUpdate(
            stableKey: "decision-1",
            operation: .add,
            category: .decision,
            text: "A decision",
            explicitOwner: nil
        )
        let copy = InsightUpdate(
            stableKey: "decision-1",
            operation: .add,
            category: .decision,
            text: "A decision",
            explicitOwner: nil
        )

        XCTAssertEqual(update, copy)
        XCTAssertEqual(SessionID(rawValue: 7), SessionID(rawValue: 7))
        XCTAssertEqual(Availability.unavailable(.speechAssetsNotReady), .unavailable(.speechAssetsNotReady))
        XCTAssertEqual(
            PipelineFailure.stage(.audioCapture, .interrupted),
            PipelineFailure.stage(.audioCapture, .interrupted)
        )
    }

    func testAudioDoubleOutputsAndCompletes() async throws {
        let chunk = AudioChunk(
            sequenceNumber: 1,
            duration: .milliseconds(20),
            sampleRate: 48_000,
            channelCount: 1,
            samples: [0.1, 0.2]
        )
        let capture = DeterministicAudioCapture(
            plan: DeterministicStreamPlan(
                stage: .audioCapture,
                events: [.output(chunk)]
            )
        )

        let stream = try await capture.start()
        var output: [AudioChunk] = []
        for try await value in stream {
            output.append(value)
        }

        XCTAssertEqual(output, [chunk])
        await capture.stop()
    }

    func testSpeechDoubleDelaysThenOutputsFinalizedSegments() async throws {
        let segment = FinalizedSpeechSegment(
            sequenceNumber: 1,
            text: "temporary test text",
            startOffset: .zero,
            endOffset: .seconds(1)
        )
        let recognizer = DeterministicSpeechRecognizer(
            plan: DeterministicStreamPlan(
                stage: .speechRecognition,
                events: [.delay(.milliseconds(1)), .output(segment)]
            )
        )
        let audio = DeterministicAudioCapture(
            plan: DeterministicStreamPlan(stage: .audioCapture, events: [])
        )

        let audioStream = try await audio.start()
        let speechStream = try await recognizer.recognize(audio: audioStream)
        var output: [FinalizedSpeechSegment] = []
        for try await value in speechStream {
            output.append(value)
        }

        XCTAssertEqual(output, [segment])
        await recognizer.stop()
    }

    func testStreamDoubleSurfacesFailureAndInterruption() async throws {
        let failure = PipelineFailure.stage(.audioCapture, .failed)
        let failedCapture = DeterministicAudioCapture(
            plan: DeterministicStreamPlan(
                stage: .audioCapture,
                events: [.failure(failure)]
            )
        )
        let interruptedCapture = DeterministicAudioCapture(
            plan: DeterministicStreamPlan(
                stage: .audioCapture,
                events: [.interruption]
            )
        )

        try await assertStreamFailure(try await failedCapture.start(), equals: failure)
        try await assertStreamFailure(
            try await interruptedCapture.start(),
            equals: .stage(.audioCapture, .interrupted)
        )
    }

    func testLongLivedDoublesCancelWithoutProducingLaterOutput() async throws {
        let chunk = AudioChunk(
            sequenceNumber: 1,
            duration: .seconds(1),
            sampleRate: 48_000,
            channelCount: 1,
            samples: [0.1]
        )
        let capture = DeterministicAudioCapture(
            plan: DeterministicStreamPlan(
                stage: .audioCapture,
                events: [.delay(.seconds(5)), .output(chunk)]
            )
        )
        let stream = try await capture.start()
        let consumer = Task { () -> PipelineFailure? in
            do {
                for try await _ in stream { }
                return nil
            } catch let failure as PipelineFailure {
                return failure
            } catch {
                return .stage(.audioCapture, .failed)
            }
        }

        await capture.cancel()
        let result = await consumer.value
        XCTAssertEqual(result, .cancelled)
    }

    func testContextDoubleCancelsAndClears() async throws {
        let context = DeterministicRollingMeetingContext()
        let segment = FinalizedSpeechSegment(
            sequenceNumber: 1,
            text: "temporary test text",
            startOffset: .zero,
            endOffset: .seconds(1)
        )

        try await context.append(segment)
        await context.cancel()

        do {
            _ = try await context.nextBatch()
            XCTFail("A cancelled context must not return a batch")
        } catch let failure {
            XCTAssertEqual(failure, .cancelled)
        }
    }

    func testInsightGeneratorDoubleSupportsDelayFailureAndCancellation() async throws {
        let update = InsightUpdate(
            stableKey: "question-1",
            operation: .add,
            category: .question,
            text: "An open question",
            explicitOwner: nil
        )
        let batch = MeetingContextBatch(segments: [])
        let generator = DeterministicInsightGenerator(
            delay: .milliseconds(1),
            result: .success([update])
        )

        let output = try await generator.generate(from: batch)
        XCTAssertEqual(output, [update])

        let failingGenerator = DeterministicInsightGenerator(
            result: .failure(.stage(.insightGeneration, .failed))
        )
        do {
            _ = try await failingGenerator.generate(from: batch)
            XCTFail("The configured generator failure must be surfaced")
        } catch let failure {
            XCTAssertEqual(failure, .stage(.insightGeneration, .failed))
        }

        let cancellableGenerator = DeterministicInsightGenerator(
            delay: .seconds(5),
            result: .success([update])
        )
        let generation = Task {
            try await cancellableGenerator.generate(from: batch)
        }
        await Task.yield()
        await cancellableGenerator.cancel()

        do {
            _ = try await generation.value
            XCTFail("A cancelled generator must not return output")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure, .cancelled)
        }
    }

    @MainActor
    func testStateAndSessionDoublesRecordContractCalls() async throws {
        let state = DeterministicInsightState()
        let update = InsightUpdate(
            stableKey: "action-1",
            operation: .add,
            category: .action,
            text: "An action",
            explicitOwner: "Alex"
        )
        state.apply([update])
        XCTAssertEqual(state.appliedUpdates, [[update]])
        state.reset()
        XCTAssertTrue(state.appliedUpdates.isEmpty)

        let lifecycle = DeterministicSessionLifecycle()
        let availability = await lifecycle.checkAvailability()
        XCTAssertEqual(availability, .available)
        try await lifecycle.start()
        XCTAssertEqual(lifecycle.status, .listening)
        await lifecycle.cancel()
        XCTAssertEqual(lifecycle.status, .stopped)
        XCTAssertEqual(lifecycle.cancelCount, 1)
    }

    private func assertStreamFailure<Element: Sendable>(
        _ stream: AsyncThrowingStream<Element, any Error>,
        equals expected: PipelineFailure
    ) async throws {
        do {
            for try await _ in stream { }
            XCTFail("The stream should have failed")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure, expected)
        }
    }
}
