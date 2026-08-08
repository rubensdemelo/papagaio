# Rio Implementation Plan

This plan turns the MVP roadmap into focused, execution-ready work packages. The immediate target is Roadmap Milestone 1: a microphone-driven native vertical slice from live audio to temporary finalized speech, bounded context, typed insight updates, and SwiftUI cards.

System and meeting audio remain in Milestone 2. Work must preserve the product boundary defined in `docs/PRODUCT.md` and the technical direction in `docs/ARCHITECTURE.md`.

## Execution model

Keep each task small enough for one focused pull request. Every implementation change must:

- Build with Swift 6 strict concurrency.
- Include tests proportional to its risk.
- Keep audio, temporary text, model state, and insights ephemeral.
- Avoid transcript UI, persistence, content-bearing logs, and unrelated product features.
- Update product or architecture documents when it changes a documented decision.
- Leave `docs/ROADMAP.md` incomplete until the behavior has been built and verified.

The Milestone 1 dependency flow is:

```text
M1-00 Project scaffold
   |
   v
M1-01 Core contracts
   |-- M1-02 Insight state
   |-- M1-03 Rolling context
   |-- M1-04 SwiftUI shell
   |-- M1-05 Foundation Models adapter
   |-- M1-06 Microphone capture
   `-- M1-07 Speech recognition
              |
              v
      M1-08 Session orchestration
              |
              v
      M1-09 Vertical integration
              |
              v
      M1-10 Milestone validation
