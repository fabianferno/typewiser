# TypeWiser — Design

**Date:** 2026-07-16
**Status:** Approved

## Summary

TypeWiser is a native macOS menu-bar app for system-wide dictation. Hold the 🌐 (Fn)
key, speak, release — cleaned-up text is inserted at the cursor of whatever app has
focus: browser, chat window, editor, or terminal.

Speech-to-text runs against a self-hosted `whisper.cpp` server at
`https://whisper.crevn.xyz`. Text cleanup (filler removal, grammar, self-correction
resolution, name spelling) runs against an LLM — either a locally-spawned
`llama-server` or AWS Bedrock, switchable from the menu bar.

## Measured Constraints

These were verified against the live server on 2026-07-16 and drive the whole design.

| Finding | Evidence | Consequence |
|---|---|---|
| Server is `whisper.cpp`'s built-in HTTP server | Only `/inference` (multipart) and `/load` exist. No `/docs`, no `/openapi.json`, no WebSocket. | No server-side streaming. Pseudo-streaming must be built client-side. |
| ~3.5s fixed latency per request | A 7.5s clip and a 2s clip both took ~3.5s round-trip. | Latency is dominated by network + whisper.cpp's 30s mel-window padding. Smaller chunks do **not** reduce lag. Letter-by-letter realtime typing is impossible. |
| Exactly one inference slot | 3 parallel requests took 9.5s total (~3.2s each, serialized). | Interim requests must be strictly single-flight. A fixed-interval timer would queue and fall progressively further behind. |
| Whisper already drops non-lexical fillers | `"...two, um, actually three..."` → `" Let's meet at two, actually three tomorrow afternoon."` | Filler removal is partly free. **Self-correction is not** — "two, actually three" survived. That requires the LLM. |

**Whisper cannot do any of the requested cleanup features.** It is an acoustic model;
it transcribes what it hears. Filler removal, grammar repair, repetition removal,
self-correction resolution, and context-aware name spelling are all text-rewriting
tasks requiring a language model reading the transcript.

## Architecture

Native Swift/SwiftUI. `LSUIElement` (menu bar only, no Dock icon). Electron was
rejected: it cannot install a CGEventTap, read the Accessibility API, or capture
audio at the required latency.

**Permissions required:** Accessibility (hotkey capture + context reading + paste
synthesis), Microphone.

### Pipeline

```
Hold 🌐
  └─ AudioCapture ──> PCM buffer (16kHz mono) ──> RMS ──> HUD waveform
        │
        ├─ (while held) WhisperClient: re-transcribe buffer-so-far,
        │               single-flight, next fires when previous returns
        │               └──> interim text ──> HUD
        │
Release 🌐
  ├─ cancel any in-flight interim request
  ├─ WhisperClient: final /inference on complete utterance
  ├─ ContextReader: surrounding text via AX API + name dictionary
  ├─ Rewriter: LLM cleanup (Local llama-server | Bedrock)
  └─ TextInjector: clipboard save → set → ⌘V → restore
```

### Components

Each has one purpose, a defined interface, and is testable in isolation.

| Component | Responsibility | Key dependency |
|---|---|---|
| `HotkeyMonitor` | Fn down/up detection, 150ms debounce, no-other-key guard | `NSEvent.flagsChanged` |
| `AudioCapture` | Mic → 16kHz mono PCM buffer; live RMS for waveform | `AVAudioEngine` |
| `WhisperClient` | Multipart POST to `/inference`; single-flight; cancellable | `URLSession` |
| `ContextReader` | Focused element's surrounding text + frontmost app name | `AXUIElement` |
| `Rewriter` | Protocol. Impls: `LocalLlamaRewriter`, `BedrockRewriter` | — |
| `EngineManager` | Spawn/kill `llama-server` child process; health-check | `Process` |
| `TextInjector` | Clipboard save → set → synthesize ⌘V → restore | `CGEvent` |
| `HUD` | Non-activating floating panel: waveform, timer, interim text | `NSPanel` |
| `SettingsStore` | Cleanup-rule toggles, hotkey, name dictionary | `UserDefaults` |
| `CredentialStore` | AWS creds | macOS Keychain |

### Hotkey: 🌐 / Fn

Detected via `flagsChanged` monitoring `.function`. Two guards prevent misfires:

1. **150ms minimum hold** — a quick tap does nothing.
2. **No-other-key guard** — Fn+F5 and arrow keys also set `.function`. A recording
   only starts if Fn is held alone.

**Onboarding must instruct:** System Settings → Keyboard → "Press 🌐 key to" →
**Do Nothing**. macOS binds Fn to dictation and the emoji picker by default; without
this, the app fights the OS.

### Interim transcription loop

While the key is held, the HUD is populated by re-transcribing the growing audio
buffer. Because the server has one slot and ~3.5s latency:

- **Strictly one request in flight.** Never fire on a timer.
- **Adaptive cadence.** The next chunk is sent the moment the previous returns.
  Realistic refresh is therefore ~3.5s, not faster.
- **Release wins.** On release, any in-flight interim is cancelled immediately so
  the final request is not stuck behind it.

