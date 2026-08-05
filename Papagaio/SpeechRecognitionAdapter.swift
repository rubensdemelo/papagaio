@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

enum SpeechAssetState: Sendable, Equatable {
    case unsupported
    case supported
    case downloading
    case installed

    init(_ status: AssetInventory.Status) {
        switch status {
        case .unsupported:
            self = .unsupported
        case .supported:
            self = .supported
        case .downloading:
            self = .downloading
        case .installed:
            self = .installed
        @unknown default:
            self = .unsupported
        }
    }
}

struct SpeechRecognitionAvailability: Sendable, Equatable {
    let transcriberIsAvailable: Bool
    let requestedLocaleIdentifier: String
    let resolvedLocaleIdentifier: String?
    let installedLocale: Bool
    let assetState: SpeechAssetState

    var failure: PipelineFailure? {
        guard transcriberIsAvailable else {
            return .unavailable(.speechRecognitionUnavailable)
        }
        guard resolvedLocaleIdentifier != nil else {
            return .unavailable(
                .speechLocaleUnsupported(identifier: requestedLocaleIdentifier)
            )
        }
        guard installedLocale, assetState == .installed else {
            return .unavailable(.speechAssetsNotReady)
        }
        return nil
    }
}

protocol SpeechAvailabilityProviding: Sendable {
    func inspect(localeIdentifier: String) async -> SpeechRecognitionAvailability
}

struct SystemSpeechAvailabilityProvider: SpeechAvailabilityProviding, Sendable {
    func inspect(localeIdentifier: String) async -> SpeechRecognitionAvailability {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard SpeechTranscriber.isAvailable else {
            return SpeechRecognitionAvailability(
                transcriberIsAvailable: false,
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                installedLocale: false,
                assetState: .unsupported
            )
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            return SpeechRecognitionAvailability(
                transcriberIsAvailable: true,
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                installedLocale: false,
                assetState: .unsupported
            )
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .transcription
        )
        let installedLocales = await SpeechTranscriber.installedLocales
        let installedLocale = installedLocales.contains {
            $0.identifier.caseInsensitiveCompare(supportedLocale.identifier) == .orderedSame
        }
        let assetStatus = await AssetInventory.status(forModules: [transcriber])

        return SpeechRecognitionAvailability(
            transcriberIsAvailable: true,
            requestedLocaleIdentifier: localeIdentifier,
            resolvedLocaleIdentifier: supportedLocale.identifier,
            installedLocale: installedLocale,
            assetState: SpeechAssetState(assetStatus)
        )
    }
}

struct SpeechAudioInput: Sendable, Equatable {
    let chunk: AudioChunk
    let sourceFormat: MicrophoneAudioFormat
    let analysisFormat: MicrophoneAudioFormat
    let startOffset: Duration
}

typealias SpeechAudioInputStream = AsyncThrowingStream<SpeechAudioInput, any Error>

struct SpeechTranscriptionResult: Sendable, Equatable {
    let text: String
    let startOffset: Duration
    let endOffset: Duration
    let isFinal: Bool
}

typealias SpeechTranscriptionStream = AsyncThrowingStream<SpeechTranscriptionResult, any Error>

protocol SpeechRecognitionSession: Sendable {
    func bestAvailableAudioFormat(
        considering naturalFormat: MicrophoneAudioFormat
    ) async -> MicrophoneAudioFormat?
    func prepare(toAnalyze format: MicrophoneAudioFormat) async throws(PipelineFailure)
    func start(input: SpeechAudioInputStream) async throws(PipelineFailure)
    func results() -> SpeechTranscriptionStream
    func cancelAndFinishNow() async
}

protocol SpeechRecognitionSessionFactory: Sendable {
    func makeSession(localeIdentifier: String) -> any SpeechRecognitionSession
}

struct SystemSpeechRecognitionSessionFactory: SpeechRecognitionSessionFactory, Sendable {
    func makeSession(localeIdentifier: String) -> any SpeechRecognitionSession {
        SystemSpeechRecognitionSession(localeIdentifier: localeIdentifier)
    }
}

