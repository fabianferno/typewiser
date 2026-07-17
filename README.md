# TypeWiser

Hold 🌐, speak, release. Cleaned-up text appears in whatever app has focus.

Speech-to-text runs **on-device** by default via Apple's Speech framework — no
server, no model download, and audio never leaves your Mac. You can instead point
it at a self-hosted whisper.cpp server (Settings → Engine). Cleanup — filler
removal, grammar, self-correction resolution, name spelling — runs on an LLM,
either locally (llama.cpp) or on AWS Bedrock.

New here? See [`SETUP.md`](SETUP.md) for a from-scratch walkthrough, including the
optional local llama.cpp rewrite engine.

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

The app icon is committed as both its 1024×1024 master (`Resources/AppIcon.png`)
and the rendered `Resources/AppIcon.icns` that `bundle-app.sh` copies in, so a
normal build needs no image tooling. If you change the master, re-render with
`./Scripts/make-icon.sh`. macOS aggressively caches icons — if the Dock or
Finder still shows the old one after a rebuild, that's the cache, not the
bundle; check with `Get Info` on `build/TypeWiser.app`.

## Setup

**Run this once**, before your first build:

```bash
./Scripts/create-signing-cert.sh   # creates a stable "TypeWiser Dev" signing identity
./Scripts/bundle-app.sh
open build/TypeWiser.app
```

Why: macOS ties Accessibility permission to the code signature. An ad-hoc
signature is identified by a hash of the exact binary, so **every rebuild would
silently void your granted permission** — System Settings keeps showing the
checkbox ON while the app is untrusted. The certificate makes the grant stick.

Then:

1. **Grant Accessibility** when prompted. Without it, dictation is disabled
   entirely: the 🌐 key is never observed, and the ⌘V used to paste your text
   is silently dropped.
2. **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.** Otherwise
   the emoji picker opens every time you dictate.
3. For Cloud mode, add AWS credentials in Settings → Cloud (stored in your
   macOS Keychain).

### If the app says permission is missing after you granted it

You almost certainly have a stale entry bound to an older binary. Toggling it
off/on will NOT help — it re-grants a binary that no longer exists:

```bash
tccutil reset Accessibility xyz.crevn.typewiser
open build/TypeWiser.app     # grant again when prompted
```

This should not recur once you're signing with the certificate above.

## Engine modes

- **Local** spawns `llama-server` on port `8231` running Gemma 26B A4B
  (`-c 4096`, speculative decoding via a draft model, no `--mmproj`). Model
  load takes 10–30s and holds ~17GB of RAM plus the GPU while active. The
  binary and model paths default to a `~/Models/Local` layout and are
  configurable in Settings → Engine — see [`SETUP.md`](SETUP.md).
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

Applies to the **remote whisper.cpp** STT source only — Apple on-device
transcription does not have this round-trip.

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
swift test                                                  # 128 tests, 5 suites, no network/Keychain/model deps
TYPEWISER_INTEGRATION=1 swift test --filter wavEncoderRoundTripIsAcceptedByRealServer  # opt-in: real whisper.cpp server (set TYPEWISER_WHISPER_ENDPOINT, defaults to localhost:8080), needs `say`+`ffmpeg`
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

- Setup (from scratch): [`SETUP.md`](SETUP.md)
- Manual QA checklist: [`docs/manual-qa.md`](docs/manual-qa.md)

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
