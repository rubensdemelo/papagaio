import XCTest

@MainActor
final class ApplicationShellTests: XCTestCase {
    func testLiveCompositionUsesFixedEnglishUSLocale() {
        XCTAssertEqual(RioCompositionRoot.defaultLocaleIdentifier, "en-US")
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

    func testAppleIntelligenceDisabledNoticeIsShownOnceAndOnlyForDisabledState() {
        let suiteName = "RioTests.Notice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let disabledReadiness = SessionReadiness(
            checks: [
                PrerequisiteCheck(
                    kind: .appleIntelligence,
                    reason: .appleIntelligenceDisabled
                )
            ]
        )
        let notReadyReadiness = SessionReadiness(
            checks: [
                PrerequisiteCheck(
                    kind: .appleIntelligence,
                    reason: .languageModelNotReady
                )
            ]
        )

        let presenter = AppleIntelligenceDisabledNoticePresenter(defaults: defaults)
        presenter.update(for: notReadyReadiness)
        XCTAssertFalse(presenter.isVisible)

        presenter.update(for: disabledReadiness)
        XCTAssertTrue(presenter.isVisible)

        let secondPresenter = AppleIntelligenceDisabledNoticePresenter(defaults: defaults)
        secondPresenter.update(for: disabledReadiness)
        XCTAssertFalse(secondPresenter.isVisible)
    }

    func testAppleIntelligenceDisabledNoticeExplainsModelDownloadAndStorageWithoutExactSize() {
        let detail = AppleIntelligenceDisabledNoticePresentation.detail

        XCTAssertTrue(detail.contains("on-device models"))
        XCTAssertTrue(detail.contains("several gigabytes"))
        XCTAssertTrue(detail.contains("free disk space"))
        XCTAssertFalse(detail.range(of: #"\b\d+(?:\.\d+)?\s*(?:GB|TB|gigabytes?)\b"#, options: .regularExpression) != nil)
    }

    func testVoiceFeedbackUsesNonContentSpeechActivityInsteadOfTranscript() {
        let presentation = VoiceFeedbackPresentation(
            status: .listening,
            feedback: SessionFeedbackSnapshot(
                audioInput: AudioInputSnapshot(
                    level: 0.65,
                    hasReceivedAudio: true,
                    isMuted: false
                ),
                finalizedSpeechSegmentCount: 3
            )
        )

        XCTAssertEqual(presentation.condition, .live)
        XCTAssertEqual(presentation.title, "Audio input live")
        XCTAssertTrue(presentation.detail.contains("3 finalized segments"))
        XCTAssertFalse(presentation.detail.contains("transcript"))
    }

    func testVoiceFeedbackDistinguishesMutedAndConnectionErrorStates() {
        let muted = VoiceFeedbackPresentation(
            status: .listening,
            feedback: SessionFeedbackSnapshot(
                audioInput: AudioInputSnapshot(
                    level: 0,
                    hasReceivedAudio: true,
                    isMuted: true
                ),
                finalizedSpeechSegmentCount: 0
            )
        )
        let connectionError = VoiceFeedbackPresentation(
            status: .unavailable,
            feedback: .inactive,
            failure: .stage(.audioCapture, .failed)
        )

        XCTAssertEqual(muted.condition, .muted)
        XCTAssertEqual(connectionError.condition, .connectionError)
        XCTAssertNotEqual(muted.condition, connectionError.condition)
    }

    func testFakeControllerPausesAndResumesWithoutClearingInsights() async {
        let card = InsightCard(
            stableKey: "pause-card",
            category: .decision,
            text: "A decision",
            explicitOwner: nil,
            state: .new
        )
        let controller = FakeSessionController(cards: [card])

        await controller.performPrimaryAction()
        await controller.performPauseAction()

        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(controller.cards, [card])
        XCTAssertEqual(controller.pauseActionTitle, "Resume Listening")

        await controller.performPauseAction()
        XCTAssertEqual(controller.status, .listening)
        XCTAssertEqual(controller.cards, [card])
    }

}
