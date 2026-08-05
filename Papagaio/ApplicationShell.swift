import Combine
import SwiftUI

enum FakeSessionStartOutcome: Sendable, Equatable {
    case listening
    case unavailable(UnavailableReason)
    case interrupted
    case failure(PipelineFailure)
}

@MainActor
protocol SessionShellControlling: ObservableObject {
    var status: SessionStatus { get }
    var cards: [InsightCard] { get }
    var unavailableReason: UnavailableReason? { get }
    var failure: PipelineFailure? { get }
    var isPerformingPrimaryAction: Bool { get }
    var primaryActionTitle: String { get }

    func performPrimaryAction() async
}

@MainActor
final class FakeSessionController: SessionShellControlling {
    @Published private(set) var status: SessionStatus
    @Published private(set) var cards: [InsightCard]
    @Published private(set) var unavailableReason: UnavailableReason?
    @Published private(set) var failure: PipelineFailure?
    @Published private(set) var isPerformingPrimaryAction = false

    private let startOutcome: FakeSessionStartOutcome
    private let transitionDelay: Duration

    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        status: SessionStatus = .stopped,
        cards: [InsightCard] = [],
        unavailableReason: UnavailableReason? = nil,
        failure: PipelineFailure? = nil,
        startOutcome: FakeSessionStartOutcome = .listening,
        transitionDelay: Duration = .zero
    ) {
        self.status = status
        self.cards = cards
        self.unavailableReason = unavailableReason
        self.failure = failure
        self.startOutcome = startOutcome
        self.transitionDelay = transitionDelay
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

    func performPrimaryAction() async {
        guard !isPerformingPrimaryAction else { return }

        switch status {
        case .listening, .processing:
            await stop()
        case .stopped, .interrupted, .unavailable:
            await start()
        case .checkingAvailability:
            break
        }
    }

    func inject(
        status: SessionStatus,
        cards: [InsightCard] = [],
        unavailableReason: UnavailableReason? = nil,
        failure: PipelineFailure? = nil
    ) {
        self.status = status
        self.cards = cards
        self.unavailableReason = unavailableReason
        self.failure = failure
    }

    private func start() async {
        startCount += 1
        isPerformingPrimaryAction = true
        status = .checkingAvailability
        unavailableReason = nil
        failure = nil

        if transitionDelay > .zero {
            do {
                try await Task.sleep(for: transitionDelay)
            } catch {
                status = .stopped
                isPerformingPrimaryAction = false
                return
            }
        }

        switch startOutcome {
        case .listening:
            status = .listening
        case .unavailable(let reason):
            unavailableReason = reason
            status = .unavailable
        case .interrupted:
            failure = .stage(.sessionLifecycle, .interrupted)
            status = .interrupted
        case .failure(let startFailure):
            apply(startFailure)
        }

        isPerformingPrimaryAction = false
    }

    private func stop() async {
        stopCount += 1
        isPerformingPrimaryAction = true
        cards.removeAll()
        unavailableReason = nil
        failure = nil
        status = .stopped
        isPerformingPrimaryAction = false
    }

    private func apply(_ startFailure: PipelineFailure) {
        failure = startFailure

        switch startFailure {
        case .unavailable(let reason):
            unavailableReason = reason
            status = .unavailable
        case .stage(_, .interrupted):
            status = .interrupted
        case .stage, .cancelled:
            status = .unavailable
        }
    }
}

struct PapagaioView<Controller: SessionShellControlling>: View {
    @ObservedObject private var controller: Controller

