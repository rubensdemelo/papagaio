# Papagaio

Papagaio is a deliberately simple macOS app that listens to meetings and shows useful insights while the conversation is still happening.

The insight stream is the product. Papagaio is not a transcription app, note-taking app, meeting recorder, or meeting archive.

## Status

M1-00 provides the native macOS 26+ SwiftUI application and unit-test scaffold. Later milestones will add the temporary audio, speech, model, and insight pipeline.

## MVP experience

The app has one primary action: start or stop listening. During a meeting, it surfaces concise cards for:

- Important points and takeaways.
- Decisions.
- Action items.
- Open questions.
- Risks, blockers, and unresolved topics.

Insights update or replace stale cards instead of accumulating duplicates. Papagaio never guesses an action-item owner; it includes one only when the meeting explicitly names that person.

Papagaio does not display a live transcript. Audio and temporary speech-to-text output are discarded continuously and cleared when listening stops.

## Apple-native pipeline

```text
Microphone + meeting/system audio
                 │
                 v
        ScreenCaptureKit
                 │
                 v
SpeechAnalyzer + SpeechTranscriber
                 │
          temporary text
                 │
                 v
 Foundation Models / Apple Intelligence
                 │
                 v
        live insight cards
```

The macOS MVP uses:

- Swift and SwiftUI for the application and interface.
- ScreenCaptureKit for live meeting/system audio and microphone capture where supported.
- SpeechAnalyzer and SpeechTranscriber for temporary, on-device speech-to-text.
- The Foundation Models framework and `SystemLanguageModel` for on-device meeting understanding.
- Guided generation for structured, typed insight updates.

## Requirements

The first release targets:

- macOS 26 or later.
- A Mac that supports Apple Intelligence.
- Apple Intelligence enabled and ready on the device.
- A meeting language supported by both SpeechTranscriber and the system language model.
- Microphone and screen-capture permissions.

Papagaio checks these capabilities at runtime and explains unavailable states. The MVP does not use a cloud-model fallback.

## Data lifecycle

Meeting data is ephemeral in the MVP:

- Audio is processed as a live stream and is not intentionally written to disk.
- Audio queues and temporary text buffers are bounded.
- Only finalized speech results enter the rolling insight context.
- Old audio and text are continuously discarded.
- Stopping a session clears remaining audio, temporary text, model-session state, and insight cards.
- Meeting content must never appear in logs, analytics, crash annotations, or test fixtures.

## MVP exclusions

- Visible transcription or transcript editing.
- Note-taking and document editing.
- Audio recording or playback.
- Transcript export, meeting history, or a database.
- Meeting bots, speaker identification, or diarization.
- Accounts, calendar integrations, team workspaces, or cloud synchronization.
- OpenAI or another cloud inference provider.
- Windows and Linux support.

## Project documents

- [Product vision](IDEA.md)
- [Product definition](docs/PRODUCT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Agent and contribution guidance](AGENTS.md)

## Development

The project uses Xcode 26.6, Swift 6, and a macOS 26 deployment target. Build and test from the repository root:

```sh
xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Papagaio \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build

xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Papagaio \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build

xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Papagaio \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  test
```

M1-00 is limited to the placeholder window, project configuration, and test-bundle smoke test. Verified progress is tracked in [the roadmap](docs/ROADMAP.md); work must not be marked complete until the corresponding acceptance criteria pass.
