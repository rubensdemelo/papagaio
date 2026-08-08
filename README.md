# Rio

Rio is a deliberately simple macOS meeting assistant for IBM employees. Bob helps with coding; Rio helps with meetings by showing useful insights while the conversation is still happening.

The insight stream is the product. Rio is not a transcription app, note-taking app, meeting recorder, or meeting archive.

## Status

M1-09 provides the native microphone-to-insight vertical slice, including temporary speech recognition, bounded context, on-device Foundation Models generation, in-memory cards, session cleanup, and the SwiftUI composition root. Automated M1-10 checks pass; direct hardware acceptance remains open.

## MVP experience

The app has one primary action: start or stop listening. During a meeting, it surfaces concise cards for:

- Important points and takeaways.
- Decisions.
- Action items.
- Open questions.
- Risks, blockers, and unresolved topics.

Insights update or replace stale cards instead of accumulating duplicates. Rio never guesses an action-item owner; it includes one only when the meeting explicitly names that person.

Rio does not display a live transcript. Audio and temporary speech-to-text output are discarded continuously and cleared when listening stops.

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

The current M1 vertical slice uses:

- Swift and SwiftUI for the application and interface.
- AVAudioEngine for microphone capture. ScreenCaptureKit meeting/system audio is planned for Milestone 2.
- SpeechAnalyzer and SpeechTranscriber for temporary, on-device speech-to-text.
- The Foundation Models framework and `SystemLanguageModel` for on-device meeting understanding.
- Guided generation for structured, typed insight updates.

## Requirements

The first release targets:

- macOS 26 or later.
- A Mac that supports Apple Intelligence.
- Apple Intelligence enabled and ready on the device.
- English (US) speech and language-model support; the current M1 composition root uses `en-US` regardless of the Mac's system locale.
- Microphone and screen-capture permissions.

Rio checks these capabilities at runtime and explains unavailable states. The MVP does not use a cloud-model fallback.

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

Development builds must use a stable Apple Development signing identity so macOS can associate microphone permission with the same Rio bundle and signing authority across frequent rebuilds. Copy `Config/Development.xcconfig.example` to `Config/Development.xcconfig`, set `DEVELOPMENT_TEAM` to the team shown in Xcode’s Signing & Capabilities editor, and sign in to Xcode with that Apple Developer account. `make final` automatically uses the local config when present. Do not delete or recreate that identity while testing, because changing the bundle identifier or signing authority legitimately causes macOS to ask again. If no local config exists, the build falls back to Xcode’s ad-hoc “Sign to Run Locally” behavior, which is suitable only for transient builds and may cause TCC to ask again after rebuilds.

`make final` clears the generated `.build/` directory before building, and `make clean` can be used to clear it without rebuilding.

```sh
xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Rio \
  -configuration Debug \
  -destination 'platform=macOS' \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build

xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Rio \
  -configuration Release \
  -destination 'platform=macOS' \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build

xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Rio \
  -configuration Debug \
  -destination 'platform=macOS' \
  test

xcodebuild \
  -project Papagaio.xcodeproj \
  -scheme Rio \
  -configuration Release \
  -destination 'platform=macOS' \
  test
```

The automated M1-10 run on macOS 26.5.2 passed all 68 unit tests in Debug and Release and passed both warnings-as-errors builds. The app also launched and exited cleanly in an idle smoke check. Permission prompts, live microphone speech, SpeechAnalyzer output, Apple Intelligence availability, and the 15-to-30-minute bounded-memory session have not been directly exercised in this environment; they remain required before the M1 exit criterion can be marked complete. Verified progress is tracked in [the roadmap](docs/ROADMAP.md).
