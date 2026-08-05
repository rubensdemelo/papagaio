# Papagaio Roadmap

The repository contains the native M1 implementation through the vertical-slice integration. Milestone 1 remains open until its hardware and long-running validation gates pass.

## Milestone 1: Native vertical slice

Goal: prove the complete Apple-native understanding loop with the smallest possible app.

- Create a macOS 26+ SwiftUI application target.
- Add one start/stop listening control and a clear session status.
- Capture microphone audio for the initial development loop.
- Feed audio to SpeechAnalyzer and SpeechTranscriber.
- Hold finalized text in a bounded, in-memory rolling context.
- Check `SystemLanguageModel` availability and locale support.
- Generate typed insight updates with Foundation Models guided generation.
- Render simple insight cards without displaying transcript text.
- Clear all audio, temporary text, model-session state, and insights when the session ends.
- Add deterministic fixtures and unit tests for context limits and insight update behavior.

Exit criterion: speaking into the Mac produces useful, structured insight cards through an entirely native, on-device pipeline.

### Milestone 1 validation status

Verified on macOS 26.5.2:

- 68 unit tests pass in both Debug and Release configurations.
- Debug and Release builds pass with warnings treated as errors and Swift 6 complete strict-concurrency checking enabled.
- Static privacy scans find no production logging, persistence, or networking APIs.
- The built application launches and exits cleanly without creating meeting-content files; its inspected container contains only window-frame preferences.

Not yet verified:

- Microphone permission grant or denial behavior in the live app.
- Live microphone speech through SpeechAnalyzer, Foundation Models availability, and visible cards.
- Restart, interruption, unsupported-locale, model-unavailable, and stop-during-stage hardware paths.
- The 15-to-30-minute bounded-memory smoke session and Instruments resource-growth inspection.

The Milestone 1 exit criterion is not marked complete until the not-yet-verified checks have direct evidence.

## Milestone 2: Real meeting audio

Goal: make the vertical slice work with actual remote meetings.

- Add system/meeting audio capture with ScreenCaptureKit.
- Capture or combine microphone audio without recording either source.
- Exclude Papagaio's own process audio.
- Add microphone and screen-capture permission onboarding.
- Add source and input-level status without exposing transcript text.
- Handle device changes, selected-source loss, sleep and wake, and permission revocation.
- Test speaker-output duplication and document headphone expectations or add mitigation if needed.

Exit criterion: Papagaio can listen to both sides of a meeting in common conferencing apps and maintain an accurate listening state.

## Milestone 3: Useful live insights

Goal: make the insight stream consistently useful instead of merely functional.

- Tune batching cadence and rolling-context limits.
- Define and evaluate prompts for important points, decisions, actions, questions, and risks.
- Implement stable insight keys, deduplication, updates, and resolution.
- Enforce the rule against guessed action-item owners.
- Cap active cards and prioritize newer or unresolved information.
- Build a small, non-sensitive evaluation corpus from synthetic meeting fixtures.
- Measure time from finalized speech to visible insight.
- Handle model refusal, context overflow, unsupported language, and generation errors.

Exit criterion: representative meeting fixtures produce concise, non-repetitive insights with acceptable latency and no invented owners.

## Milestone 4: Reliability and product polish

Goal: ship a technical preview that behaves predictably for a full meeting.

- Add polished unavailable, permission, listening, processing, interrupted, and stopped states.
- Ensure cancellation and cleanup work from every state.
- Run one-hour capture and insight-generation soak tests.
- Verify bounded audio queues, text context, model context, and card count.
- Confirm that no meeting content is written to logs, caches, crash annotations, or persistent storage.
- Test Apple Intelligence disabled, model assets downloading, unsupported locales, and ineligible hardware.
- Add accessibility, keyboard control, and basic VoiceOver coverage.
- Sign, notarize, and package the macOS app.

Exit criterion: a one-hour meeting completes without unbounded memory growth, silent capture loss, persistent meeting data, or manual recovery from ordinary interruptions.

## Deferred until after the MVP

- Saving or exporting insights.
- Meeting history.
- Cloud or third-party model providers.
- Audio or transcript storage.
- Speaker identification and diarization.
- Accounts, calendars, and integrations.
- Windows and Linux support.