final class SystemSpeechRecognitionSession: SpeechRecognitionSession, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let resultStream: SpeechTranscriptionStream

    init(localeIdentifier: String) {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: localeIdentifier),
            preset: .transcription
        )
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
        resultStream = Self.makeResultStream(from: transcriber)
    }

    func bestAvailableAudioFormat(
        considering naturalFormat: MicrophoneAudioFormat
    ) async -> MicrophoneAudioFormat? {
        guard let naturalFormat = makeAVAudioFormat(naturalFormat) else {
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) else {
            return nil
        }
        return MicrophoneAudioFormat(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    func prepare(toAnalyze format: MicrophoneAudioFormat) async throws(PipelineFailure) {
        guard let audioFormat = makeAVAudioFormat(format) else {
            throw .stage(.speechRecognition, .invalidState)
        }

        do {
            try await analyzer.prepareToAnalyze(in: audioFormat)
        } catch {
            throw speechFailure(for: error)
        }
    }

    func start(input: SpeechAudioInputStream) async throws(PipelineFailure) {
        let analyzerInputStream = AsyncThrowingStream<AnalyzerInput, any Error>(
            bufferingPolicy: .bufferingOldest(1)
        ) {
            continuation in
            Task {
                do {
                    for try await audioInput in input {
                        let buffer = try makePCMBuffer(for: audioInput)
                        let input = AnalyzerInput(
                            buffer: buffer,
                            bufferStartTime: CMTime(
                                seconds: durationInSeconds(audioInput.startOffset),
                                preferredTimescale: 1_000_000
                            )
                        )
                        continuation.yield(input)
                    }
                    continuation.finish()
                } catch let failure as PipelineFailure {
                    continuation.finish(throwing: failure)
                } catch is CancellationError {
                    continuation.finish(throwing: PipelineFailure.cancelled)
                } catch {
                    continuation.finish(
                        throwing: PipelineFailure.stage(.speechRecognition, .failed)
                    )
                }
            }
        }

        do {
            try await analyzer.start(inputSequence: analyzerInputStream)
        } catch {
            throw speechFailure(for: error)
        }
    }

    func results() -> SpeechTranscriptionStream {
        resultStream
    }

    func cancelAndFinishNow() async {
        await analyzer.cancelAndFinishNow()
        await SpeechModels.endRetention()
    }

    private static func makeResultStream(
        from transcriber: SpeechTranscriber
    ) -> SpeechTranscriptionStream {
        AsyncThrowingStream<SpeechTranscriptionResult, any Error>(
            bufferingPolicy: .bufferingOldest(1)
        ) { continuation in
            Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        continuation.yield(
                            SpeechTranscriptionResult(
                                text: text,
                                startOffset: .seconds(result.range.start.seconds),
                                endOffset: .seconds(result.range.end.seconds),
                                isFinal: result.isFinal
                            )
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: PipelineFailure.cancelled)
                } catch {
                    continuation.finish(
                        throwing: PipelineFailure.stage(.speechRecognition, .failed)
                    )
                }
            }
        }
    }
}

