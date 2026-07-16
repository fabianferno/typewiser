# TypeWiser

Hold 🌐, speak, release. Cleaned-up text appears in whatever app has focus.

Speech-to-text runs on a self-hosted whisper.cpp server. Cleanup — filler removal,
grammar, self-correction resolution, name spelling — runs on an LLM, either locally
or on AWS Bedrock.

## Build

```bash
./Scripts/bundle-app.sh
open build/TypeWiser.app
```

`bundle-app.sh` builds a release binary, assembles `build/TypeWiser.app`, and
ad-hoc signs it. A `.app` bundle is required, not optional: macOS ties
Accessibility and Microphone permission grants to a bundle ID plus a stable
signature, which a bare `swift run` binary does not have — TCC will not
persist a grant for it across relaunches.

## Setup

1. **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.** Otherwise
   the emoji picker opens every time you dictate instead of TypeWiser seeing
   the key. The app's Setup tab checks this for you by reading the
   `AppleFnUsageType` key from `com.apple.HIToolbox` and shows a pass/fail
   indicator — it does not just take your word for it.
2. Grant Accessibility and Microphone when prompted.
3. For Cloud mode, add AWS credentials in Settings → Cloud. They are stored in
   the macOS Keychain (service `xyz.crevn.typewiser`) and are never written to
   UserDefaults, a plist, a dotfile, or this repo. **Cloud mode requires this
   step** — switching to Cloud immediately kills the local `llama-server`, so
   without saved credentials there is no rewriter to fall back to. The menu
   bar says so plainly (`Cloud · no credentials — add them in Settings`
   instead of the model name) and the HUD adds a note on every dictation;
   your words are never lost either way — they're just pasted raw, unedited,
   until credentials are added.

## Engine modes

- **Local** spawns `llama-server` on port `8231` running Gemma 26B A4B
  (`-c 4096`, speculative decoding via a draft model, no `--mmproj`). Model
  load takes 10–30s and holds ~17GB of RAM plus the GPU while active.
- **Cloud** kills the local `llama-server` process — reclaiming that RAM and
  GPU — and rewrites via Bedrock, model `apac.amazon.nova-lite-v1:0` in
  `ap-south-1`, signed with SigV4.
- Switching modes in the menu bar tears down or spawns the process
  immediately; it isn't lazy.
- If the app is force-quit or crashes while `llama-server` is running, the
  next launch (and a normal quit) reap it via a pidfile that records the
  child's pid, start time, and port. The kill only fires when the live
  process's start time still matches exactly what was recorded at spawn —
  pid reuse can't fool it — so a leaked 17GB process from a crash gets
  cleaned up, but a `llama-server` some other tool launched never does.

## Known latency

The whisper.cpp server has exactly one inference slot and a ~3.5s fixed
round-trip latency, regardless of clip length — it pads every request to a
30s mel window internally. Text therefore appears roughly 3–5s after you stop
speaking, and the interim HUD text trails your voice by about the same
amount. This is a property of the server, not the client: three concurrent
requests measured 9.5s total (fully serialized, not parallel), confirming the
single slot. The fix would be server-side — a smaller model, or a
VAD-segmented streaming endpoint — not anything the client can paper over.

## Degradation, not data loss

- **Rewriter failure** (network error, timeout, non-200, unparseable
  response) → the raw transcript is pasted instead of the cleaned-up text.
  Your words are never dropped, only left unpolished.
- **Implausible rewrite** — if the model returns something that isn't
  recognizably derived from what you said (a safety refusal, or it answers a
  dictated question instead of cleaning it up), that output is discarded and
  the raw transcript is used instead. This is a token-grounding check: output
  tokens are compared against the transcript's token set, and outputs that
  share too few words with the input are rejected as non-rewrites rather than
  pasted verbatim.
- **Whisper transcription failure** → the HUD shows an error and nothing is
  pasted or typed. There's no transcript to fall back to at that point.

## Tests

```bash
swift test                                                  # 120 tests, 5 suites, no network/Keychain/model deps
TYPEWISER_INTEGRATION=1 swift test --filter wavEncoderRoundTripIsAcceptedByRealServer  # opt-in: real whisper.cpp server, needs `say`+`ffmpeg`
TYPEWISER_GOLDEN_LOCAL=1 swift test --filter goldenLocal    # opt-in: needs llama-server up on :8231
TYPEWISER_GOLDEN_BEDROCK=1 swift test --filter goldenBedrock  # opt-in: hits real Bedrock, costs money, creds from Keychain or env
TYPEWISER_BEDROCK_LIVE=1 AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... swift test --filter liveBedrockRewriteAgainstRealAWS  # opt-in: real Bedrock call, creds from env only
```

Plain `swift test` never touches the network, the Keychain, or a real model —
everything opt-in is gated behind an env var so CI and casual runs stay fast
and free.

## Manual QA

Some behavior can only be checked by a human with a microphone driving the
real GUI (focus stealing, HUD timing, actually speaking into TextEdit/Slack).
See [`docs/manual-qa.md`](docs/manual-qa.md) for the checklist.

## Docs

- Design: [`docs/superpowers/specs/2026-07-16-typewiser-design.md`](docs/superpowers/specs/2026-07-16-typewiser-design.md)
- Plan: [`docs/superpowers/plans/2026-07-16-typewiser.md`](docs/superpowers/plans/2026-07-16-typewiser.md)