Interim text lags ~3.5s behind speech and earlier words may shift as context grows.
This is expected and acceptable — the interim is advisory. The authoritative text
comes from the final full-utterance pass, which is also more accurate (full context
in one pass).

### Commit model

Nothing enters the focused app until the key is released. This was a deliberate
choice over draft-then-revise:

- No synthesized backspaces, which can fire into a terminal's shell history or send
  a half-finished Slack message.
- No fighting browser/editor autocomplete.
- Self-correction resolution requires the complete sentence anyway, so incremental
  commit could not deliver the headline feature regardless.

**Insertion method: clipboard paste.** Save the pasteboard → set our text →
synthesize ⌘V → restore the pasteboard. This is the only method that works reliably
everywhere including Terminal and Electron apps. Unicode keystroke synthesis was
rejected: slow on long text, and broken in some apps.

### Local ⇄ Cloud toggle

A segmented control in the menu bar. This is the user's compute on/off switch.

**Local** spawns `llama-server` as a child process:

```
/Users/fabianferno/Models/Local/repos/llama.cpp/build/bin/llama-server \
  -m /Users/fabianferno/Models/Local/models/unsloth-gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf \
  --model-draft /Users/fabianferno/Models/Local/models/unsloth-gemma-4-26B-A4B-it-GGUF/MTP/gemma-4-26B-A4B-it-Q8_0-MTP.gguf \
  --spec-type draft-mtp --spec-draft-n-max 3 \
  -ngl 999 -fa on -c 4096 --parallel 1 \
  --host 127.0.0.1 --port 8231
```

Deviations from the user's reference command, all deliberate:

- **Port 8231, not 8080** — 8080 is commonly occupied; 8231–8233 verified free.
- **`--mmproj` dropped** — that is the vision projector. We do text-only rewriting.
  Saves ~1.2GB.
- **`-c 4096`, not 65536** — our prompt is one short utterance plus a little
  context. Saves several GB of KV cache.

Model paths verified present (Gemma GGUF is 17GB; MTP draft 462MB).

**Switching to Cloud kills the child process**, reclaiming RAM and GPU. The server
is also killed on app termination. Cloud routes to Bedrock
`apac.amazon.nova-lite-v1:0` in `ap-south-1` via SigV4.

**Credentials live in the macOS Keychain**, entered once in Settings. They are never
written to the repo, a dotfile, or a plist. `.gitignore` covers `.env` and
`credentials`.

> **Security note:** the AWS credentials were shared in plaintext chat during design
> and should be rotated.

### Cleanup rules

Each is a Settings toggle, composed into one system prompt sent with the transcript.
The prompt is hard-constrained: rewrite only, never answer the content, never add
information, return text only.

| Toggle | Behaviour |
|---|---|
| Remove fillers | Drop um, uh, hmm and other non-lexical sounds |
| Fix grammar | Repair agreement, tense, punctuation |
| Remove repetition | Collapse stutters and restarts |
| Resolve self-corrections | "meet at 2… actually 3" → "meet at 3" |
| Context-aware spelling | Use surrounding text + name dictionary for proper nouns |

Context for the last rule comes from `ContextReader`: the focused element's
surrounding text via the AX API, the frontmost app's name, and a user-defined name
dictionary in Settings.

### Error handling

Every stage fails soft. The guiding rule: **never lose the user's words.**

| Failure | Behaviour |
|---|---|
| Whisper unreachable / times out | HUD shows the error. Nothing is pasted. |
| Rewriter unreachable or exceeds 2s timeout | **Paste the raw Whisper transcript.** Degraded, not lost. |
| `llama-server` fails to start | Fall back to Cloud, notify in HUD. |
| No Accessibility permission | HUD explains and deep-links to the settings pane. |
| No Microphone permission | HUD explains and deep-links to the settings pane. |
| Clipboard restore fails | Log; do not block the paste. |

### Testing

Components are protocol-backed, so `WhisperClient` and `Rewriter` are faked in unit
tests.

- **`Rewriter` golden-file suite** — a table of messy-input → expected-clean-output
  cases, run against both Local and Bedrock. Includes the "2… actually 3" case.
  Prompt regressions are the likeliest thing to silently break, so this suite is the
  highest-value test in the project.
- **`HotkeyMonitor`** — synthetic `flagsChanged` events assert the debounce and the
  no-other-key guard.
- **`WhisperClient`** — asserts single-flight invariant and cancel-on-release.
- **`TextInjector`** — asserts clipboard save/restore round-trip.

## Out of Scope (v1)

Deferred to keep v1 shippable:

- Code signing / notarization (local dev build only)
- Auto-update
- Custom vocabulary training
- Multi-language support
- Dictation history / transcript log
- Draft-then-revise commit mode

## Open Risks

1. **~3.5s latency is inherent to the current server.** If it proves unacceptable in
   daily use, the fix is server-side (a smaller model, or a VAD-segmented streaming
   endpoint), not client-side. The client cannot engineer around a fixed floor.
2. **Fn detection depends on the user disabling the OS binding.** If onboarding is
   skipped, the emoji picker will appear on every dictation. Onboarding should
   verify the setting rather than merely instruct.
3. **The AX API returns nothing in some apps** (notably some Electron and Java apps),
   which silently degrades context-aware spelling to the name dictionary alone.
