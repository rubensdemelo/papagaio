import AVFAudio
import Foundation

enum MicrophonePermission: Sendable, Equatable {
    case undetermined
    case denied
    case granted
}

protocol MicrophonePermissionProviding: Sendable {
    func currentPermission() -> MicrophonePermission
    func requestPermission() async -> MicrophonePermission
}

struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding, Sendable {
    func currentPermission() -> MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            return .undetermined
        case .denied:
            return .denied
        case .granted:
            return .granted
        @unknown default:
            return .denied
        }
    }

    func requestPermission() async -> MicrophonePermission {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }

}

struct MicrophoneAudioFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
}

protocol MicrophoneEngineDriver: AnyObject, Sendable {
    var inputFormat: MicrophoneAudioFormat { get }
    func installTap(
        bufferSize: UInt32,
        handler: @escaping @Sendable (AudioChunk) -> Void
    )
    func removeTap()
    func start() throws
    func stop()
}

final class AVAudioEngineMicrophoneDriver: MicrophoneEngineDriver, @unchecked Sendable {
    private let engine: AVAudioEngine
    // AVAudioEngine invokes one tap serially; the counter is only touched by that callback.
    private var sequenceNumber: UInt64 = 0

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    var inputFormat: MicrophoneAudioFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return MicrophoneAudioFormat(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    func installTap(
        bufferSize: UInt32,
        handler: @escaping @Sendable (AudioChunk) -> Void
    ) {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(bufferSize),
            format: format
        ) { [self] buffer, _ in
            guard let channelData = buffer.floatChannelData else {
                return
            }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else {
                return
            }

            var samples = [Float](repeating: 0, count: frameCount * channelCount)
            for channel in 0..<channelCount {
                let source = channelData[channel]
                for frame in 0..<frameCount {
                    samples[(frame * channelCount) + channel] = source[frame]
                }
            }

            let chunk = AudioChunk(
                sequenceNumber: sequenceNumber,
                duration: .seconds(Double(frameCount) / buffer.format.sampleRate),
                sampleRate: buffer.format.sampleRate,
                channelCount: channelCount,
                samples: samples
            )
            sequenceNumber &+= 1
            handler(chunk)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

enum BoundedAudioEnqueueResult: Sendable, Equatable {
    case accepted
    case dropped
    case terminated
}

struct BoundedAudioEnqueueOutcome: Sendable, Equatable {
    let result: BoundedAudioEnqueueResult
    let queueDepth: Int
}

struct MicrophoneCaptureDiagnosticsSnapshot: Sendable, Equatable {
    let acceptedBufferCount: UInt64
    let droppedBufferCount: UInt64
    let terminatedBufferCount: UInt64
    let maximumQueueDepth: Int
    let failureCount: UInt64
}

final class MicrophoneCaptureDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptedBufferCount: UInt64 = 0
    private var droppedBufferCount: UInt64 = 0
    private var terminatedBufferCount: UInt64 = 0
    private var maximumQueueDepth = 0
    private var failureCount: UInt64 = 0

    func record(_ result: BoundedAudioEnqueueResult, queueDepth: Int) {
        guard lock.try() else {
            return
        }
        defer { lock.unlock() }

        switch result {
        case .accepted:
            acceptedBufferCount &+= 1
            maximumQueueDepth = max(maximumQueueDepth, queueDepth)
        case .dropped:
            droppedBufferCount &+= 1
        case .terminated:
            terminatedBufferCount &+= 1
        }
    }

    func recordFailure() {
        guard lock.try() else {
            return
        }
        defer { lock.unlock() }
        failureCount &+= 1
    }

    func snapshot() -> MicrophoneCaptureDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MicrophoneCaptureDiagnosticsSnapshot(
            acceptedBufferCount: acceptedBufferCount,
            droppedBufferCount: droppedBufferCount,
            terminatedBufferCount: terminatedBufferCount,
            maximumQueueDepth: maximumQueueDepth,
            failureCount: failureCount
        )
    }
}

final class BoundedAudioQueue: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var storage: [AudioChunk?]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var terminated = false
    private var terminalFailure: PipelineFailure?

    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)

        var continuation: AsyncStream<Void>.Continuation?
        wakeStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        wakeContinuation = continuation!
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func enqueue(_ chunk: AudioChunk) -> BoundedAudioEnqueueOutcome {
        // The realtime producer never waits for the consumer. Contention drops the newest chunk.
        guard lock.try() else {
            return BoundedAudioEnqueueOutcome(result: .dropped, queueDepth: 0)
        }

        guard !terminated else {
            lock.unlock()
            return BoundedAudioEnqueueOutcome(result: .terminated, queueDepth: 0)
        }
        guard count < capacity else {
            let queueDepth = count
            lock.unlock()
            return BoundedAudioEnqueueOutcome(result: .dropped, queueDepth: queueDepth)
        }

        storage[writeIndex] = chunk
        writeIndex = (writeIndex + 1) % capacity
        count += 1
        let queueDepth = count
        lock.unlock()
        wakeContinuation.yield(())
        return BoundedAudioEnqueueOutcome(result: .accepted, queueDepth: queueDepth)
    }

    func makeStream(
        onOutputDrop: @escaping @Sendable () -> Void,
        onTermination: @escaping @Sendable () -> Void
    ) -> AudioStream {
        let stream = AsyncThrowingStream<AudioChunk, any Error>(
            bufferingPolicy: .bufferingOldest(capacity)
        ) { continuation in
            let pump = Task { [self] in
                for await _ in wakeStream {
                    drain(into: continuation, onOutputDrop: onOutputDrop)
                }

                drain(into: continuation, onOutputDrop: onOutputDrop)
                continuation.finish(throwing: terminalFailureSnapshot())
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                pump.cancel()
                self?.finish(throwing: .cancelled)
                onTermination()
            }
        }
        return stream
    }

    func finish(throwing failure: PipelineFailure? = nil) {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }

        terminated = true
        terminalFailure = failure
        clearStorageLocked()
        lock.unlock()

        wakeContinuation.finish()
    }

    private func drain(
        into continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation,
        onOutputDrop: @Sendable () -> Void
    ) {
        while let chunk = dequeue() {
            if case .dropped = continuation.yield(chunk) {
                onOutputDrop()
            }
        }
    }

    private func dequeue() -> AudioChunk? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else {
            return nil
        }

        let chunk = storage[readIndex]
        storage[readIndex] = nil
        readIndex = (readIndex + 1) % capacity
        count -= 1
        return chunk
    }

    private func clearStorageLocked() {
        for index in storage.indices {
            storage[index] = nil
        }
        count = 0
        readIndex = 0
        writeIndex = 0
    }

    private func terminalFailureSnapshot() -> PipelineFailure? {
        lock.lock()
        defer { lock.unlock() }
        return terminalFailure
    }
}