actor SpeechAnalyzerTranscriberAdapter: SessionSpeechRecognizer {
    private let localeIdentifier: String
    private let availabilityProvider: any SpeechAvailabilityProviding
    private let sessionFactory: any SpeechRecognitionSessionFactory

    private var activeSession: (any SpeechRecognitionSession)?
    private var inputContinuation: SpeechAudioInputStream.Continuation?
    private var outputContinuation: FinalizedSpeechStream.Continuation?
    private var processingTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var teardownGate: SessionTeardownGate?
    private var isStarting = false

    init(
        localeIdentifier: String,
        availabilityProvider: any SpeechAvailabilityProviding = SystemSpeechAvailabilityProvider(),
        sessionFactory: any SpeechRecognitionSessionFactory = SystemSpeechRecognitionSessionFactory()
    ) {
        self.localeIdentifier = localeIdentifier
        self.availabilityProvider = availabilityProvider
        self.sessionFactory = sessionFactory
    }

    func availability() async -> SpeechRecognitionAvailability {
        await availabilityProvider.inspect(localeIdentifier: localeIdentifier)
    }

    func recognize(audio: AudioStream) async throws(PipelineFailure) -> FinalizedSpeechStream {
        guard activeSession == nil, !isStarting else {
            throw .stage(.speechRecognition, .invalidState)
        }
        isStarting = true
        defer { isStarting = false }

        let availability = await availabilityProvider.inspect(
            localeIdentifier: localeIdentifier
        )
        if let failure = availability.failure {
            throw failure
        }
        guard let resolvedLocaleIdentifier = availability.resolvedLocaleIdentifier else {
            throw .unavailable(
                .speechLocaleUnsupported(identifier: localeIdentifier)
            )
        }

        let session = sessionFactory.makeSession(
            localeIdentifier: resolvedLocaleIdentifier
        )
        let teardownGate = SessionTeardownGate()
        var inputContinuation: SpeechAudioInputStream.Continuation?
        let inputStream = SpeechAudioInputStream { continuation in
            inputContinuation = continuation
        }
        guard let inputContinuation else {
            throw .stage(.speechRecognition, .failed)
        }

        var outputContinuation: FinalizedSpeechStream.Continuation?
        let outputStream = FinalizedSpeechStream(
            bufferingPolicy: .bufferingOldest(16)
        ) { continuation in
            outputContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] termination in
                guard case .cancelled = termination else {
                    return
                }
                Task {
                    await self?.cancel()
                }
            }
        }
        guard let outputContinuation else {
            throw .stage(.speechRecognition, .failed)
        }

        let resultTask = Task { @Sendable in
            var sequenceNumber: UInt64 = 0
            do {
                for try await result in session.results() {
                    guard result.isFinal else {
                        continue
                    }
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        continue
                    }
                    outputContinuation.yield(
                        FinalizedSpeechSegment(
                            sequenceNumber: sequenceNumber,
                            text: text,
                            startOffset: result.startOffset,
                            endOffset: result.endOffset
                        )
                    )
                    sequenceNumber &+= 1
                }
            } catch let failure as PipelineFailure {
                await teardownGate.teardown(session: session)
                outputContinuation.finish(throwing: failure)
            } catch is CancellationError {
                await teardownGate.teardown(session: session)
                outputContinuation.finish(throwing: PipelineFailure.cancelled)
            } catch {
                await teardownGate.teardown(session: session)
                outputContinuation.finish(
                    throwing: PipelineFailure.stage(.speechRecognition, .failed)
                    )
            }
        }

        let processingTask = Task { @Sendable in
            do {
                var iterator = audio.makeAsyncIterator()
                guard let firstChunk = try await iterator.next() else {
                    inputContinuation.finish()
                    resultTask.cancel()
                    outputContinuation.finish()
                    return
                }

                let naturalFormat = MicrophoneAudioFormat(
                    sampleRate: firstChunk.sampleRate,
                    channelCount: firstChunk.channelCount
                )
                guard let analysisFormat = await session.bestAvailableAudioFormat(
                    considering: naturalFormat
                ) else {
                    throw PipelineFailure.stage(.speechRecognition, .invalidState)
                }
                try await session.prepare(toAnalyze: analysisFormat)
                let analyzerTask = Task {
                    try await session.start(input: inputStream)
                }

                var startOffset = Duration.zero
                inputContinuation.yield(
                    SpeechAudioInput(
                        chunk: firstChunk,
                        sourceFormat: naturalFormat,
                        analysisFormat: analysisFormat,
                        startOffset: startOffset
                    )
                )
                startOffset += firstChunk.duration

                while let chunk = try await iterator.next() {
                    inputContinuation.yield(
                        SpeechAudioInput(
                            chunk: chunk,
                            sourceFormat: MicrophoneAudioFormat(
                                sampleRate: chunk.sampleRate,
                                channelCount: chunk.channelCount
                            ),
                            analysisFormat: analysisFormat,
                            startOffset: startOffset
                        )
                    )
                    startOffset += chunk.duration
                }
                inputContinuation.finish()
                try await analyzerTask.value
                outputContinuation.finish()
            } catch let failure as PipelineFailure {
                inputContinuation.finish(throwing: failure)
                resultTask.cancel()
                await teardownGate.teardown(session: session)
                outputContinuation.finish(throwing: failure)
            } catch is CancellationError {
                inputContinuation.finish(throwing: PipelineFailure.cancelled)
                resultTask.cancel()
                await teardownGate.teardown(session: session)
                outputContinuation.finish(throwing: PipelineFailure.cancelled)
            } catch {
                inputContinuation.finish(
                    throwing: PipelineFailure.stage(.speechRecognition, .failed)
                )
                resultTask.cancel()
                await teardownGate.teardown(session: session)
                outputContinuation.finish(
                    throwing: PipelineFailure.stage(.speechRecognition, .failed)
                )
            }
        }

        self.activeSession = session
        self.inputContinuation = inputContinuation
        self.outputContinuation = outputContinuation
        self.processingTask = processingTask
        self.resultTask = resultTask
        self.teardownGate = teardownGate

        return outputStream
    }

    func stop() async {
        await finishSession(throwing: nil)
    }

    func cancel() async {
        await finishSession(throwing: .cancelled)
    }

    private func finishSession(throwing failure: PipelineFailure?) async {
        guard let session = activeSession else {
            return
        }

        inputContinuation?.finish(throwing: failure)
        processingTask?.cancel()
        resultTask?.cancel()
        await teardownGate?.teardown(session: session)
        outputContinuation?.finish(throwing: failure)

        activeSession = nil
        inputContinuation = nil
        outputContinuation = nil
        processingTask = nil
        resultTask = nil
        teardownGate = nil
    }
}