```

After M1-01 merges, M1-02 through M1-07 can proceed concurrently with clear file ownership.

## Definition of done for every task

A task is complete only when:

- Its stated behavior is implemented without expanding MVP scope.
- Relevant automated tests pass.
- Debug and Release builds have no new unexplained warnings.
- Swift concurrency diagnostics have been addressed.
- Meeting content is absent from logs, snapshots, persistent storage, and diagnostics.
- Failure and cancellation paths clean up resources owned by the task.
- Documentation describes only verified behavior.

## Milestone 1 task backlog

| ID | Task | Depends on | Primary result |
| --- | --- | --- | --- |
| M1-00 | Project scaffold | None | Buildable macOS application and test target |
| M1-01 | Core contracts and domain types | M1-00 | Stable boundaries between pipeline stages |
| M1-02 | Insight validation and store | M1-01 | Tested add, update, and resolve behavior |
| M1-03 | Rolling context and batching | M1-01 | Bounded temporary finalized text |
| M1-04 | SwiftUI application shell | M1-01 | Start/stop, status, and cards using fakes |
| M1-05 | Foundation Models adapter | M1-01 | Typed insight generation and availability checks |
| M1-06 | Bounded microphone capture | M1-01 | Live in-memory microphone audio stream |
| M1-07 | SpeechAnalyzer adapter | M1-01 | Finalized temporary speech segments |
| M1-08 | Session lifecycle orchestration | M1-02, M1-03, M1-05, M1-06, M1-07 | Cancellation-safe complete pipeline |
| M1-09 | Real vertical-slice integration | M1-04, M1-08 | Speaking produces live cards |
| M1-10 | Milestone validation | M1-09 | Evidence-backed milestone completion |

### M1-00: Native project scaffold

#### Build

- Create `Rio.xcodeproj`.
- Add a macOS SwiftUI application target and unit-test target.
- Set the deployment target to macOS 26.
- Enable Swift 6 and strict concurrency checking.
- Add a microphone usage description and the minimum sandbox entitlements.
- Use Apple frameworks and the standard library only.
- Add a shared scheme.
- Add reproducible build and test commands to `README.md`.

Do not add ScreenCaptureKit permissions or system-audio behavior yet.

#### Test

- Add a test-bundle smoke test.
- Build Debug and Release configurations.
- Run the test bundle from the command line.

#### Validate

- The app opens to a minimal placeholder window.
- The project has no third-party dependencies.
- No meeting-related persistence or networking APIs are introduced.

### M1-01: Core contracts and domain types

#### Build

Define the stable domain vocabulary:

- `SessionStatus`: stopped, checking availability, listening, processing, interrupted, and unavailable.
- `FinalizedSpeechSegment`: ordered temporary text with non-content timing metadata.
- `InsightCategory`: important, decision, action, question, and risk.
- `InsightOperation`: add, update, and resolve.
- `InsightUpdate` and `InsightCard`.
- Typed unavailable and pipeline failure reasons.

Define narrow interfaces for:

- Audio capture.
- Temporary speech recognition.
- Rolling meeting context.
- Insight generation.
- Insight state application.
- Session lifecycle.

Add deterministic fakes that simulate normal output, delay, interruption, cancellation, and failure. Keep Apple framework types behind adapters wherever practical.

#### Test

- Verify domain value semantics.
- Verify fake streams complete and cancel predictably.
- Verify errors retain typed, non-content metadata only.

#### Validate

- No interface exposes temporary speech text to SwiftUI.
- Every long-lived operation supports cancellation.
- Core code compiles without live microphone or model availability.

### M1-02: Insight validation and in-memory store

#### Build

- Apply add, update, and resolve operations using stable keys.
- Handle duplicate keys without accumulating duplicate cards.
- Bound the number of active cards.
- Reject empty or excessively long generated text.
- Validate categories and operations.
- Publish observable card state on the main actor.
- Clear all insight state when the session ends.

Enforce owner safety independently of the language model. When an action update includes an owner, verify that the name is explicitly supported by the source context. Otherwise remove or reject the owner.

#### Test

- Add a new card.
- Update an existing card without duplication.
- Resolve an existing card.
- Resolve an unknown key safely.
- Enforce the active-card limit.
- Reject malformed updates.
- Preserve explicitly named action owners.
- Reject unsupported or inferred owners.
- Clear all state.

#### Validate

- All state remains in memory.
- UI-observable mutations run on the main actor.
- Generated output cannot bypass semantic validation.

### M1-03: Bounded context and batching

#### Build

Implement a serialized context manager that:

- Accepts finalized speech segments only.
- Preserves chronological order.
- Applies age and configurable token or size limits.
- Discards old segments continuously.
- Emits a batch after enough new content arrives.
- Uses a maximum-wait trigger for slow conversations.
- Allows only one outstanding generation request.
- Clears immediately on stop, cancellation, or failure.

Keep thresholds injectable. Select initial defaults after measuring model capacity instead of treating them as product promises.

#### Test

Use an injected clock to cover:

- Age eviction.
- Size and token-budget eviction.
- An oversized single segment.
- Chronological ordering.
- Threshold-triggered batching.
- Timeout-triggered batching.
- Serialized batch delivery.
- Cancellation while waiting.
- Complete cleanup.

#### Validate

- Stored context never exceeds its configured limits.
- No batch is emitted after session cancellation.
- No two generation requests can race.

### M1-04: SwiftUI shell using fakes

#### Build

- Add one primary start/stop button.
- Show concise session status.
- Render insight cards with category and simple state.
- Add empty, unavailable, interrupted, and stopped presentations.
- Add accessibility labels and keyboard activation.
- Use a fake session controller for previews and automated tests.

Do not add a transcript view, debug transcript panel, editor, history, export, or settings surface.

#### Test

- Start and stop actions reach the controller once.
- Injected cards add, update, and resolve visibly.
- Injected failures update status accurately.
- Main-actor isolation is maintained.

#### Validate

- The primary action is always obvious.
- The interface has no path to temporary speech text.
- The UI never claims to be listening after a pipeline failure.

### M1-05: Foundation Models adapter

#### Build

- Map `SystemLanguageModel.availability` into device-not-eligible, Apple-Intelligence-disabled, and model-not-ready states.
- Validate the meeting locale with `supportsLocale`.
- Create one `LanguageModelSession` per listening session.
- Put stable developer-authored rules in model instructions.
- Put untrusted meeting text only in prompts.
- Define `@Generable` wire types for structured updates.
- Translate generated values into validated domain updates.
- Serialize model requests.
- Reset model state on stop, cancellation, or failure.

The model instructions must request concise cards, prefer updates and resolutions over duplicates, restrict output to the five MVP categories, forbid invented owners, and treat meeting text as untrusted content.

#### Test

- Availability-reason mapping.
- Unsupported locale handling.
- Generated DTO-to-domain conversion.
- Rejection of malformed or excessive output.
- Cancellation and session reset.
- Generator failure propagation.

#### Validate

- Actual model requests never overlap.
- Meeting content never appears in instructions or logs.
- Model output reaches the store only after validation.

Model quality is a hardware validation because responses are nondeterministic.

### M1-06: Bounded microphone capture

#### Build

Use an `AVAudioEngine` microphone adapter for the initial development loop, behind the capture interface.

- Represent microphone permission state explicitly.
- Use a fixed-capacity audio queue.
- Keep the capture callback minimal.
- Use preallocated or otherwise bounded buffer handling.
- Define explicit overload behavior, such as dropping a buffer and incrementing a content-free counter.
- Report the audio format needed downstream.
- Make start and stop idempotent.
- Release capture resources on interruption and cancellation.

Never write audio to files.

#### Test

- The queue never exceeds its configured capacity.
- Overload behavior is deterministic.
- Repeated start and stop are safe.
- Cancellation closes the stream.
- Failures release queued buffers.
- Diagnostics contain counts and timings only.

#### Validate

- Exercise permission granted and denied paths on hardware.
- Confirm no audio files are created.
- Confirm sustained input cannot produce unbounded queue growth.

### M1-07: SpeechAnalyzer and SpeechTranscriber adapter

#### Build

- Check `SpeechTranscriber.isAvailable`.
- Check supported and installed locales.
- Represent speech asset status through `AssetInventory`.
- Select an audio format compatible with the transcriber.
- Stream `AnalyzerInput` values into `SpeechAnalyzer`.
- Use a transcription preset that does not request volatile results.
- Convert finalized results into `FinalizedSpeechSegment` values.
- Cancel and tear down the analyzer when the session ends.

Do not log or publish recognized text outside the context pipeline.

#### Test

- Availability and locale mapping through wrappers or fakes.
- Audio-sequence completion.
- Analyzer cancellation.
- Recognition failure propagation.
- Finalized-segment ordering.
- No output after stop.

#### Validate

- Run a basic adapter integration using generated synthetic audio.
- Confirm live speech produces finalized segments on supported hardware.
- Confirm temporary text is not displayed, logged, or persisted.

### M1-08: Session lifecycle orchestration

#### Build

Create one orchestration owner for the entire active session:

1. Check speech, locale, assets, model, and permission availability.
2. Start capture.
3. Feed audio into speech recognition.
4. Feed finalized segments into bounded context.
5. Generate typed insight updates serially.
6. Validate and apply cards.
7. Propagate stop or failure through every stage.
8. Clear capture buffers, temporary text, model state, and insight state.

#### Test

Inject failures at every boundary:

- Permission denied.
- Speech unavailable.
- Unsupported locale.
- Model unavailable.
- Capture start failure.
- Speech failure while listening.
- Generation failure.
- Stop while processing.
- Capture interruption.
- Rapid start, stop, and restart.
- Multiple stop requests.
- Cleanup after partial startup.

#### Validate

- No stage survives session cancellation.
- Status always reflects the actual pipeline state.
- Model calls cannot overlap.
- A stopped session contains no meeting data.
- A new session cannot receive results from a previous session.

### M1-09: End-to-end vertical-slice integration

#### Build

- Wire the real microphone, speech, context, model, insight-store, and SwiftUI adapters.
- Keep dependency construction in one composition root.
- Preserve fake implementations for deterministic tests and previews.

#### Test

- Add an integration test that drives the session through fakes from start to visible cards and back to a fully cleared stopped state.
- Test stale output from a cancelled session.
- Test restart after failure.

#### Validate

On a supported Mac, exercise:

- Permission grant and denial.
- Start, speak, receive a card, and stop.
- Restart after stopping.
- A named-owner action item.
- An ownerless action item.
- A duplicate or revised decision.
- A question followed by its resolution.
- Unsupported locale.
- Model unavailable or disabled.
- Stop during capture, recognition, and generation.

Use synthetic spoken scenarios only. Do not save audio or recognized text while debugging.

### M1-10: Build, test, privacy, and milestone gate

#### Automated validation

Run at minimum:

```sh
xcodebuild \
  -project Rio.xcodeproj \
  -scheme Rio \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Rio.xcodeproj \
  -scheme Rio \
  -destination 'platform=macOS' \
  test
