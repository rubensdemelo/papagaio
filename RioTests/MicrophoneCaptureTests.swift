import XCTest

final class MicrophoneCaptureTests: XCTestCase {
    func testPermissionIsExplicitAndDeniedPermissionPreventsStart() async throws {
        let permission = TestMicrophonePermissionProvider(permission: .denied)
        let engine = TestMicrophoneEngine()
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: permission
        )

        let permissionState = await capture.permission()
        let availability = await capture.checkAvailability()
        XCTAssertEqual(permissionState, .denied)
        XCTAssertEqual(availability, .unavailable(.microphonePermissionDenied))

        do {
            _ = try await capture.start()
            XCTFail("Denied microphone permission must prevent capture")
        } catch let failure {
            XCTAssertEqual(failure, .unavailable(.microphonePermissionDenied))
        }
        XCTAssertEqual(engine.startCount, 0)
    }

    func testUndeterminedPermissionIsRequestedBeforeStarting() async throws {
        let permission = TestMicrophonePermissionProvider(
            permission: .undetermined,
            requestedPermission: .granted
        )
        let engine = TestMicrophoneEngine()
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: permission
        )

        let availability = await capture.checkAvailability()
        XCTAssertEqual(availability, .unavailable(.microphonePermissionUndetermined))
        _ = try await capture.start()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(engine.startCount, 1)
        await capture.stop()
    }

    func testBoundedQueueDropsNewestBufferAtCapacity() {
        let queue = BoundedAudioQueue(capacity: 2)
        defer { queue.finish() }

        XCTAssertEqual(queue.enqueue(makeChunk(sequenceNumber: 1)).result, .accepted)
        XCTAssertEqual(queue.enqueue(makeChunk(sequenceNumber: 2)).result, .accepted)
        XCTAssertEqual(queue.enqueue(makeChunk(sequenceNumber: 3)).result, .dropped)
        XCTAssertEqual(queue.pendingCount, 2)

        queue.finish()
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.enqueue(makeChunk(sequenceNumber: 4)).result, .terminated)
    }

    func testCaptureDeliversAudioInOrderAndReportsFormat() async throws {
        let engine = TestMicrophoneEngine(
            format: MicrophoneAudioFormat(sampleRate: 48_000, channelCount: 1)
        )
        let diagnostics = MicrophoneCaptureDiagnostics()
        let permission = TestMicrophonePermissionProvider(permission: .granted)
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: permission,
            queueCapacity: 4,
            diagnostics: diagnostics
        )
        let stream = try await capture.start()
        let format = await capture.audioFormat()
        XCTAssertEqual(format, MicrophoneAudioFormat(sampleRate: 48_000, channelCount: 1))

        let consumer = Task { () -> [UInt64] in
            var sequenceNumbers: [UInt64] = []
            do {
                for try await chunk in stream {
                    sequenceNumbers.append(chunk.sequenceNumber)
                    if sequenceNumbers.count == 2 {
                        break
                    }
                }
            } catch {
                XCTFail("Audio stream unexpectedly failed")
            }
            return sequenceNumbers
        }

        engine.emit(makeChunk(sequenceNumber: 10))
        engine.emit(makeChunk(sequenceNumber: 11))

        let sequenceNumbers = await consumer.value
        XCTAssertEqual(sequenceNumbers, [10, 11])
        await capture.stop()
        let stoppedFormat = await capture.audioFormat()
        let diagnosticsSnapshot = await capture.diagnostics()
        XCTAssertEqual(stoppedFormat, nil)
        XCTAssertEqual(diagnosticsSnapshot.acceptedBufferCount, 2)
        XCTAssertEqual(
            permission.requestCount,
            0,
            "Granted microphone access must not trigger another authorization request."
        )
    }

    func testStartAndStopAreIdempotentAndRestartCreatesNewCapture() async throws {
        let engine = TestMicrophoneEngine()
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: TestMicrophonePermissionProvider(permission: .granted)
        )

        let firstStream = try await capture.start()
        let sameStream = try await capture.start()
        _ = firstStream
        _ = sameStream
        XCTAssertEqual(engine.startCount, 1)

        await capture.stop()
        await capture.stop()
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.removeTapCount, 1)

        _ = try await capture.start()
        XCTAssertEqual(engine.startCount, 2)
        await capture.stop()
        XCTAssertEqual(engine.stopCount, 2)
        XCTAssertEqual(engine.removeTapCount, 2)
    }

    func testEngineFailureReleasesTapAndQueuedResources() async throws {
        let engine = TestMicrophoneEngine(startError: TestEngineError.startFailed)
        let diagnostics = MicrophoneCaptureDiagnostics()
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: TestMicrophonePermissionProvider(permission: .granted),
            diagnostics: diagnostics
        )

        do {
            _ = try await capture.start()
            XCTFail("The engine failure must be surfaced")
        } catch let failure {
            XCTAssertEqual(failure, .stage(.audioCapture, .failed))
        }

        XCTAssertEqual(engine.removeTapCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        let format = await capture.audioFormat()
        let diagnosticsSnapshot = await capture.diagnostics()
        XCTAssertEqual(format, nil)
        XCTAssertEqual(diagnosticsSnapshot.failureCount, 1)
    }

    func testCancellationFinishesStreamAndReleasesCapture() async throws {
        let engine = TestMicrophoneEngine()
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: TestMicrophonePermissionProvider(permission: .granted)
        )
        let stream = try await capture.start()
        let consumer = Task { () -> PipelineFailure? in
            do {
                for try await _ in stream { }
                return nil
            } catch let failure as PipelineFailure {
                return failure
            } catch {
                return .stage(.audioCapture, .failed)
            }
        }

        await capture.cancel()

        let result = await consumer.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.removeTapCount, 1)
        let format = await capture.audioFormat()
        XCTAssertEqual(format, nil)
    }

    func testCancellationDuringPermissionRequestDoesNotStartEngine() async throws {
        let permission = BlockingMicrophonePermissionProvider()
        let engine = TestMicrophoneEngine()
        let capture = AVAudioEngineMicrophoneCapture(
            engine: engine,
            permissionProvider: permission
        )

        let start = Task {
            try await capture.start()
        }
        await permission.waitUntilRequested()
        await capture.cancel()
        permission.resolve(.granted)

        do {
            _ = try await start.value
            XCTFail("Cancellation must prevent a pending start")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertEqual(engine.startCount, 0)
    }

    private func makeChunk(sequenceNumber: UInt64) -> AudioChunk {
        AudioChunk(
            sequenceNumber: sequenceNumber,
            duration: .milliseconds(20),
            sampleRate: 48_000,
            channelCount: 1,
            samples: [0.0, 0.1]
        )
    }
}

