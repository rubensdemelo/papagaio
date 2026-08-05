# Papagaio

Papagaio is a deliberately simple macOS app that listens to meetings and shows useful insights while the conversation is still happening.

The insight stream is the product. Papagaio is not a transcription app, note-taking app, meeting recorder, or meeting archive.

## Status

Papagaio is in the pre-implementation design stage. The product definition, initial architecture, and MVP roadmap are documented; the macOS application has not been created yet.

The first milestone is a native vertical slice that turns microphone audio into temporary text and then into structured insight cards using Apple frameworks.

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

There is no buildable application target yet. Development begins with the native vertical slice described in the first roadmap milestone.

When implementation starts, build and test instructions will live here. Verified progress is tracked in [the roadmap](docs/ROADMAP.md); work must not be marked complete until the corresponding build and tests pass.
