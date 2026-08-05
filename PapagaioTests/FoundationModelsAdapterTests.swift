import Foundation
import FoundationModels
import XCTest

final class FoundationModelsAdapterTests: XCTestCase {
    func testAvailabilityReasonsMapToDomainReasons() {
        XCTAssertEqual(
            FoundationModelsAvailabilityMapper.map(.available),
            .available
        )
        XCTAssertEqual(
            FoundationModelsAvailabilityMapper.map(
                .unavailable(.deviceNotEligible)
            ),
            .unavailable(.languageModelDeviceNotEligible)
        )
        XCTAssertEqual(
            FoundationModelsAvailabilityMapper.map(
                .unavailable(.appleIntelligenceNotEnabled)
            ),
            .unavailable(.appleIntelligenceDisabled)
        )
        XCTAssertEqual(
            FoundationModelsAvailabilityMapper.map(
                .unavailable(.modelNotReady)
            ),
            .unavailable(.languageModelNotReady)
        )
    }

    func testLocaleValidationAndOneSessionPerListeningSession() async throws {
        let session = RecordingFoundationModelsSession(
            response: FoundationInsightResponse(updates: [])
        )
        let runtime = FakeFoundationModelsRuntime(
            availability: .available,
            supportedLocales: ["en-US"],
            session: session
        )
        let generator = FoundationModelsInsightGenerator(runtime: runtime)

        do {
            try await generator.startSession(localeIdentifier: "fr-FR")
            XCTFail("An unsupported locale must prevent session creation")
        } catch let failure {
            XCTAssertEqual(
                failure,
                .unavailable(.languageModelLocaleUnsupported(identifier: "fr-FR"))
            )
        }
        let unsupportedSessionCount = await runtime.sessionCount()
        XCTAssertEqual(unsupportedSessionCount, 0)

        try await generator.startSession(localeIdentifier: "en-US")
        let firstSessionCount = await runtime.sessionCount()
        XCTAssertEqual(firstSessionCount, 1)

        do {
            try await generator.startSession(localeIdentifier: "en-US")
            XCTFail("A listening session must own one model session")
        } catch let failure {
            XCTAssertEqual(failure, .stage(.insightGeneration, .invalidState))
        }

        await generator.stop()
        try await generator.startSession(localeIdentifier: "en-US")
        let secondSessionCount = await runtime.sessionCount()
        XCTAssertEqual(secondSessionCount, 2)
    }

    func testTranslationKeepsSupportedOwnerAndRemovesUnsupportedOwner() throws {
        let batch = MeetingContextBatch(
            segments: [
                FinalizedSpeechSegment(
                    sequenceNumber: 1,
                    text: "Alex owns the migration follow-up.",
                    startOffset: .zero,
                    endOffset: .seconds(1)
                )
            ]
        )
        let response = FoundationInsightResponse(
            updates: [
                FoundationInsightUpdate(
                    stableKey: " action-1 ",
                    operation: .add,
                    category: .action,
                    text: "Complete the migration follow-up.",
                    explicitOwner: "Alex"
                ),
                FoundationInsightUpdate(
                    stableKey: "decision-1",
                    operation: .add,
                    category: .decision,
                    text: "Use the migration plan.",
                    explicitOwner: "Invented Owner"
                )
            ]
        )

        let updates = try FoundationModelsInsightTranslator.translate(response, from: batch)

        XCTAssertEqual(updates[0].stableKey, "action-1")
        XCTAssertEqual(updates[0].explicitOwner, "Alex")
        XCTAssertNil(updates[1].explicitOwner)
    }

    func testMalformedAndExcessiveGeneratedOutputIsRejected() {
        let batch = MeetingContextBatch(segments: [])
        let malformed = FoundationInsightResponse(
            updates: [
                FoundationInsightUpdate(
                    stableKey: " ",
                    operation: .add,
                    category: .important,
                    text: "Useful point",
                    explicitOwner: nil
                )
            ]
        )
        let excessive = FoundationInsightResponse(
            updates: (0..<FoundationModelsInsightTranslator.maximumUpdateCount + 1).map { index in
                FoundationInsightUpdate(
                    stableKey: "key-\(index)",
                    operation: .add,
                    category: .important,
                    text: "Useful point",
                    explicitOwner: nil
                )
            }
        )

        XCTAssertThrowsError(try FoundationModelsInsightTranslator.translate(malformed, from: batch)) { error in
            XCTAssertEqual(
                error as? PipelineFailure,
                .stage(.insightGeneration, .invalidState)
            )
        }
        XCTAssertThrowsError(try FoundationModelsInsightTranslator.translate(excessive, from: batch)) { error in
            XCTAssertEqual(
                error as? PipelineFailure,
                .stage(.insightGeneration, .invalidState)
            )
        }
    }