private enum TestEngineError: Error {
    case startFailed
}

private final class TestMicrophoneEngine: MicrophoneEngineDriver, @unchecked Sendable {
    let inputFormat: MicrophoneAudioFormat
    let startError: Error?
    private var handler: (@Sendable (AudioChunk) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var removeTapCount = 0

    init(
        format: MicrophoneAudioFormat = MicrophoneAudioFormat(sampleRate: 48_000, channelCount: 1),
        startError: Error? = nil
    ) {
        inputFormat = format
        self.startError = startError
    }

    func installTap(
        bufferSize: UInt32,
        handler: @escaping @Sendable (AudioChunk) -> Void
    ) {
        self.handler = handler
    }

    func removeTap() {
        removeTapCount += 1
        handler = nil
    }

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ chunk: AudioChunk) {
        handler?(chunk)
    }
}

private final class TestMicrophonePermissionProvider: MicrophonePermissionProviding, @unchecked Sendable {
    private(set) var permission: MicrophonePermission
    let requestedPermission: MicrophonePermission
    private(set) var requestCount = 0

    init(
        permission: MicrophonePermission,
        requestedPermission: MicrophonePermission = .denied
    ) {
        self.permission = permission
        self.requestedPermission = requestedPermission
    }

    func currentPermission() -> MicrophonePermission {
        permission
    }

    func requestPermission() async -> MicrophonePermission {
        requestCount += 1
        permission = requestedPermission
        return requestedPermission
    }
}

private final class BlockingMicrophonePermissionProvider: MicrophonePermissionProviding, @unchecked Sendable {
    private var requested = false
    private var continuation: CheckedContinuation<MicrophonePermission, Never>?

    func currentPermission() -> MicrophonePermission {
        .undetermined
    }

    func requestPermission() async -> MicrophonePermission {
        requested = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while !requested {
            await Task.yield()
        }
    }

    func resolve(_ permission: MicrophonePermission) {
        continuation?.resume(returning: permission)
        continuation = nil
    }
}
