import XCTest
import Observation

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
        let sourceContext = MeetingContextBatch(segments: [])
        try state.apply([update], supportedBy: sourceContext)
        XCTAssertEqual(state.appliedUpdates, [[update]])
        XCTAssertEqual(state.supportingContexts, [sourceContext])
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

@MainActor
final class InMemoryInsightStoreTests: XCTestCase {
    func testAddsCardAndPublishesObservableState() throws {
        let store = InMemoryInsightStore()
        let change = expectation(description: "cards changed")
        withObservationTracking {
            _ = store.cards
        } onChange: {
            change.fulfill()
        }

        try store.apply(
            [update(key: " important-1 ", category: .important, text: "  Useful point  ")],
            supportedBy: context()
        )

        XCTAssertEqual(XCTWaiter.wait(for: [change], timeout: 0.1), .completed)
        XCTAssertEqual(
            store.cards,
            [
                InsightCard(
                    stableKey: "important-1",
                    category: .important,
                    text: "Useful point",
                    explicitOwner: nil,
                    state: .new
                )
            ]
        )
    }

    func testDuplicateAddAndUpdateUseStableKeyWithoutAccumulatingCards() throws {
        let store = InMemoryInsightStore()

        try store.apply(
            [update(key: "Decision-1", category: .decision, text: "Use option A")],
            supportedBy: context()
        )
        try store.apply(
            [update(key: " decision-1 ", category: .decision, text: "Use option B")],
            supportedBy: context()
        )

        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards[0].stableKey, "decision-1")
        XCTAssertEqual(store.cards[0].text, "Use option B")
        XCTAssertEqual(store.cards[0].state, .updated)

        try store.apply(
            [
                update(
                    key: "DECISION-1",
                    operation: .update,
                    category: .decision,
                    text: "Use option C"
                )
            ],
            supportedBy: context()
        )

        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards[0].text, "Use option C")
        XCTAssertEqual(store.cards[0].state, .updated)
    }

    func testResolveKnownCardAndIgnoreUnknownStableKeys() throws {
        let store = InMemoryInsightStore()
        try store.apply(
            [update(key: "question-1", category: .question, text: "Which option?")],
            supportedBy: context()
        )

        try store.apply(
            [
                update(
                    key: "question-1",
                    operation: .resolve,
                    category: .question,
                    text: "Option A was selected"
                ),
                update(
                    key: "unknown",
                    operation: .resolve,
                    category: .risk,
                    text: "No matching risk"
                ),
                update(
                    key: "unknown-update",
                    operation: .update,
                    category: .important,
                    text: "No matching card"
                )
            ],
            supportedBy: context()
        )

        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards[0].text, "Option A was selected")
        XCTAssertEqual(store.cards[0].state, .resolved)
    }

    func testActiveAndRetainedCardCountsStayBounded() throws {
        let store = InMemoryInsightStore(
            configuration: InsightStoreConfiguration(maximumActiveCardCount: 2)
        )

        try store.apply(
            [
                update(key: "point-1", category: .important, text: "First"),
                update(key: "point-2", category: .important, text: "Second"),
                update(key: "point-3", category: .important, text: "Dropped at capacity")
            ],
            supportedBy: context()
        )

        XCTAssertEqual(store.cards.map(\.stableKey), ["point-1", "point-2"])

        try store.apply(
            [
                update(
                    key: "point-1",
                    operation: .resolve,
                    category: .important,
                    text: "First resolved"
                ),
                update(key: "point-4", category: .important, text: "Fourth")
            ],
            supportedBy: context()
        )

        XCTAssertEqual(store.cards.count, 2)
        XCTAssertEqual(store.cards.map(\.stableKey), ["point-2", "point-4"])
        XCTAssertEqual(store.cards.filter { $0.state != .resolved }.count, 2)
    }

    func testMalformedBatchIsRejectedAtomically() throws {
        let store = InMemoryInsightStore(
            configuration: InsightStoreConfiguration(
                maximumUpdateCount: 2,
                maximumStableKeyLength: 12,
                maximumTextLength: 12
            )
        )
        try store.apply(
            [update(key: "valid", category: .important, text: "Kept")],
            supportedBy: context()
        )
        let originalCards = store.cards

        let malformedBatches: [[InsightUpdate]] = [
            [update(key: " ", category: .important, text: "Point")],
            [update(key: "key", category: .important, text: " \n ")],
            [update(key: "too-long-key-1", category: .important, text: "Point")],
            [update(key: "key", category: .important, text: "Text is much too long")],
            [update(key: "bad\nkey", category: .important, text: "Point")],
            [
                update(key: "same", category: .important, text: "First"),
                update(key: " SAME ", category: .important, text: "Second")
            ],
            [
                update(key: "one", category: .important, text: "One"),
                update(key: "two", category: .important, text: "Two"),
                update(key: "three", category: .important, text: "Three")
            ]
        ]

        for batch in malformedBatches {
            XCTAssertThrowsError(try store.apply(batch, supportedBy: context())) { error in
                XCTAssertEqual(
                    error as? PipelineFailure,
                    .stage(.insightState, .invalidState)
                )
            }
            XCTAssertEqual(store.cards, originalCards)
        }
    }

    func testOwnerIsKeptOnlyForExplicitlySupportedAction() throws {
        let store = InMemoryInsightStore()
        let source = context(text: "Alex owns the migration follow-up. Planning continues tomorrow.")

        try store.apply(
            [
                update(
                    key: "action-supported",
                    category: .action,
                    text: "Complete the migration follow-up",
                    owner: "Alex"
                ),
                update(
                    key: "action-inferred",
                    category: .action,
                    text: "Prepare the plan",
                    owner: "Morgan"
                ),
                update(
                    key: "action-partial-name",
                    category: .action,
                    text: "Prepare another plan",
                    owner: "Al"
                ),
                update(
                    key: "decision-owner",
                    category: .decision,
                    text: "Use the migration plan",
                    owner: "Alex"
                )
            ],
            supportedBy: source
        )

        XCTAssertEqual(store.cards[0].explicitOwner, "Alex")
        XCTAssertNil(store.cards[1].explicitOwner)
        XCTAssertNil(store.cards[2].explicitOwner)
        XCTAssertNil(store.cards[3].explicitOwner)
    }

    func testResetClearsAllInsightState() throws {
        let store = InMemoryInsightStore()
        try store.apply(
            [update(key: "risk-1", category: .risk, text: "A risk")],
            supportedBy: context()
        )

        store.reset()

        XCTAssertTrue(store.cards.isEmpty)
    }

    private func update(
        key: String,
        operation: InsightOperation = .add,
        category: InsightCategory,
        text: String,
        owner: String? = nil
    ) -> InsightUpdate {
        InsightUpdate(
            stableKey: key,
            operation: operation,
            category: category,
            text: text,
            explicitOwner: owner
        )
    }

    private func context(text: String = "Synthetic context") -> MeetingContextBatch {
        MeetingContextBatch(
            segments: [
                FinalizedSpeechSegment(
                    sequenceNumber: 1,
                    text: text,
                    startOffset: .zero,
                    endOffset: .seconds(1)
                )
            ]
        )
    }
}