    func testInstructionsAndPromptKeepTheirBoundaries() async throws {
        let meetingText = "Synthetic meeting phrase: Alex owns migration follow-up."
        let session = RecordingFoundationModelsSession(
            response: FoundationInsightResponse(updates: [])
        )
        let runtime = FakeFoundationModelsRuntime(
            availability: .available,
            supportedLocales: ["en-US"],
            session: session
        )
        let generator = FoundationModelsInsightGenerator(runtime: runtime)
        let batch = MeetingContextBatch(
            segments: [
                FinalizedSpeechSegment(
                    sequenceNumber: 1,
                    text: meetingText,
                    startOffset: .zero,
                    endOffset: .seconds(1)
                )
            ]
        )

        try await generator.startSession(localeIdentifier: "en-US")
        _ = try await generator.generate(from: batch)

        let prompts = await session.prompts()
        let instructions = await runtime.instructions()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.contains("<MEETING_TEXT>"), true)
        XCTAssertEqual(prompts.first?.contains(meetingText), true)
        XCTAssertFalse(instructions.contains(meetingText))
        XCTAssertTrue(FoundationModelsPrompt.instructions.contains("untrusted"))
    }

    func testGenerationRequestsAreSerialized() async throws {
        let session = RecordingFoundationModelsSession(
            response: FoundationInsightResponse(updates: []),
            delay: .milliseconds(10)
        )
        let runtime = FakeFoundationModelsRuntime(
            availability: .available,
            supportedLocales: ["en-US"],
            session: session
        )
        let generator = FoundationModelsInsightGenerator(runtime: runtime)
        try await generator.startSession(localeIdentifier: "en-US")

        let batch = MeetingContextBatch(segments: [])
        async let first = generator.generate(from: batch)
        async let second = generator.generate(from: batch)
        _ = try await (first, second)

        let maximumConcurrentRequests = await session.maximumConcurrentRequests()
        XCTAssertEqual(maximumConcurrentRequests, 1)
    }

    func testFailureAndCancellationResetTheModelSession() async throws {
        let failingSession = RecordingFoundationModelsSession(
            response: FoundationInsightResponse(updates: []),
            failure: .failed
        )
        let runtime = FakeFoundationModelsRuntime(
            availability: .available,
            supportedLocales: ["en-US"],
            session: failingSession
        )
        let generator = FoundationModelsInsightGenerator(runtime: runtime)
        let batch = MeetingContextBatch(segments: [])

        try await generator.startSession(localeIdentifier: "en-US")
        do {
            _ = try await generator.generate(from: batch)
            XCTFail("The configured model failure must propagate")
        } catch let failure {
            XCTAssertEqual(failure, .stage(.insightGeneration, .failed))
        }
        do {
            _ = try await generator.generate(from: batch)
            XCTFail("A failed session must be reset")
        } catch let failure {
            XCTAssertEqual(failure, .stage(.insightGeneration, .invalidState))
        }

        let delayedSession = RecordingFoundationModelsSession(
            response: FoundationInsightResponse(updates: []),
            delay: .seconds(5)
        )
        let delayedRuntime = FakeFoundationModelsRuntime(
            availability: .available,
            supportedLocales: ["en-US"],
            session: delayedSession
        )
        let cancellableGenerator = FoundationModelsInsightGenerator(runtime: delayedRuntime)
        try await cancellableGenerator.startSession(localeIdentifier: "en-US")
        let generation = Task {
            try await cancellableGenerator.generate(from: batch)
        }
        await Task.yield()
        await cancellableGenerator.cancel()

        do {
            _ = try await generation.value
            XCTFail("Cancellation must stop generation")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        do {
            _ = try await cancellableGenerator.generate(from: batch)
            XCTFail("A cancelled session must be reset")
        } catch let failure {
            XCTAssertEqual(failure, .stage(.insightGeneration, .invalidState))
        }
    }
}

private enum FakeFoundationModelsError: Error, Sendable {
    case failed
}

private actor RecordingFoundationModelsSession: FoundationModelsSession {
    let response: FoundationInsightResponse
    let delay: Duration
    let failure: FakeFoundationModelsError?
    private var recordedPrompts: [String] = []
    private var activeRequests = 0
    private var maximumActiveRequests = 0

    init(
        response: FoundationInsightResponse,
        delay: Duration = .zero,
        failure: FakeFoundationModelsError? = nil
    ) {
        self.response = response
        self.delay = delay
        self.failure = failure
    }

    func generate(prompt: String) async throws -> FoundationInsightResponse {
        recordedPrompts.append(prompt)
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }

        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        if let failure {
            throw failure
        }
        return response
    }

    func prompts() -> [String] {
        recordedPrompts
    }

    func maximumConcurrentRequests() -> Int {
        maximumActiveRequests
    }
}

private actor FakeFoundationModelsRuntime: FoundationModelsRuntime {
    let configuredAvailability: Availability
    let supportedLocales: Set<String>
    let session: RecordingFoundationModelsSession
    private var recordedInstructions: [String] = []
    private var createdSessionCount = 0

    init(
        availability: Availability,
        supportedLocales: Set<String>,
        session: RecordingFoundationModelsSession
    ) {
        configuredAvailability = availability
        self.supportedLocales = supportedLocales
        self.session = session
    }

    func availability() async -> Availability {
        configuredAvailability
    }

    func supportsLocale(identifier: String) async -> Bool {
        supportedLocales.contains(identifier)
    }

    func makeSession(instructions: String) async -> any FoundationModelsSession {
        createdSessionCount += 1
        recordedInstructions.append(instructions)
        return session
    }

    func sessionCount() -> Int {
        createdSessionCount
    }

    func instructions() -> String {
        recordedInstructions.joined(separator: "\n")
    }
}
