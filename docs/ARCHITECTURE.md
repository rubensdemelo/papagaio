# Papagaio Architecture

## MVP architecture

Papagaio is a native Swift macOS application. The first release does not introduce a Rust core, C ABI, database, cloud provider, or cross-platform abstraction.

```text
Microphone audio ─────┐
                      ├─> bounded audio pipeline
System/meeting audio ─┘             │
                                    v
                       SpeechAnalyzer + SpeechTranscriber
                                    │
                             finalized text only
                                    │
                                    v
                         bounded rolling text context
                                    │
                                    v
                    Foundation Models / SystemLanguageModel
                                    │
                         structured insight updates
                                    │
                                    v
                           live SwiftUI insight cards

Old audio buffers and temporary text are continuously discarded.
Stopping the session clears all remaining meeting data.
```

## Native technology choices

### Audio capture

Use ScreenCaptureKit to capture meeting/system audio and microphone audio. Exclude Papagaio's own process audio where supported so app sounds do not re-enter the pipeline.

The app requests the required microphone and screen-capture permissions and makes their status visible. The capture layer must handle device removal, output changes, sleep and wake, permission revocation, and the selected meeting source disappearing.

The MVP does not save audio or create a recording output. Capture callbacks perform minimal work and hand bounded buffers to the speech pipeline without file I/O or blocking UI work.

If one ScreenCaptureKit stream cannot provide the required microphone and system-audio behavior on the minimum supported macOS release, use AVAudioEngine for the microphone while keeping the same downstream interface.

### Temporary speech-to-text

Use SpeechAnalyzer with SpeechTranscriber for on-device speech recognition. Speech recognition and Apple Intelligence are separate stages: SpeechTranscriber converts audio to text, while the system language model understands that text.

Only finalized speech results enter the insight context. Volatile results may be used internally to measure responsiveness but never become insight evidence or UI content.

At startup, check:

- SpeechTranscriber availability on the device.
- Support for the selected meeting locale.
- Installation state of required speech assets.

The current M1 composition root supplies `en-US` as the fixed meeting locale regardless of the Mac's system locale. A user-selectable locale remains outside the current interface.

The app should guide the user when assets are downloadable and stop cleanly when the language or device is unsupported.

### Rolling meeting context

The transcript is an internal, bounded buffer rather than a product model. It has no editor, transcript view, export path, or persistent store.

The context manager:

- Accepts finalized text segments in order.
- Retains only a limited recent window sized to fit the language model context.
- Groups enough new content before requesting another insight update.
- Discards segments after they are no longer needed.
- Clears immediately when the session stops.

The first implementation should trigger insight analysis on a small batch of new finalized text, with a maximum wait so quiet or slow meetings still produce updates. Exact thresholds must be tuned with recorded test fixtures and live meetings rather than treated as product behavior.

### Meeting understanding

Use the Foundation Models framework's `SystemLanguageModel`, which provides access to the on-device model that powers Apple Intelligence.

When the app window loads and before starting a session, inspect all session prerequisites and retain a combined readiness report for the UI. Repeat the check during session preflight so changes made in System Settings are reflected. The preflight checks microphone permission and capture availability, speech recognition availability and assets, model availability, and locale support. Foundation Models exposes device eligibility, Apple Intelligence not enabled, and model-not-ready states; it does not expose organization policy as a separate public availability reason. For the not-enabled state, guide the user to align the Mac and Siri languages, enable Apple Intelligence, and contact the administrator if the managed-device restriction remains. An undetermined microphone permission is allowed to continue so the system permission prompt can appear; other blocking prerequisites stop startup. The UI must distinguish at least:

- Available.
- Device not eligible.
- Apple Intelligence or model not ready.
- Unsupported meeting language.
- Generation temporarily failed.

Use a `LanguageModelSession` with stable developer-authored instructions. Meeting text belongs in prompts, never interpolated into privileged instructions.

Use guided generation with `@Generable` types for structured results. A conceptual result is:

```text
InsightUpdate
  operation: add | update | resolve
  stableKey: String
  category: important | decision | action | question | risk
  text: String
  explicitOwner: String?
```

The app validates semantic constraints after generation, including nonempty text, known categories, bounded card counts, and the rule against guessed owners.

### Insight state

An in-memory insight store applies generated updates on the main actor. Stable keys allow the model to update or resolve an existing card instead of creating duplicates.

Insights exist only for the active session. The MVP does not include a database, automatic history, or export. Closing or stopping the session clears the store after an explicit confirmation if doing so would surprise the user.

## Data and memory boundaries

All queues and buffers are bounded:

- Audio queues have a fixed duration limit and drop or signal overload rather than grow indefinitely.
- Temporary finalized text is limited by age and token budget.
- The insight store has a maximum active-card count.
- Language model sessions are reset when listening stops.

Diagnostics may record durations, queue depth, model availability, and error codes. They must never record audio, transcript text, generated insight text, or other meeting content.

## Concurrency

- Capture callbacks do minimal real-time work.
- Speech analysis runs asynchronously outside the main actor.
- Context batching and model generation are serialized so insight requests do not race.
- SwiftUI state changes occur on the main actor.
- Session cancellation propagates through capture, speech analysis, context processing, generation, and UI state.

## Failure behavior

A failure must not silently leave the app appearing to listen.

- Permission denial explains which permission is needed and how to retry.
- Capture interruption changes the status and attempts a bounded recovery where safe.
- Speech failure keeps capture state accurate and offers restart.
- Model unavailability prevents insight generation and explains the reason.
- A failed generation request may retry after new finalized text arrives; it does not preserve unbounded text while waiting.
- Stopping always clears temporary meeting data, including after a partial failure.

## Deferred decisions

The following are outside the first MVP and require a new product decision before implementation:

- Insight export or session history.
- Cloud inference or fallback providers.
- Speaker identification.
- A portable Rust audio core.
- Windows or Linux applications.
