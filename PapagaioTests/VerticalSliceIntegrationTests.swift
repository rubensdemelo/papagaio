import Foundation
import XCTest

@MainActor
final class VerticalSliceIntegrationTests: XCTestCase {
    func testVerticalSliceShowsCardsStopsCleansAndRejectsStaleResults() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            delay: .milliseconds(50),
            updates: [],
            updateProvider: { batch in
                let sourceText = batch.segments.first?.text ?? ""
                let cardText = sourceText == "old session" ? "old card" : "new card"
                return [
                    InsightUpdate(
                        stableKey: "decision-1",
                        operation: .add,
                        category: .decision,
                        text: cardText,
                        explicitOwner: nil
                    )
                ]
            },
            ignoresCancellation: true
        )
        let contextFactory = TestMeetingContextFactory()
        let store = InMemoryInsightStore()
        let lifecycle = SessionLifecycleCoordinator(
            localeIdentifier: "en-US",
            capture: capture,
            speechRecognizer: speech,
            contextFactory: contextFactory,
            insightGenerator: generator,
            insightState: store
        )
        let controller = LiveSessionController(
            lifecycle: lifecycle,
            insightStore: store
        )

        await controller.performPrimaryAction()
        XCTAssertEqual(controller.status, SessionStatus.listening)

        let firstSpeechStream = await speech.lastStream()
        firstSpeechStream?.yield(makeSegment(sequence: 1, text: "old session"))
        await waitUntil {
            controller.status == SessionStatus.processing
        }

        await controller.performPrimaryAction()
        XCTAssertEqual(controller.status, SessionStatus.stopped)
        XCTAssertTrue(controller.cards.isEmpty)

        await waitUntil {
            contextFactory.contexts().count == 1
        }
        let firstContext = contextFactory.contexts()[0]
        let firstContextSegments = await firstContext.storedSegments()
        XCTAssertTrue(firstContextSegments.isEmpty)

        await controller.performPrimaryAction()
        XCTAssertEqual(controller.status, SessionStatus.listening)
        let secondSpeechStream = await speech.lastStream()
        secondSpeechStream?.yield(makeSegment(sequence: 1, text: "new session"))

        await waitUntil {
            controller.cards.count == 1 && controller.cards[0].text == "new card"
        }
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(controller.cards.map(\.text), ["new card"])

        await controller.performPrimaryAction()
        XCTAssertEqual(controller.status, SessionStatus.stopped)
        XCTAssertTrue(controller.cards.isEmpty)

        let contexts = contextFactory.contexts()
        XCTAssertEqual(contexts.count, 2)
        let secondContextSegments = await contexts[1].storedSegments()
        let captureStarts = await capture.startCount()
        let captureStops = await capture.stopCount()
        let generatorStarts = await generator.startSessionCount()
        let generatorStops = await generator.stopCount()
        XCTAssertTrue(secondContextSegments.isEmpty)
        XCTAssertEqual(captureStarts, 2)
        XCTAssertEqual(captureStops, 2)
        XCTAssertEqual(generatorStarts, 2)
        XCTAssertEqual(generatorStops, 2)
    }

    func testVerticalSliceRestartsAfterGenerationFailure() async throws {
        let capture = TestSessionAudioCapture()
        let speech = TestSessionSpeechRecognizer()
        let generator = TestSessionInsightGenerator(
            updates: [
                InsightUpdate(
                    stableKey: "question-1",
                    operation: .add,
                    category: .question,
                    text: "new question",
                    explicitOwner: nil
                )
            ],
            generateFailure: .stage(.insightGeneration, .failed)
        )
        let contextFactory = TestMeetingContextFactory()
        let store = InMemoryInsightStore()
        let lifecycle = SessionLifecycleCoordinator(
            localeIdentifier: "en-US",
            capture: capture,
            speechRecognizer: speech,
            contextFactory: contextFactory,
            insightGenerator: generator,
            insightState: store
        )
        let controller = LiveSessionController(
            lifecycle: lifecycle,
            insightStore: store
        )

        await controller.performPrimaryAction()
        let firstSpeechStream = await speech.lastStream()
        firstSpeechStream?.yield(makeSegment(sequence: 1, text: "first attempt"))
        await waitUntil {
            controller.status == SessionStatus.unavailable
        }
        XCTAssertTrue(controller.cards.isEmpty)

        await controller.performPrimaryAction()
        let secondSpeechStream = await speech.lastStream()
        secondSpeechStream?.yield(makeSegment(sequence: 1, text: "second attempt"))
        await waitUntil {
            controller.cards.count == 1 && controller.cards[0].text == "new question"
        }

        await controller.performPrimaryAction()
        XCTAssertEqual(controller.status, SessionStatus.stopped)
        XCTAssertTrue(controller.cards.isEmpty)
        XCTAssertEqual(contextFactory.contexts().count, 2)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for vertical slice transition")
    }

    private func makeSegment(sequence: UInt64, text: String) -> FinalizedSpeechSegment {
        FinalizedSpeechSegment(
            sequenceNumber: sequence,
            text: text,
            startOffset: .zero,
            endOffset: .seconds(1)
        )
    }
}