actor AVAudioEngineMicrophoneCapture: AudioCapture {
    private let engine: any MicrophoneEngineDriver
    private let permissionProvider: any MicrophonePermissionProviding
    private let bufferSize: UInt32
    private let queueCapacity: Int
    private let diagnosticsStore: MicrophoneCaptureDiagnostics

    private var queue: BoundedAudioQueue?
    private var activeStream: AudioStream?
    private var isStarting = false
    private var isRunning = false
    private var cancellationRequested = false

    init(
        engine: any MicrophoneEngineDriver = AVAudioEngineMicrophoneDriver(),
        permissionProvider: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        bufferSize: UInt32 = 1_024,
        queueCapacity: Int = 8,
        diagnostics: MicrophoneCaptureDiagnostics = MicrophoneCaptureDiagnostics()
    ) {
        precondition(bufferSize > 0)
        precondition(queueCapacity > 0)
        self.engine = engine
        self.permissionProvider = permissionProvider
        self.bufferSize = bufferSize
        self.queueCapacity = queueCapacity
        diagnosticsStore = diagnostics
    }

    func permission() async -> MicrophonePermission {
        permissionProvider.currentPermission()
    }

    func checkAvailability() async -> Availability {
        switch permissionProvider.currentPermission() {
        case .granted:
            guard engine.inputFormat.channelCount > 0, engine.inputFormat.sampleRate > 0 else {
                return .unavailable(.audioInputUnavailable)
            }
            return .available
        case .denied:
            return .unavailable(.microphonePermissionDenied)
        case .undetermined:
            return .unavailable(.microphonePermissionUndetermined)
        }
    }

    func diagnostics() async -> MicrophoneCaptureDiagnosticsSnapshot {
        diagnosticsStore.snapshot()
    }

    func audioFormat() async -> MicrophoneAudioFormat? {
        guard isRunning else {
            return nil
        }
        return engine.inputFormat
    }

    func start() async throws(PipelineFailure) -> AudioStream {
        if isRunning, let activeStream {
            return activeStream
        }
        guard !isStarting else {
            throw .stage(.audioCapture, .invalidState)
        }
        isStarting = true
        cancellationRequested = false
        defer { isStarting = false }

        var permission = permissionProvider.currentPermission()
        if permission == .undetermined {
            permission = await permissionProvider.requestPermission()
        }
        if Task.isCancelled || cancellationRequested {
            throw .cancelled
        }
        guard permission == .granted else {
            throw .unavailable(.microphonePermissionDenied)
        }

        let format = engine.inputFormat
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw .unavailable(.audioInputUnavailable)
        }
        if Task.isCancelled || cancellationRequested {
            throw .cancelled
        }

        let queue = BoundedAudioQueue(capacity: queueCapacity)
        let stream = queue.makeStream(
            onOutputDrop: { [diagnosticsStore] in
                diagnosticsStore.record(.dropped, queueDepth: 0)
            },
            onTermination: { [weak self] in
                Task {
                    await self?.cancel()
                }
            }
        )

        do {
            engine.installTap(bufferSize: bufferSize) { [queue, diagnosticsStore] chunk in
                let outcome = queue.enqueue(chunk)
                diagnosticsStore.record(outcome.result, queueDepth: outcome.queueDepth)
            }
            try engine.start()
        } catch {
            diagnosticsStore.recordFailure()
            engine.removeTap()
            engine.stop()
            queue.finish(throwing: .stage(.audioCapture, .failed))
            throw .stage(.audioCapture, .failed)
        }

        self.queue = queue
        activeStream = stream
        isRunning = true
        return stream
    }

    func stop() async {
        await finish(throwing: nil)
    }

    func cancel() async {
        await finish(throwing: .cancelled)
    }

    private func finish(throwing failure: PipelineFailure?) async {
        if isStarting {
            cancellationRequested = true
        }
        guard isRunning || queue != nil else {
            return
        }

        isRunning = false
        activeStream = nil
        engine.removeTap()
        engine.stop()
        queue?.finish(throwing: failure)
        queue = nil
    }
}
