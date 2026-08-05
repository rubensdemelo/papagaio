import Foundation
import Observation

typealias AudioStream = AsyncThrowingStream<AudioChunk, any Error>
typealias FinalizedSpeechStream = AsyncThrowingStream<FinalizedSpeechSegment, any Error>

struct MeetingContextBatch: Sendable, Equatable {
    let segments: [FinalizedSpeechSegment]
}

protocol AudioCapture: Sendable {
    func start() async throws(PipelineFailure) -> AudioStream
    func stop() async
    func cancel() async
}

protocol TemporarySpeechRecognizer: Sendable {
    func recognize(audio: AudioStream) async throws(PipelineFailure) -> FinalizedSpeechStream
    func stop() async
    func cancel() async
}

protocol RollingMeetingContext: Sendable {
    func append(_ segment: FinalizedSpeechSegment) async throws(PipelineFailure)
    func nextBatch() async throws(PipelineFailure) -> MeetingContextBatch?
    func clear() async
    func cancel() async
}

protocol InsightGenerator: Sendable {
    func generate(from batch: MeetingContextBatch) async throws(PipelineFailure) -> [InsightUpdate]
    func cancel() async
}

@MainActor
protocol InsightState: AnyObject {
    var cards: [InsightCard] { get }
    func apply(
        _ updates: [InsightUpdate],
        supportedBy sourceContext: MeetingContextBatch
    ) throws(PipelineFailure)
    func reset()
}

struct InsightStoreConfiguration: Sendable, Equatable {
    let maximumActiveCardCount: Int
    let maximumUpdateCount: Int
    let maximumStableKeyLength: Int
    let maximumTextLength: Int
    let maximumOwnerLength: Int

    init(
        maximumActiveCardCount: Int = 20,
        maximumUpdateCount: Int = 8,
        maximumStableKeyLength: Int = 128,
        maximumTextLength: Int = 500,
        maximumOwnerLength: Int = 120
    ) {
        precondition(maximumActiveCardCount >= 0)
        precondition(maximumUpdateCount >= 0)
        precondition(maximumStableKeyLength > 0)
        precondition(maximumTextLength > 0)
        precondition(maximumOwnerLength > 0)

        self.maximumActiveCardCount = maximumActiveCardCount
        self.maximumUpdateCount = maximumUpdateCount
        self.maximumStableKeyLength = maximumStableKeyLength
        self.maximumTextLength = maximumTextLength
        self.maximumOwnerLength = maximumOwnerLength
    }
}

@Observable
@MainActor
final class InMemoryInsightStore: InsightState {
    private(set) var cards: [InsightCard] = []

    private let configuration: InsightStoreConfiguration

    init(configuration: InsightStoreConfiguration = InsightStoreConfiguration()) {
        self.configuration = configuration
    }

    func apply(
        _ updates: [InsightUpdate],
        supportedBy sourceContext: MeetingContextBatch
    ) throws(PipelineFailure) {
        let validatedUpdates = try validate(updates, supportedBy: sourceContext)
        var nextCards = cards

        for update in validatedUpdates {
            apply(update, to: &nextCards)
        }

        cards = nextCards
    }

    func reset() {
        cards.removeAll(keepingCapacity: false)
    }

    private func validate(
        _ updates: [InsightUpdate],
        supportedBy sourceContext: MeetingContextBatch
    ) throws(PipelineFailure) -> [InsightUpdate] {
        guard updates.count <= configuration.maximumUpdateCount else {
            throw invalidGeneratedOutput
        }

        let sourceText = sourceContext.segments.map(\.text).joined(separator: "\n")
        var stableKeys = Set<String>()
        var validatedUpdates: [InsightUpdate] = []
        validatedUpdates.reserveCapacity(updates.count)

        for update in updates {
            let stableKey = normalizedStableKey(update.stableKey)
            let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !stableKey.isEmpty,
                  stableKey.count <= configuration.maximumStableKeyLength,
                  !containsControlCharacter(stableKey),
                  stableKeys.insert(stableKey).inserted,
                  !text.isEmpty,
                  text.count <= configuration.maximumTextLength,
                  !containsControlCharacter(text) else {
                throw invalidGeneratedOutput
            }

            validate(update.operation)
            validate(update.category)

            let owner = validatedOwner(
                update.explicitOwner,
                category: update.category,
                sourceText: sourceText
            )
            validatedUpdates.append(
                InsightUpdate(
                    stableKey: stableKey,
                    operation: update.operation,
                    category: update.category,
                    text: text,
                    explicitOwner: owner
                )
            )
        }

        return validatedUpdates
    }