private actor SessionTeardownGate {
    private var hasTornDown = false

    func teardown(session: any SpeechRecognitionSession) async {
        guard !hasTornDown else {
            return
        }
        hasTornDown = true
        await session.cancelAndFinishNow()
    }
}

private func makeAVAudioFormat(_ format: MicrophoneAudioFormat) -> AVAudioFormat? {
    guard format.sampleRate > 0, format.channelCount > 0 else {
        return nil
    }
    return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.sampleRate,
        channels: AVAudioChannelCount(format.channelCount),
        interleaved: false
    )
}

private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private func makePCMBuffer(for input: SpeechAudioInput) throws(PipelineFailure) -> AVAudioPCMBuffer {
    guard let sourceFormat = makeAVAudioFormat(input.sourceFormat),
          let targetFormat = makeAVAudioFormat(input.analysisFormat) else {
        throw .stage(.speechRecognition, .invalidState)
    }

    let sourceChannelCount = input.sourceFormat.channelCount
    guard sourceChannelCount > 0,
          input.chunk.samples.count % sourceChannelCount == 0 else {
        throw .stage(.speechRecognition, .invalidState)
    }
    let sourceFrameCount = input.chunk.samples.count / sourceChannelCount
    guard sourceFrameCount > 0,
          let sourceBuffer = AVAudioPCMBuffer(
              pcmFormat: sourceFormat,
              frameCapacity: AVAudioFrameCount(sourceFrameCount)
          ),
          let sourceChannelData = sourceBuffer.floatChannelData else {
        throw .stage(.speechRecognition, .invalidState)
    }

    sourceBuffer.frameLength = AVAudioFrameCount(sourceFrameCount)
    for channel in 0..<sourceChannelCount {
        for frame in 0..<sourceFrameCount {
            sourceChannelData[channel][frame] = input.chunk.samples[
                (frame * sourceChannelCount) + channel
            ]
        }
    }

    guard !sourceFormat.isEqual(targetFormat) else {
        return sourceBuffer
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw .stage(.speechRecognition, .invalidState)
    }

    let outputFrameCapacity = AVAudioFrameCount(
        ceil(Double(sourceFrameCount) * targetFormat.sampleRate / sourceFormat.sampleRate) + 32
    )
    guard let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputFrameCapacity
    ) else {
        throw .stage(.speechRecognition, .invalidState)
    }

    let inputState = ConverterInputState(buffer: sourceBuffer)
    var conversionError: NSError?
    let status = converter.convert(
        to: outputBuffer,
        error: &conversionError
    ) { _, inputStatus in
        guard !inputState.didProvideInput else {
            inputStatus.pointee = .endOfStream
            return nil
        }
        inputState.didProvideInput = true
        inputStatus.pointee = .haveData
        return inputState.buffer
    }
    guard status != .error, outputBuffer.frameLength > 0, conversionError == nil else {
        throw .stage(.speechRecognition, .failed)
    }
    return outputBuffer
}

private func speechFailure(for error: Error) -> PipelineFailure {
    if error is CancellationError {
        return .cancelled
    }
    if let failure = error as? PipelineFailure {
        return failure
    }
    return .stage(.speechRecognition, .failed)
}

private func durationInSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}
