# Papagaio Product Definition

## Purpose

Papagaio is a macOS app for live meeting insights. It listens to microphone and meeting audio and surfaces the information a user is likely to need while the conversation is still happening.

The insight stream is the product. Audio capture and speech-to-text are temporary implementation stages, not user-facing features.

## Audience

Papagaio is for people who want to stay engaged in meetings without operating a recorder, reading a transcript, or taking continuous notes. The first release is a focused technical preview for macOS 26+ on Macs that support Apple Intelligence.

It is not an enterprise recording platform, collaboration workspace, or meeting archive.

## Core experience

The app opens to one clear listening control and a small status indicator.

When the user starts listening:

1. Papagaio captures system/meeting audio and microphone audio.
2. Apple's Speech framework converts the live audio into temporary finalized text.
3. A bounded rolling text window is sent to Apple's on-device system language model.
4. The model returns structured insight updates.
5. The UI adds, updates, or removes insight cards as the meeting develops.

The app does not display a live transcript. Temporary transcript text is discarded as it leaves the rolling context window and is discarded completely when listening stops.

## Insight categories

The MVP surfaces:

- Important points and takeaways.
- Decisions.
- Action items.
- Open questions.
- Risks, blockers, and unresolved topics.

Each card contains a concise statement, its category, and a simple state such as new, updated, or resolved. Evidence text and transcript navigation are not required for the MVP.

Papagaio must not guess an action-item owner. It may include an owner only when the temporary meeting text explicitly names one; otherwise the owner remains unspecified.

## Apple Intelligence

The MVP uses the Foundation Models framework to access the on-device system language model that powers Apple Intelligence. Insight responses use guided generation to produce typed Swift values rather than free-form text that the app must parse.

Before listening begins, Papagaio checks whether the system language model is available and whether the meeting language is supported. Apple Intelligence may be unavailable because the Mac is ineligible, the feature is disabled, required assets are not ready, or the locale is unsupported. The MVP explains the condition and does not offer a cloud-model fallback.

Speech recognition is a separate native stage. SpeechAnalyzer and SpeechTranscriber perform on-device speech-to-text suitable for meetings; Foundation Models then interprets that temporary text.

## Data lifecycle

- Audio remains in memory only long enough to feed speech recognition.
- Audio is never intentionally written to disk.
- Finalized transcript segments live in a bounded rolling context window.
- Old text is continuously discarded.
- All temporary meeting text is discarded when listening stops.
- Current insight cards are session-only and disappear when the session ends unless a later product decision adds explicit insight export.
- No audio, transcript text, insight text, or secrets may appear in logs.

## Explicit exclusions

- Visible live transcription or transcript editing.
- Note-taking and document editing.
- Audio recording, playback, or persistent audio storage.
- Transcript export, automatic meeting history, or searchable archives.
- Meeting bots or joining calls on the user's behalf.
- Speaker identification, diarization, or guessed speaker ownership.
- OpenAI or another cloud-model fallback in the MVP.
- Accounts, calendars, CRM integrations, team workspaces, or cloud synchronization.
- Generic assistant chat, unrelated recommendations, or autonomous actions.
- Windows and Linux support in the MVP.

## Success criteria

The MVP is successful when:

1. A user can start and stop listening with one obvious action.
2. The app captures microphone and system audio from a real meeting after a clear permission flow.
3. Useful insight cards begin appearing during the meeting without exposing a transcript.
4. Duplicate insights are merged and changed conclusions update or replace stale cards.
5. An action-item owner is never inferred without explicit support in the temporary text.
6. Stopping listening promptly releases capture resources and clears temporary audio and text.
7. A one-hour meeting completes without deadlock, unrecovered capture failure, or unbounded memory growth.
8. The app clearly reports unavailable Apple Intelligence, unsupported language, denied permission, and interrupted capture states.
9. No meeting content is persisted or logged unintentionally.
