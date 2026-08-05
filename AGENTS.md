# AGENTS.md

## Project goal

Papagaio is a deliberately simple macOS app that listens to meetings and shows useful live insights. The insight stream is the product.

Audio capture and speech-to-text are temporary implementation stages. Papagaio is not a transcription app, note-taking app, meeting recorder, or meeting archive.

Read these documents before changing product behavior or architecture:

- `IDEA.md`
- `docs/PRODUCT.md`
- `docs/ARCHITECTURE.md`
- `docs/ROADMAP.md`

When documents conflict, `docs/PRODUCT.md` defines product behavior and `docs/ARCHITECTURE.md` defines the current technical direction. Update the relevant documents in the same change whenever a product or architecture decision changes.

## MVP boundaries

The first MVP:

- Targets macOS 26+ on Macs that support Apple Intelligence.
- Uses native Swift and SwiftUI.
- Uses ScreenCaptureKit for meeting/system audio and microphone capture where supported.
- Uses SpeechAnalyzer and SpeechTranscriber for temporary on-device speech-to-text.
- Uses the Foundation Models framework and `SystemLanguageModel` for meeting understanding.
- Shows concise live insight cards.
- Keeps audio, temporary text, model sessions, and insights in memory only for the active session.

Do not add the following without an explicit product decision and matching documentation update:

- A visible transcript or transcript editor.
- Note-taking features.
- Audio recording, playback, or persistent audio storage.
- Transcript export, meeting history, or a database.
- OpenAI or another cloud inference provider.
- Accounts, calendars, CRM integrations, team workspaces, or cloud synchronization.
- Speaker identification or diarization.
- A Rust core, C ABI, or cross-platform abstraction.
- Windows or Linux support.

## Product behavior

Keep the interaction small and obvious:

- One primary start/stop listening action.
- A clear listening, processing, interrupted, unavailable, or stopped status.
- Insight cards for important points, decisions, actions, questions, and risks.
- Existing cards update or resolve instead of accumulating duplicates.
- Never infer an action-item owner. Include an owner only when the temporary meeting text explicitly names one.
- Do not expose temporary transcript text in the interface.

Prefer removing complexity over adding configuration. New controls and settings need a concrete MVP requirement.

## Architecture rules

- Keep the MVP as a native Swift application unless a documented requirement proves that insufficient.
- Keep capture, speech recognition, context management, insight generation, and UI state behind separate interfaces.
- Keep audio callbacks minimal. Do not perform file I/O, model requests, UI work, allocation-heavy processing, or blocking synchronization in a capture callback.
- Use structured concurrency and propagate session cancellation through the entire pipeline.
- Serialize context batching and insight generation so model requests cannot race.
- Apply SwiftUI state changes on the main actor.
- Use Foundation Models guided generation with `@Generable` types for insight output.
- Put developer-authored rules in model instructions and untrusted meeting text in prompts.
- Validate generated output before applying it to UI state.
- Check speech-model, language-model, locale, asset, hardware, and permission availability explicitly.
- Represent expected unavailable states in the UI instead of treating them as generic errors.

## Data lifecycle and privacy

All meeting data is ephemeral for the MVP:

- Never intentionally write audio to disk.
- Keep audio queues bounded by duration or frame count.
- Feed only finalized speech results into the insight context.
- Keep temporary text bounded by age and model token budget.
- Bound the number of active insight cards.
- Clear capture buffers, temporary text, language-model sessions, and insight state when listening stops.
- Perform the same cleanup after errors and cancellation.
- Never include audio, transcript text, insight text, prompts containing meeting content, or secrets in logs, analytics, crash annotations, fixtures, or snapshots.

Diagnostics may contain non-content metadata such as timing, queue depth, availability state, and error codes.

## Dependencies

Prefer Apple SDK frameworks and the standard library. Add a third-party dependency only when it materially reduces risk or complexity and the same result is not reasonably available from the platform.

Document why each dependency is needed. Avoid dependencies for basic state management, networking, logging, or UI utilities.

## Testing and verification

Every implementation change should be verified in proportion to its risk.

Prioritize tests for:

- Rolling-context age, size, and token limits.
- Insight parsing, validation, deduplication, updates, and resolution.
- The rule against guessed action-item owners.
- Session cancellation and cleanup from every state.
- Permission denial and unavailable speech or language models.
- Bounded queues and overload behavior.
- Recovery from capture interruption and device changes.

Use synthetic meeting text and generated audio fixtures. Do not add real meeting content to the repository.

Before considering a milestone complete:

- Run relevant unit and integration tests.
- Build the macOS target with warnings treated seriously.
- Exercise start, stop, restart, denial, interruption, and model-unavailable paths.
- Confirm that no meeting content was persisted or logged.
- Update `docs/ROADMAP.md` to reflect verified work only.

Hardware-dependent capture and one-hour soak tests must be identified clearly when they cannot run in automated environments.

## Change discipline

- Keep changes focused on the current roadmap milestone.
- Do not claim unimplemented or unverified work as complete.
- Preserve the simple product boundary when proposing abstractions or future-proofing.
- Add comments for non-obvious constraints and decisions, not line-by-line narration.
- Keep user-facing language concise and avoid calling the temporary speech-to-text pipeline a product feature.