    init(controller: Controller) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionStatus
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            primaryAction
                .padding(24)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 460, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Papagaio")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Live meeting insights")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var sessionStatus: some View {
        let presentation = SessionStatusPresentation(
            status: controller.status,
            unavailableReason: controller.unavailableReason,
            failure: controller.failure
        )

        return HStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session status")
        .accessibilityValue("\(presentation.title). \(presentation.detail)")
    }

    @ViewBuilder
    private var content: some View {
        if controller.cards.isEmpty {
            SessionEmptyView(
                presentation: EmptyStatePresentation(
                    status: controller.status,
                    statusDetail: SessionStatusPresentation(
                        status: controller.status,
                        unavailableReason: controller.unavailableReason,
                        failure: controller.failure
                    ).detail
                )
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(controller.cards, id: \.stableKey) { card in
                        InsightCardView(card: card)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .accessibilityLabel("Meeting insights")
        }
    }

    private var primaryAction: some View {
        Button {
            Task {
                await controller.performPrimaryAction()
            }
        } label: {
            Label(controller.primaryActionTitle, systemImage: primaryActionSymbol)
                .frame(minWidth: 170)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("l", modifiers: [.command])
        .disabled(controller.isPerformingPrimaryAction)
        .accessibilityLabel(controller.primaryActionTitle)
        .accessibilityHint(primaryActionHint)
        .help("\(controller.primaryActionTitle) (⌘L)")
    }

    private var primaryActionSymbol: String {
        switch controller.status {
        case .listening, .processing:
            "stop.fill"
        case .checkingAvailability:
            "hourglass"
        case .stopped, .interrupted, .unavailable:
            "waveform"
        }
    }

    private var primaryActionHint: String {
        switch controller.status {
        case .listening, .processing:
            "Stops the current session and clears its insights. Keyboard shortcut Command-L."
        case .checkingAvailability:
            "Papagaio is checking whether listening can begin."
        case .stopped, .interrupted, .unavailable:
            "Starts a new listening session. Keyboard shortcut Command-L."
        }
    }
}

private struct SessionEmptyView: View {
    let presentation: EmptyStatePresentation

    var body: some View {
        ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.symbolName)
        } description: {
            Text(presentation.detail)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InsightCardView: View {
    let card: InsightCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(card.category.displayName, systemImage: card.category.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(card.category.tint)

                Spacer()

                Text(card.state.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(card.text)
                .font(.body)
                .foregroundStyle(card.state == .resolved ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            if let owner = card.explicitOwner, !owner.isEmpty {
                Text("Owner: \(owner)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(card.category.tint.opacity(0.22), lineWidth: 1)
        }
        .opacity(card.state == .resolved ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityDescription)
    }
}

struct SessionStatusPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let tintName: TintName

    enum TintName: Equatable {
        case neutral
        case active
        case warning
        case unavailable
    }

    init(
        status: SessionStatus,
        unavailableReason: UnavailableReason? = nil,
        failure: PipelineFailure? = nil
    ) {
        switch status {
        case .stopped:
            title = "Stopped"
            detail = "Nothing from a meeting is being retained."
            symbolName = "stop.circle"
            tintName = .neutral
        case .checkingAvailability:
            title = "Checking availability"
            detail = "Confirming this Mac is ready."
            symbolName = "ellipsis.circle"
            tintName = .neutral
        case .listening:
            title = "Listening"
            detail = "Insights appear as the meeting develops."
            symbolName = "waveform.circle.fill"
            tintName = .active
        case .processing:
            title = "Processing"
            detail = "Refreshing live insights."
            symbolName = "sparkles"
            tintName = .active
        case .interrupted:
            title = "Interrupted"
            detail = "Listening stopped unexpectedly. Start again when ready."
            symbolName = "exclamationmark.circle"
            tintName = .warning
        case .unavailable:
            title = "Unavailable"
            detail = unavailableReason?.displayMessage ?? failure?.displayMessage
                ?? "Papagaio could not start listening."
            symbolName = "xmark.circle"
            tintName = .unavailable
        }
    }

    var tint: Color {
        switch tintName {
        case .neutral:
            .secondary
        case .active:
            .accentColor
        case .warning:
            .orange
        case .unavailable:
            .red
        }
    }
}

struct EmptyStatePresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String

    init(status: SessionStatus, statusDetail: String) {
        switch status {
        case .stopped:
            title = "Ready to listen"
            detail = "Start listening to see live insights here."
            symbolName = "waveform"
        case .checkingAvailability:
            title = "Getting ready"
            detail = "This should only take a moment."
            symbolName = "hourglass"
        case .listening:
            title = "Listening for useful moments"
            detail = "Important points, decisions, actions, questions, and risks will appear here."
            symbolName = "ear"
        case .processing:
            title = "Insights are on the way"
            detail = "Papagaio is processing the latest meeting context."
            symbolName = "sparkles"
        case .interrupted:
            title = "Listening was interrupted"
            detail = "Start listening to try again."
            symbolName = "exclamationmark.circle"
        case .unavailable:
            title = "Papagaio is unavailable"
            detail = statusDetail
            symbolName = "xmark.circle"
        }
    }
}

private extension UnavailableReason {
    var displayMessage: String {
        switch self {
        case .microphonePermissionUndetermined:
            "Microphone permission has not been requested yet."
        case .microphonePermissionDenied:
            "Microphone access is required to listen."
        case .audioInputUnavailable:
            "No audio input is available."
        case .speechRecognitionUnavailable:
            "On-device speech recognition is unavailable."
        case .speechLocaleUnsupported(let identifier):
            "Speech recognition does not support \(identifier)."
        case .speechAssetsNotReady:
            "Required speech assets are not ready."
        case .languageModelDeviceNotEligible:
            "This Mac does not support the on-device language model."
        case .appleIntelligenceDisabled:
            "Apple Intelligence is turned off."
        case .languageModelNotReady:
            "The on-device language model is not ready."
        case .languageModelLocaleUnsupported(let identifier):
            "The on-device language model does not support \(identifier)."
        }
    }
}

private extension PipelineFailure {
    var displayMessage: String {
        switch self {
        case .unavailable(let reason):
            reason.displayMessage
        case .stage(_, .interrupted):
            "Listening was interrupted."
        case .stage(_, .overloaded):
            "Papagaio could not keep up with the audio stream."
        case .stage, .cancelled:
            "Papagaio could not start listening."
        }
    }
}

private extension InsightCategory {
    var displayName: String {
        switch self {
        case .important: "Important"
        case .decision: "Decision"
        case .action: "Action"
        case .question: "Question"
        case .risk: "Risk"
        }
    }

    var symbolName: String {
        switch self {
        case .important: "star.fill"
        case .decision: "checkmark.circle.fill"
        case .action: "arrow.right.circle.fill"
        case .question: "questionmark.circle.fill"
        case .risk: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .important: .indigo
        case .decision: .green
        case .action: .blue
        case .question: .purple
        case .risk: .orange
        }
    }
}

private extension InsightCardState {
    var displayName: String {
        switch self {
        case .new: "New"
        case .updated: "Updated"
        case .resolved: "Resolved"
        }
    }
}

private extension InsightCard {
    var accessibilityDescription: String {
        var components = [category.displayName, state.displayName, text]
        if let explicitOwner, !explicitOwner.isEmpty {
            components.append("Owner: \(explicitOwner)")
        }
        return components.joined(separator: ", ")
    }
}

#Preview("Stopped") {
    PapagaioView(controller: FakeSessionController())
}

#Preview("Listening — empty") {
    PapagaioView(controller: FakeSessionController(status: .listening))
}

#Preview("Insight cards") {
    PapagaioView(
        controller: FakeSessionController(
            status: .listening,
            cards: [
                InsightCard(
                    stableKey: "preview-important",
                    category: .important,
                    text: "A concise important point appears here.",
                    explicitOwner: nil,
                    state: .new
                ),
                InsightCard(
                    stableKey: "preview-decision",
                    category: .decision,
                    text: "A changed decision is presented as an update.",
                    explicitOwner: nil,
                    state: .updated
                ),
                InsightCard(
                    stableKey: "preview-question",
                    category: .question,
                    text: "A resolved question remains easy to identify.",
                    explicitOwner: nil,
                    state: .resolved
                ),
            ]
        )
    )
}

#Preview("Unavailable") {
    PapagaioView(
        controller: FakeSessionController(
            status: .unavailable,
            unavailableReason: .appleIntelligenceDisabled,
            startOutcome: .unavailable(.appleIntelligenceDisabled)
        )
    )
}

#Preview("Interrupted") {
    PapagaioView(
        controller: FakeSessionController(
            status: .interrupted,
            failure: .stage(.audioCapture, .interrupted),
            startOutcome: .interrupted
        )
    )
}