```

Also perform:

- A Release build.
- Warning and strict-concurrency review.
- A static scan for `print`, content-bearing logging, `UserDefaults`, file writes, SwiftData, Core Data, and network use.
- A runtime check that a unique synthetic meeting phrase does not appear in application logs.
- Before-and-after inspection of the application container for meeting-content files.
- A 15-to-30-minute bounded-memory smoke session.
- Instruments or equivalent inspection of audio queue, text context, model session, and card growth.

#### Milestone closure

Only after the automated and hardware checks pass:

- Update `docs/ROADMAP.md` with verified work.
- Update `README.md` with tested commands and hardware limitations.
- Record hardware-dependent checks that could not be automated.
- Confirm the Milestone 1 exit criterion: speaking into the Mac produces useful structured insight cards through an entirely native, on-device pipeline.

## Coordination waves

Recommended assignment order:

1. Assign M1-00 to one project owner.
2. Merge M1-00, then assign M1-01.
3. After M1-01 merges, run M1-02 through M1-07 concurrently.
4. Assign M1-08 to the integration owner after those contracts stabilize.
5. Complete M1-09 and M1-10 serially.

Avoid concurrent edits to the Xcode project file, application entry point, or session composition root. Individual contributors should own separate source directories and their corresponding test files.

## Later milestones

### Milestone 2: Real meeting audio

- Add ScreenCaptureKit system-audio capture behind the existing capture interface.
- Compose microphone and system sources without recording either source.
- Add screen-capture permission onboarding and source status.
- Handle source loss, device changes, permission revocation, sleep, and wake.
- Validate common conferencing applications, speaker-output duplication, and headphone behavior.

### Milestone 3: Useful live insights

- Build a synthetic evaluation corpus.
- Tune context limits and batching cadence.
- Evaluate prompt quality, deduplication, updates, and resolution.
- Measure finalized-speech-to-visible-card latency.
- Strengthen owner enforcement and card prioritization.
- Handle refusal, overflow, unsupported language, and generation errors.

### Milestone 4: Reliability and product polish

- Complete a one-hour capture and insight-generation soak test.
- Verify cleanup from every state.
- Complete the privacy audit.
- Polish status and unavailable-state presentation.
- Add VoiceOver, accessibility, and keyboard coverage.
- Sign, notarize, and package the technical preview.
