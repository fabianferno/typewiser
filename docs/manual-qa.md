# Manual QA checklist

Everything below requires a human: a real microphone, real speech, and driving
the real GUI. None of it can be exercised by an automated agent or by
`swift test` — there is no substitute for actually holding 🌐 and talking.

Before starting: `./Scripts/bundle-app.sh && open build/TypeWiser.app`.

For rows involving Local mode, give the model 10–30s to finish loading after
switching (menu bar shows "Loading model…" then "ready"). For rows involving
Cloud mode, valid AWS credentials must already be saved in Settings → Cloud.

## Checklist

| # | Action | Expected outcome | Pass/Fail |
|---|---|---|---|
| 1 | Open TextEdit, click into the document, hold 🌐, say "let's meet at two, um, actually three", release | Cleaned-up text appears — self-correction resolved to "three", no "um" survives |
| 2 | Hold 🌐 for about 6 seconds while watching the HUD | Interim text appears roughly 3.5s in (see "Known latency" in the README); TextEdit keeps keyboard focus the entire time — the HUD never steals it |
| 3 | Copy the literal text `SENTINEL` to the clipboard, then dictate something into TextEdit, then press ⌘V | `SENTINEL` pastes — proves the original clipboard contents were saved before the dictated text was pasted and restored afterward |
| 4 | Dictate into a Terminal prompt | The dictated text lands at the prompt as typed characters; no stray keystrokes leak in and nothing gets executed |
| 5 | Dictate into a Slack (or other Electron app) message composer | Text lands in the compose box, unsent |
| 6 | Tap 🌐 briefly — well under 150ms — and release | Nothing happens: no HUD, no recording starts. (This is the debounce guard in `HotkeyStateMachine`, unit-tested with synthetic timestamps but not provable against a real keyboard driver without a human's tap.) |
| 7 | Press 🌐+F5 (or another 🌐+key combo) | Nothing happens — holding another key alongside 🌐 must not trigger dictation |
| 8 | With the app in Local mode, switch to Cloud via the menu bar | `llama-server` disappears from `ps` (check with `pgrep -fl llama-server`); dictation still works, now via Bedrock |
| 9 | With the app in Cloud mode, switch to Local via the menu bar | Status shows "Loading model…" then "ready"; dictation works once ready |
| 10 | In Local mode, kill `llama-server` manually (`pkill -f llama-server`), then dictate | The raw transcript is inserted, not lost — this exercises the rewriter-failure fallback in `DictationSession.end()` against a real dead server rather than a mock |
| 11 | Quit the app (menu bar → Quit) | `pgrep -f llama-server` returns nothing — the child process is torn down on quit, not left running |

Verify rows 8 and 11 with:

```bash
pgrep -fl llama-server
```

## Why these can't be automated here

This assistant has no microphone and cannot drive the macOS GUI (click into
apps, hold a key, watch a HUD render). Anything in this list that depends on
those was **not** run by the assistant and must be walked by a human before
treating Task 19 as fully closed. Do not treat an unchecked box as a pass.

## What the assistant verified instead (no fabrication)

These are process- and build-level checks that don't require a microphone or
GUI interaction, and were actually run as part of this task:

- `swift test`: 119 tests, 5 suites, all green, plain invocation (no
  `--no-parallel`).
- `pgrep -fl llama-server` returned nothing before the test run and nothing
  after — the opt-in golden/integration tests are gated behind env vars and
  plain `swift test` never spawns the server.
- `./Scripts/bundle-app.sh` succeeds; `build/TypeWiser.app` builds and
  ad-hoc signs with `Identifier=xyz.crevn.typewiser` (checked via
  `codesign -dv`).
- `defaults read com.apple.HIToolbox AppleFnUsageType` on this machine
  returns "does not exist" — i.e. genuinely unset, not merely `0`. The
  Setup tab's check (`fnUsage == 0`) will correctly show this as **not**
  satisfied, so whoever runs the manual matrix on this machine will need to
  change the System Settings binding first or the HUD checklist item won't
  reflect a real pass.

Everything else above — rows 1 through 11 in the table — requires a human.

## Regression checks (found the hard way in real use)

These are here because each one shipped as a real bug that no automated test
could catch — they only exist in the gap between real permissions and a real GUI.

- [ ] **With Accessibility GRANTED, the menu bar icon still opens its panel.**
      This is the row that matters most, and the one whose absence let the bug
      below ship twice. Registering `NSEvent.addGlobalMonitorForEvents` — for
      any event type, even with an empty handler — silently stops the
      `MenuBarExtra(.window)` popover from opening. It was first diagnosed as an
      *untrusted-only* problem, but that was an artifact of only ever testing
      the untrusted path, which is the one where the monitors are never
      registered. On the trusted path the monitors do register and the popover
      is just as dead — locking the user out of the app's only UI. Key events
      now come from a listen-only `CGEventTap` instead
      (`hotkeyMonitorNeverUsesNSEventGlobalMonitors` guards the source).
      **Both halves must pass in the same run, while trusted:** the icon opens
      its panel, AND holding 🌐 still dictates. Either alone is what a
      half-verified fix looks like.
- [ ] **With Accessibility DENIED, the menu bar icon still opens its panel.**
      The menu is the only place to grant permission, so a user who denies the
      prompt must still be able to reach it. Verify by: `tccutil reset
      Accessibility xyz.crevn.typewiser`, relaunch, deny the prompt, then click
      the icon.
- [ ] **The menu states plainly that dictation is disabled when untrusted**, and
      offers a working "Open System Settings…" deep link (macOS will not re-show
      a prompt the user already denied).
- [ ] **After granting, the app notices within ~2s without a restart** (AppModel
      polls, then starts the monitors).
- [ ] **Permission survives a rebuild.** Make a real code change, run
      `./Scripts/bundle-app.sh`, relaunch — dictation must still work. If it
      breaks, the app fell back to ad-hoc signing; check for the warning from
      bundle-app.sh and run `./Scripts/create-signing-cert.sh`.
