import XCTest

@MainActor
final class ApplicationShellTests: XCTestCase {
    func testLiveCompositionUsesFixedEnglishUSLocale() {
        XCTAssertEqual(PapagaioCompositionRoot.defaultLocaleIdentifier, "en-US")
    }

    func testPrimaryActionStartsAndStopsExactlyOnce() async {
        let card = InsightCard(
            stableKey: "synthetic-card",
            category: .important,
            text: "Synthetic insight",
            explicitOwner: nil,
            state: .new
        )
        let controller = FakeSessionController(cards: [card])

        await controller.performPrimaryAction()

        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.stopCount, 0)
        XCTAssertEqual(controller.status, .listening)
        XCTAssertEqual(controller.primaryActionTitle, "Stop Listening")

        await controller.performPrimaryAction()

        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.stopCount, 1)
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertTrue(controller.cards.isEmpty)
        XCTAssertEqual(controller.primaryActionTitle, "Start Listening")
    }

    func testInjectedCardsExposeNewUpdatedAndResolvedStates() {
        let cards = [
            InsightCard(
                stableKey: "synthetic-new",
                category: .important,
                text: "New synthetic insight",
                explicitOwner: nil,
                state: .new
            ),
            InsightCard(
                stableKey: "synthetic-updated",
                category: .decision,
                text: "Updated synthetic insight",
                explicitOwner: nil,
                state: .updated
            ),
            InsightCard(
                stableKey: "synthetic-resolved",
                category: .question,
                text: "Resolved synthetic insight",
                explicitOwner: nil,
                state: .resolved
            ),
        ]
        let controller = FakeSessionController()

        controller.inject(status: .listening, cards: cards)

        XCTAssertEqual(controller.cards, cards)
        XCTAssertEqual(controller.cards.map(\.state), [.new, .updated, .resolved])
        XCTAssertEqual(controller.status, .listening)
    }

    func testUnavailableOutcomeNeverClaimsToBeListening() async {
        let reason = UnavailableReason.appleIntelligenceDisabled
        let controller = FakeSessionController(startOutcome: .unavailable(reason))

        await controller.performPrimaryAction()

        XCTAssertEqual(controller.status, .unavailable)
        XCTAssertEqual(controller.unavailableReason, reason)
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.primaryActionTitle, "Start Listening")
    }

    func testInterruptedFailureUpdatesStatusAccurately() async {
        let failure = PipelineFailure.stage(.audioCapture, .interrupted)
        let controller = FakeSessionController(startOutcome: .failure(failure))

        await controller.performPrimaryAction()

        XCTAssertEqual(controller.status, .interrupted)
        XCTAssertEqual(controller.failure, failure)
        XCTAssertNotEqual(controller.status, .listening)
    }

    func testGenericPipelineFailureUpdatesToUnavailable() async {
        let failure = PipelineFailure.stage(.sessionLifecycle, .failed)
        let controller = FakeSessionController(startOutcome: .failure(failure))

        await controller.performPrimaryAction()

        XCTAssertEqual(controller.status, .unavailable)
        XCTAssertEqual(controller.failure, failure)
        XCTAssertNotEqual(controller.status, .listening)
    }

    func testStatusAndEmptyPresentationsAreDeterministic() {
        MainActor.assertIsolated()

        let stopped = SessionStatusPresentation(status: .stopped)
        let interrupted = SessionStatusPresentation(status: .interrupted)
        let unavailable = SessionStatusPresentation(
            status: .unavailable,
            unavailableReason: .languageModelNotReady
        )

        XCTAssertEqual(stopped.title, "Stopped")
        XCTAssertEqual(interrupted.title, "Interrupted")
        XCTAssertEqual(unavailable.title, "Unavailable")
        XCTAssertEqual(
            EmptyStatePresentation(status: .stopped, statusDetail: stopped.detail).title,
            "Ready to listen"
        )
        XCTAssertEqual(
            EmptyStatePresentation(status: .interrupted, statusDetail: interrupted.detail).title,
            "Listening was interrupted"
        )
        XCTAssertEqual(
            EmptyStatePresentation(status: .unavailable, statusDetail: unavailable.detail).detail,
            "Keep Apple Intelligence enabled and this Mac online while the model finishes preparing."
        )
    }

    func testPrerequisitePresentationExplainsLanguageAndOrganizationBlockers() {
        let presentation = PrerequisiteCheckPresentation(
            check: PrerequisiteCheck(
                kind: .appleIntelligence,
                reason: .appleIntelligenceDisabled
            )
        )

        XCTAssertEqual(presentation.title, "Apple Intelligence")
        XCTAssertTrue(presentation.detail.contains("System Settings"))
        XCTAssertTrue(presentation.detail.contains("same language"))
        XCTAssertTrue(presentation.detail.contains("organization"))
        XCTAssertEqual(presentation.symbolName, "exclamationmark.circle.fill")
    }
}