    private func apply(_ update: InsightUpdate, to cards: inout [InsightCard]) {
        let existingIndex = cards.firstIndex { $0.stableKey == update.stableKey }

        switch update.operation {
        case .add:
            if let existingIndex {
                guard canActivateCard(at: existingIndex, in: cards) else {
                    return
                }
                cards[existingIndex] = card(from: update, state: .updated)
            } else {
                guard activeCardCount(in: cards) < configuration.maximumActiveCardCount else {
                    return
                }
                removeOldestResolvedCardIfNeeded(from: &cards)
                cards.append(card(from: update, state: .new))
            }
        case .update:
            guard let existingIndex,
                  canActivateCard(at: existingIndex, in: cards) else {
                return
            }
            cards[existingIndex] = card(from: update, state: .updated)
        case .resolve:
            guard let existingIndex else {
                return
            }
            cards[existingIndex] = card(from: update, state: .resolved)
        }
    }

    private func card(from update: InsightUpdate, state: InsightCardState) -> InsightCard {
        InsightCard(
            stableKey: update.stableKey,
            category: update.category,
            text: update.text,
            explicitOwner: update.explicitOwner,
            state: state
        )
    }

    private func canActivateCard(at index: Int, in cards: [InsightCard]) -> Bool {
        cards[index].state != .resolved
            || activeCardCount(in: cards) < configuration.maximumActiveCardCount
    }

    private func activeCardCount(in cards: [InsightCard]) -> Int {
        cards.lazy.filter { $0.state != .resolved }.count
    }

    private func removeOldestResolvedCardIfNeeded(from cards: inout [InsightCard]) {
        guard cards.count >= configuration.maximumActiveCardCount,
              let oldestResolvedIndex = cards.firstIndex(where: { $0.state == .resolved }) else {
            return
        }
        cards.remove(at: oldestResolvedIndex)
    }

    private func normalizedStableKey(_ stableKey: String) -> String {
        stableKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func validatedOwner(
        _ owner: String?,
        category: InsightCategory,
        sourceText: String
    ) -> String? {
        guard category == .action,
              let owner else {
            return nil
        }

        let candidate = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= configuration.maximumOwnerLength,
              !containsControlCharacter(candidate),
              sourceExplicitlyNames(candidate, in: sourceText) else {
            return nil
        }

        return candidate
    }

    private func sourceExplicitlyNames(_ owner: String, in sourceText: String) -> Bool {
        var searchRange = sourceText.startIndex..<sourceText.endIndex

        while let match = sourceText.range(
            of: owner,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            let startsAtBoundary = match.lowerBound == sourceText.startIndex
                || !isLetterOrNumber(sourceText[sourceText.index(before: match.lowerBound)])
            let endsAtBoundary = match.upperBound == sourceText.endIndex
                || !isLetterOrNumber(sourceText[match.upperBound])

            if startsAtBoundary && endsAtBoundary {
                return true
            }
            searchRange = match.upperBound..<sourceText.endIndex
        }

        return false
    }

    private func isLetterOrNumber(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func validate(_ operation: InsightOperation) {
        switch operation {
        case .add, .update, .resolve:
            break
        }
    }

    private func validate(_ category: InsightCategory) {
        switch category {
        case .important, .decision, .action, .question, .risk:
            break
        }
    }

    private var invalidGeneratedOutput: PipelineFailure {
        .stage(.insightState, .invalidState)
    }
}

@MainActor
protocol SessionLifecycle: AnyObject {
    var status: SessionStatus { get }
    func checkAvailability() async -> Availability
    func start() async throws(PipelineFailure)
    func stop() async
    func cancel() async
}
