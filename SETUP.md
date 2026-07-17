# Setup

A from-scratch guide to running TypeWiser. The only hard requirement is a build
of the app itself; **speech-to-text works out of the box** (Apple on-device), and
the text-cleanup engine is your choice of Cloud (Bedrock) or a local llama.cpp
server.

## 1. Prerequisites

- macOS 15 or later.
- A Swift 6.2 toolchain (Xcode 16+ or the matching Swift release).

## 2. Build and sign

```bash
./Scripts/create-signing-cert.sh   # once: creates a stable "TypeWiser Dev" identity
./Scripts/bundle-app.sh            # builds build/TypeWiser.app and signs it
open build/TypeWiser.app
```

A signed `.app` bundle is required (not a bare `swift run`): macOS ties
Accessibility and Microphone grants to a bundle ID + stable signature. See the
[README](README.md#setup) for why the signing cert matters and how to recover
from a stale-permission entry.

## 3. Permissions

On first launch, grant these when prompted (or in System Settings → Privacy &
Security):

- **Accessibility** — required. Without it the 🌐 hotkey is never observed and
  the paste keystroke is dropped.
- **Microphone** — required to record.
- **Speech Recognition** — required for the default on-device transcription.

Also set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**, so the
emoji picker doesn't open every time you dictate.

## 4. Speech-to-text (STT)

Settings → **Engine** → *Transcribe with*:

- **Apple (on-device)** — the default. No setup, no downloads, fully offline
  after macOS finishes provisioning the speech model on first use. Audio never
  leaves the machine.
- **Remote whisper.cpp** — post audio to a whisper.cpp server's `/inference`
  endpoint that you host. Enter its URL in the field that appears. Audio is
  uploaded to that server.

## 5. Text cleanup engine

Cleanup (filler removal, grammar, name spelling) runs on an LLM. Pick the mode in
the menu bar.

### Option A — Cloud (Bedrock, OpenAI, or Anthropic)

No local model needed. In Settings → **Cloud**, pick a provider and enter its
credentials (stored in the macOS Keychain, never a file):

- **AWS Bedrock** — Access Key ID + Secret Access Key. Region `ap-south-1`,
  model `apac.amazon.nova-lite-v1:0`.
- **OpenAI** — an API key (`sk-…`). Model is configurable; defaults to a small,
  fast chat model.
- **Anthropic** — an API key (`sk-ant-…`). Model is configurable; defaults to
  Claude Haiku 4.5.

Cleanup is a short, mechanical edit, so the small/fast default model on each
provider is the right choice for latency and cost. Bump it to a larger model in
Settings if you want. Changing provider or model takes effect immediately (the
rewriter is chosen per dictation).

### Option B — Local (llama.cpp)

Runs entirely on your Mac; nothing is sent to the cloud. You provide a
`llama-server` binary and a GGUF model, then point Settings → **Engine** at them.

1. **Build llama.cpp** (Metal enabled) — see the
   [llama.cpp](https://github.com/ggml-org/llama.cpp) build docs. You need the
   `llama-server` binary.

2. **Download a GGUF model.** The default configuration expects a Gemma GGUF and,
   optionally, a smaller *draft* model for speculative decoding. Any GGUF
   `llama-server` can load will work — pick one sized for your RAM (the default
   26B holds ~17 GB while active; smaller models are lighter). Hugging Face repos
   such as [unsloth](https://huggingface.co/unsloth) publish ready-made GGUFs.

3. **Set the paths** in Settings → Engine:
   - **Binary** — path to `llama-server`.
   - **Model** — path to the main `.gguf`.
   - **Draft model** — path to the draft `.gguf` (optional; leave as-is if you
     aren't using speculative decoding, or point it at a small model).

   The defaults assume a `~/Models/Local` layout:

   ```
   ~/Models/Local/repos/llama.cpp/build/bin/llama-server
   ~/Models/Local/models/<repo>/<model>.gguf
   ~/Models/Local/models/<repo>/MTP/<draft>.gguf
   ```

4. **Restart TypeWiser.** Engine paths and the STT source are read at launch, so
   changes take effect on the next start. Select **Local** in the menu bar;
   `llama-server` spawns on port 8231 and the menu bar shows when it's ready.

## Troubleshooting

- **"model not found at …"** — the Model path in Settings → Engine doesn't point
  at an existing `.gguf`. Fix the path and restart.
- **Dictation transcribes nothing (Apple mode)** — confirm Speech Recognition is
  allowed in System Settings, and that the on-device model finished downloading
  (first use can take a moment on a fresh macOS install).
- **Local engine never becomes ready** — check the binary path and that
  `llama-server` runs on its own from a terminal with the same model.
