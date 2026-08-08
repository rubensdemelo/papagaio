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
    var readiness: SessionReadiness? { get }
    var unavailableReason: UnavailableReason? { get }
    var failure: PipelineFailure? { get }
    var isPerformingPrimaryAction: Bool { get }
    var primaryActionTitle: String { get }

    func checkReadiness() async
    func performPrimaryAction() async
}

@MainActor
final class FakeSessionController: SessionShellControlling {
    @Published private(set) var status: SessionStatus
    @Published private(set) var cards: [InsightCard]
    @Published private(set) var readiness: SessionReadiness?
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
        readiness: SessionReadiness? = nil,
        unavailableReason: UnavailableReason? = nil,
        failure: PipelineFailure? = nil,
        startOutcome: FakeSessionStartOutcome = .listening,
        transitionDelay: Duration = .zero
    ) {
        self.status = status
        self.cards = cards
        self.readiness = readiness
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

    func checkReadiness() async {
        // The fake controller receives readiness through its initializer or inject().
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
        readiness: SessionReadiness? = nil,
        unavailableReason: UnavailableReason? = nil,
        failure: PipelineFailure? = nil
    ) {
        self.status = status
        self.cards = cards
        self.readiness = readiness
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
    @StateObject private var noticePresenter: AppleIntelligenceDisabledNoticePresenter

    init(
        controller: Controller,
        noticeDefaults: UserDefaults = .standard
    ) {
        self.controller = controller
        _noticePresenter = StateObject(
            wrappedValue: AppleIntelligenceDisabledNoticePresenter(
                defaults: noticeDefaults
            )
        )
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
        .task {
            await controller.checkReadiness()
            noticePresenter.update(for: controller.readiness)
        }
        .onChange(of: controller.readiness) { _, readiness in
            noticePresenter.update(for: readiness)
        }
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
            VStack(spacing: 18) {
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

                if let readiness = controller.readiness, !readiness.isReady {
                    PrerequisiteChecklistView(report: readiness)
                        .padding(.horizontal, 24)

                    if noticePresenter.isVisible {
                        AppleIntelligenceDisabledNoticeView()
                            .padding(.horizontal, 24)
                    }
                }
            }
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

struct AppleIntelligenceDisabledNoticePresentation: Equatable {
    static let title = "Apple Intelligence is turned off"
    static let detail = "Turning it on downloads on-device models and requires several gigabytes of free disk space. Open System Settings → Apple Intelligence & Siri to enable it."
}

@MainActor
final class AppleIntelligenceDisabledNoticePresenter: ObservableObject {
    static let defaultsKey = "papagaio.appleIntelligenceDisabledNoticePresented"

    @Published private(set) var isVisible = false

    private let defaults: UserDefaults
    private var hasPresented: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasPresented = defaults.bool(
            forKey: Self.defaultsKey
        )
    }

    func update(for readiness: SessionReadiness?) {
        guard !hasPresented,
              readiness?.checks.contains(where: { check in
                  check.kind == .appleIntelligence
                      && check.reason == .appleIntelligenceDisabled
              }) == true else {
            return
        }

        hasPresented = true
        defaults.set(true, forKey: Self.defaultsKey)
        isVisible = true
    }
}

private struct AppleIntelligenceDisabledNoticeView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "internaldrive.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppleIntelligenceDisabledNoticePresentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(AppleIntelligenceDisabledNoticePresentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(AppleIntelligenceDisabledNoticePresentation.title). \(AppleIntelligenceDisabledNoticePresentation.detail)"
        )
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

private struct PrerequisiteChecklistView: View {
    let report: SessionReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before listening")
                .font(.headline)

            ForEach(report.checks) { check in
                let presentation = PrerequisiteCheckPresentation(check: check)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: presentation.symbolName)
                        .foregroundStyle(presentation.tint)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .font(.subheadline.weight(.semibold))
                        Text(presentation.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Listening prerequisites")
    }
}

struct PrerequisiteCheckPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let tintName: SessionStatusPresentation.TintName

    init(check: PrerequisiteCheck) {
        title = check.kind.title
        if let reason = check.reason {
            detail = reason.guidanceMessage
            symbolName = "exclamationmark.circle.fill"
            tintName = .unavailable
        } else {
            detail = "Ready."
            symbolName = "checkmark.circle.fill"
            tintName = .active
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
            detail = unavailableReason?.guidanceMessage ?? failure?.guidanceMessage
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

private extension PrerequisiteKind {
    var title: String {
        switch self {
        case .microphone:
            "Microphone access"
        case .speechRecognition:
            "Speech recognition"
        case .appleIntelligence:
            "Apple Intelligence"
        }
    }
}

private extension UnavailableReason {
    var guidanceMessage: String {
        switch self {
        case .microphonePermissionUndetermined:
            "Click Start Listening and allow microphone access when macOS asks."
        case .microphonePermissionDenied:
            "Open System Settings → Privacy & Security → Microphone and enable Papagaio."
        case .audioInputUnavailable:
            "Connect or enable a microphone, then try again."
        case .speechRecognitionUnavailable:
            "This Mac cannot use on-device speech recognition. Use a supported macOS 26+ Mac."
        case .speechLocaleUnsupported(let identifier):
            "Speech recognition does not support \(identifier). Papagaio currently requires English (US)."
        case .speechAssetsNotReady:
            "Keep this Mac online. Papagaio will download the required speech assets, then try again."
        case .languageModelDeviceNotEligible:
            "This Mac does not support Apple Intelligence. Use a compatible Mac."
        case .appleIntelligenceDisabled:
            "Open System Settings → Apple Intelligence & Siri. Set macOS and Siri to the same language (Papagaio requires English (US)) and turn on Apple Intelligence. If macOS says your organization restricts access, contact your IT administrator."
        case .languageModelNotReady:
            "Keep Apple Intelligence enabled and this Mac online while the model finishes preparing."
        case .languageModelLocaleUnsupported(let identifier):
            "The on-device language model does not support \(identifier). Papagaio currently requires English (US)."
        }
    }
}

private extension PipelineFailure {
    var guidanceMessage: String {
        switch self {
        case .unavailable(let reason):
            reason.guidanceMessage
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
