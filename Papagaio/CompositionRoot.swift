import Combine
import Foundation
import Observation

@MainActor
final class LiveSessionController: SessionShellControlling {
    @Published private(set) var status: SessionStatus = .stopped
    @Published private(set) var cards: [InsightCard] = []
    @Published private(set) var readiness: SessionReadiness?
    @Published private(set) var unavailableReason: UnavailableReason?
    @Published private(set) var failure: PipelineFailure?
    @Published private(set) var isPerformingPrimaryAction = false

    let lifecycle: SessionLifecycleCoordinator
    let insightStore: InMemoryInsightStore

    private var monitoringTask: Task<Void, Never>?

    init(
        lifecycle: SessionLifecycleCoordinator,
        insightStore: InMemoryInsightStore
    ) {
        self.lifecycle = lifecycle
        self.insightStore = insightStore
        observeInsightStore()
        refreshSnapshot()
    }

    var primaryActionTitle: String {
        switch status {
        case .listening, .processing:
            "Stop Listening"
        case .checkingAvailability:
            "Checking…"
        case .stopped, .interrupted, .unavailable:
            "Start Listening"
        }
    }

    func checkReadiness() async {
        _ = await lifecycle.checkReadiness()
        refreshSnapshot()
    }

    func performPrimaryAction() async {
        guard !isPerformingPrimaryAction else {
            return
        }

        isPerformingPrimaryAction = true
        defer { isPerformingPrimaryAction = false }

        switch lifecycle.status {
        case .listening, .processing:
            await lifecycle.stop()
            stopMonitoring()
        case .stopped, .interrupted, .unavailable:
            failure = nil
            unavailableReason = nil
            do {
                try await lifecycle.start()
                startMonitoring()
            } catch let startFailure {
                apply(startFailure)
                stopMonitoring()
            }
        case .checkingAvailability:
            break
        }

        refreshSnapshot()
    }

    private func startMonitoring() {
        stopMonitoring()
        monitoringTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.refreshSnapshot()
                switch self.lifecycle.status {
                case .stopped, .interrupted, .unavailable:
                    return
                case .checkingAvailability, .listening, .processing:
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func refreshSnapshot() {
        status = lifecycle.status
        readiness = lifecycle.readiness
        failure = lifecycle.failure
        if case let .unavailable(reason)? = failure {
            unavailableReason = reason
        }
        cards = insightStore.cards
    }

    private func observeInsightStore() {
        withObservationTracking {
            cards = insightStore.cards
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeInsightStore()
            }
        }
    }

    private func apply(_ startFailure: PipelineFailure) {
        failure = startFailure
        switch startFailure {
        case .unavailable(let reason):
            unavailableReason = reason
        case .stage, .cancelled:
            unavailableReason = nil
        }
        status = lifecycle.status
    }
}

@MainActor
enum PapagaioCompositionRoot {
    static let defaultLocaleIdentifier = "en-US"

    static func makeLiveController() -> LiveSessionController {
        let localeIdentifier = defaultLocaleIdentifier
        let capture = AVAudioEngineMicrophoneCapture()
        let speechRecognizer = SpeechAnalyzerTranscriberAdapter(
            localeIdentifier: localeIdentifier
        )
        let contextFactory = BoundedMeetingContextFactory(
            configuration: MeetingContextConfiguration(
                maximumAge: .seconds(180),
                maximumTokenCount: 2_000,
                maximumUTF8ByteCount: 20_000,
                batchTokenThreshold: 250,
                maximumBatchWait: .seconds(10)
            ),
            clock: ContinuousMeetingContextClock(),
            tokenEstimator: { text in
                max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
            }
        )
        let insightStore = InMemoryInsightStore()
        let insightGenerator = FoundationModelsInsightGenerator(
            runtime: AppleFoundationModelsRuntime()
        )
        let lifecycle = SessionLifecycleCoordinator(
            localeIdentifier: localeIdentifier,
            capture: capture,
            speechRecognizer: speechRecognizer,
            contextFactory: contextFactory,
            insightGenerator: insightGenerator,
            insightState: insightStore
        )
        return LiveSessionController(
            lifecycle: lifecycle,
            insightStore: insightStore
        )
    }
}
