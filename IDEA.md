# Papagaio

Papagaio is a deliberately simple macOS app that listens to a meeting and surfaces useful insights while the conversation is still happening.

## Product promise

Start listening, stay engaged in the meeting, and see the important points as they emerge.

Papagaio is not a transcription or note-taking app. Speech-to-text exists only as temporary input for understanding the meeting. The live transcript is not a product surface, and neither audio nor transcript text is retained after it is no longer needed for insight generation.

## MVP

The first release targets macOS 26+ on Macs that support Apple Intelligence.

Papagaio uses native Apple technologies:

- ScreenCaptureKit for meeting/system audio and microphone capture.
- SpeechAnalyzer and SpeechTranscriber for temporary, on-device speech-to-text.
- The Foundation Models framework and its system language model for on-device meeting understanding.
- SwiftUI for a small native interface.

The interface has one primary action: start or stop listening. While listening, it displays a changing stream of concise insights:

- Important points.
- Decisions.
- Action items, without guessing an owner.
- Open questions.
- Risks, blockers, and unresolved topics.

Insights should update or replace earlier cards as the meeting develops instead of repeating the same information.

## Data lifecycle

Audio is processed as a live stream and is not recorded to a file. Speech-to-text output is held only in a bounded, rolling context window. The app continuously discards audio buffers and transcript text that are no longer needed.

Current insight cards may remain visible until the user stops the meeting or closes the window. The MVP does not create an automatic meeting archive.

## Explicit exclusions

- A visible live transcript.
- A note-taking editor.
- Audio recording or playback.
- Transcript export or meeting history.
- Meeting bots or joining calls on the user's behalf.
- Speaker identification or diarization.
- Accounts, calendars, CRM integrations, or team workspaces.
- Cloud synchronization.
- Assistant chat or autonomous follow-up actions.
- Windows and Linux support in the first release.

## Engineering priority

First prove one complete native loop on supported Macs: capture a real meeting, derive temporary text, generate useful Apple Intelligence insights, and run reliably for a full meeting with bounded memory and no persistent meeting data.
