# Plato — Bounded Proactivity & Voice Timer Control

- **Date:** 2026-06-24
- **Status:** Approved design (pre-implementation)
- **Author:** Fahim + Claude
- **Scope:** macOS app (`leanring-buddy/`). No worker / web-sdk changes.

## 1. Problem

Plato "triggers by itself" — it speaks when the user did not deliberately invoke it.
The user confirmed the symptom is: **it activates while they are just working, with no
pomodoro running.** A prior fix (commit `ab12865`, terminate duplicate instances) did not
help because the bug fires inside a single instance.

A diagnostic pass (7-path trace + adversarial verification) found the true cause and several
related facts. The user then defined the *intended* proactivity model, which this spec
implements.

### Root cause (the bug)

The default push-to-talk hotkey is the **bare modifier chord `ctrl+option`**, matched by an
OptionSet **superset** check, not an exact match and not a real key press:

- `BuddyPushToTalkShortcut.swift:105` — default shortcut string is `"controlOption"`.
- `BuddyPushToTalkShortcut.swift:68` — `.controlOption` → `modifierOnlyFlags = [.control, .option]`.
- `BuddyPushToTalkShortcut.swift:175-188` — modifier-only branch: `modifierFlags.contains(modifierOnlyFlags)`
  is `true` whenever control **and** option are both down, even with extra modifiers or a
  non-modifier key also held. Rising edge → `.pressed`, falling edge → `.released`.

Downstream, `.pressed` starts mic + screen capture (`CompanionManager.swift:856-906` →
`startOpenAIRealtimePushToTalk`), and `.released` commits the buffer and forces a model turn
when ≥1 audio chunk (~100 ms) was captured (`CompanionManager.swift:1718-1746`,
`minimumAudioChunksRequiredToCommit = 1` at `:134`, `OpenAIRealtimeClient.swift:557-577`).
The persona prompt makes speech **mandatory every turn** (`CompanionManager.swift:941`), so
the spurious turn is audible.

Therefore any unrelated use of `ctrl+option` — VoiceOver (whose VO modifier *is* ctrl+option),
window/Spaces chords, or any app's `ctrl+option+key` binding — makes Plato talk. This is
independent of instance count, so `ab12865` could never fix it.

### Related facts (from diagnosis, used by this design)

- Base realtime session sets `turn_detection = NSNull()` (`OpenAIRealtimeClient.swift:442`) — server
  VAD is off, so a merely-connected session does **not** auto-respond to ambient audio. Good; we keep this.
- Proactive speech is `requestForcedSpokenResponse` (`OpenAIRealtimeClient.swift:621-639`), guarded
  only by `isConnected`. It is the primitive behind block-start/break announcements and focus nudges.
- The focus-watch (commit `dabe390`) is the user's intended accountability feature, but currently:
  checks every **75 s** (`focusWatchIntervalSeconds = 75`, `CompanionManager.swift:200`); never *asks*
  the topic — it reads the typed `TextField("What are you working on?")` (`PanelBodyView.swift:149` →
  `pomodoro.focusTopic`); and has a brittle classifier fallback (`CompanionManager.swift:295`,
  substring match → false positives on un-parseable output).
- No timer-control tool exists. Realtime tools are only `point_at_element` and `search_scholar`
  (`OpenAIRealtimeClient.swift:371,404`; dispatch `CompanionManager.swift:1966-1982`).
- Live Tutor mode (server_vad + always-on mic, `CompanionManager.swift:1750-1786`) is a separate
  hands-free mode; it does not auto-arm on launch (`.dropFirst()` at `:706`) and defaults off
  (`AppSettings.swift:248`). Out of scope here.

## 2. Intended model (user-defined)

Plato is **silent unless** one of these is true:

1. The user **holds ctrl+option** (push-to-talk) — including to answer Plato's questions.
2. A **pomodoro is running**, during which Plato may: do a block-start check-in, announce timer
   status transitions, and nudge on distraction.
3. The user **voice-commands the timer** and Plato confirms / answers.

Everything else is silent.

## 3. Goals / Non-goals

**Goals**
- G1: `ctrl+option` no longer triggers on incidental/compound presses; deliberate hold-to-talk still works.
- G2: At block start Plato asks "what are you working on?" (or confirms a typed topic); the user
  answers by holding ctrl+option; the answer is recorded as the focus topic.
- G3: Focus checks run every ~20 s, stay silent when on-task, nudge when off-task without nagging,
  and tolerate classifier output robustly.
- G4: The user can voice-command the timer (start/pause/resume/stop/skip-break/status/set-topic).
- G5: No proactive speech occurs outside the intended model.

**Non-goals**
- Changing Live Tutor mode, the worker, billing, or web SDK.
- Reworking the upstream onboarding intro (it only fires on deliberate onboarding/replay → already in-spec).
- Fixing the pre-existing upstream credential issues (per project decision, leave as-is).

## 4. Design

### 4.1 Hotkey hardening (G1)

**Final approach (after testing): change the default to a real key-combo, `ctrl+option+0`, and keep
activation instant (no dwell).** A bare two-modifier trigger was the root problem: the original
`ctrl+option` collided with the user's Raycast hyper key (`ctrl+option+cmd`, a superset), and any
bare-modifier alternative (`shift+control`) collides with extremely common chord *prefixes*
(`ctrl+shift+tab`, IDE command palettes, Sequoia window-tiling) because activation fires the instant
the modifiers are down, before the following key. Requiring a real key removes that entire class.

1. **Exact modifier match.** `BuddyPushToTalkShortcut.shortcutTransition` compares the held modifiers
   exactly (`modifierFlags.intersection([.control, .option, .command, .shift, .function]) == required`),
   for both the bare modifier-only chords and the key-combo branch. This rejects supersets — notably
   the hyper key `ctrl+option+cmd(+0)`.
2. **Key-combo default.** New `ShortcutOption.controlOptionZero` = modifiers `[.control, .option]` +
   the `0` key (ANSI keyCode 29). The key-combo branch was generalized from the old hardcoded Space
   path to a per-option `keyComboKeyCode` (49 = Space, 29 = `0`). `.pressed` fires on the `0` key-down
   while exactly `ctrl+option` are held; `.released` on the `0` key-up. Bare `ctrl+option` (hyper key,
   VoiceOver, etc.) never fires because the `0` key is required.
3. **No dwell.** Activation is immediate in `CompanionManager.handleShortcutTransition` (restored to
   the original upstream press→start / release→stop), so it feels snappy. The dwell + cancel-on-other-key
   machinery that was briefly prototyped is removed — unnecessary once the trigger requires a real key.

Default is set in three places (kept consistent): `BuddyPushToTalkShortcut.currentShortcutOption`,
`ShortcutOption.init` default, and `AppSettings.init` — all `"controlOptionZero"`. The Settings
picker (`SettingsView`) lists "Ctrl + Option + 0" first; the older chords remain selectable.

**Edge cases:** `ctrl+option+0` passes through to the focused app (listen-only tap), but `control`
suppresses the `º` that `option+0` would otherwise insert, so it's effectively inert in text fields.
Number-row `0` (keyCode 29) triggers; numpad `0` (keyCode 82) does not — acceptable.

### 4.2 Bounded proactivity + block-start check-in (G2, G3, G5)

**Block start (`CompanionManager.swift:165-173`, `onWorkStart`):**
- If `currentFocusTopic` is empty → Plato *asks* via `speakProactiveAnnouncement`:
  "What are you working on this block?" The persona is instructed (prompt + tool guidance) that the
  user's next held-PTT answer should be recorded by calling `control_pomodoro(action: "set_topic", topic: …)`.
- If `currentFocusTopic` is set (typed field, or supplied by a voice `start`) → Plato *confirms* it
  in one short sentence and does not ask.
- When `start` originates from a **voice tool call**, suppress this auto-announcement (the tool
  continuation already speaks the confirmation) to avoid double-speaking. Use a transient
  "start source" flag set by the tool dispatch before calling `pomodoro.start(...)`.

**Focus checks (`CompanionManager.swift:204-245`, `startFocusWatch`/`performFocusCheck`):**
- Change `focusWatchIntervalSeconds` `75 → 20`.
- Keep the silent gpt-4o-mini vision classifier and the screenshot-per-check mechanism.
- Keep a cooldown between *spoken nudges* so Plato never nags (retain `focusNudgeCooldownSeconds`,
  candidate value ~120 s now that checks are more frequent). Silent (on-task) checks are uncapped.
- Robust classifier: in `classifyFocus` (`:250-296`), on any parse failure return
  `(distracted: false, …)` — remove the brittle substring fallback at `:295`. Distraction must be an
  explicitly parsed `true`.

**Kept as-is:** break recap (`onWorkEnd`) and break-end nudge (`onBreakEnd`). Onboarding intro
(deliberate onboarding/replay only).

**Silent-otherwise guarantee:** all proactive speech remains routed through
`speakProactiveAnnouncement` and is reachable only from (a) `onWorkStart/onWorkEnd/onBreakEnd`
(pomodoro active) and (b) `performFocusCheck` (guarded by `phase == .work && isRunning`). No
proactive call fires without an active pomodoro. (Verified: no other autonomous
`requestForcedSpokenResponse` caller exists except the within-turn point-tool recovery at
`CompanionManager.swift:1910`, which is part of a user turn.)

### 4.3 Voice timer control (G4)

A new realtime tool **`control_pomodoro`**.

- **Declaration:** added to the tools array in `OpenAIRealtimeClient.updateSessionConfiguration`
  (alongside `point_at_element`/`search_scholar`, near `:404-437`).
- **Schema:** `action` (enum: `start`, `pause`, `resume`, `stop`, `skip_break`, `status`, `set_topic`),
  optional `minutes` (integer, for `start`), optional `topic` (string, for `start`/`set_topic`).
- **Dispatch:** new `case "control_pomodoro"` in `CompanionManager` `.functionCallDone`
  (`:1966-1982`). It maps the action to `PomodoroTimer` calls, then returns a result and continues
  the turn so Plato speaks the confirmation/answer, using the async tool lifecycle wrapper
  (`sendToolResultAndContinue` / `continueAfterToolOutput` — `response.create` with `tool_choice: auto`,
  per the existing Scholar pattern). Control actions are synchronous/local, so no network await.
- **`status`** returns a compact state object (phase, minutes/seconds remaining, current block index,
  total blocks, topic) for Plato to read back.
- **`set_topic`** sets `pomodoro.focusTopic` (which propagates via `onFocusTopicChange` →
  `currentFocusTopic`), so the vision classifier uses the spoken topic. This is the recorder for the
  4.2 block-start ask.

**`PomodoroTimer` additions:** public methods to match the actions — `resume()` (or reuse `start()`
from paused), `stop()`/`reset()`, `skipBreak()` (end the current break early / advance), an optional
`minutes`/`topic` parameter path for `start`, and a read-only state accessor (phase, secondsRemaining,
currentSession, sessionsPerBlock, focusTopic). Existing `start()`/`pause()` are reused.

**Coordination:** a voice `start{minutes, topic}` sets duration + topic, sets the "start source =
voice" flag (4.2), starts the timer; `onWorkStart` then suppresses its own announcement and the tool
continuation speaks "Started a 25-minute block on X." A Play-button start keeps the `onWorkStart`
ask/confirm path.

## 5. Components & files (anticipated)

| File | Change |
|------|--------|
| `BuddyPushToTalkShortcut.swift` | Exact-match modifiers (both branches); new `controlOptionZero` option; generalized key-combo (`keyComboKeyCode`); default → `controlOptionZero`; explicit `controlOption` init case. |
| `CompanionManager.swift` | `onWorkStart` ask/confirm + `isVoiceInitiatedPomodoroStart`; focus-watch interval 20s; `classifyFocus` robustness; `control_pomodoro` dispatch + `handlePomodoroToolCall`/`pomodoroStateJSON`. (Hotkey handler unchanged from upstream — no dwell.) |
| `OpenAIRealtimeClient.swift` | `control_pomodoro` tool declaration. |
| `PomodoroTimer.swift` | `resume`/`stop`/`skipBreak` + `start(minutes:topic:)`. |
| `AppSettings.swift` | Push-to-talk default → `controlOptionZero`. |
| `SettingsView.swift` | "Ctrl + Option + 0" picker option (listed first). |
| `GlobalPushToTalkShortcutMonitor.swift` | No change (the prototyped other-key publisher was removed). |

All changes additive and marked `// MARK: - Plato`. No upstream renames. No `xcodebuild`.

## 6. Verification

Agents cannot run `xcodebuild` (TCC) — the user does the GUI build. For each changed file run
`swiftc -parse` as a syntax gate. Manual test matrix:

1. Raycast hyper key (`ctrl+option+cmd`) and bare `ctrl+option` → **no** activation. `ctrl+shift+tab`,
   IDE command palettes → **no** activation. Hold `ctrl+option+0`, speak,
   release → normal turn works.
2. Start a block with empty topic → Plato asks; hold ctrl+option, answer; topic is recorded
   (subsequent nudges reference it). Start with typed topic → Plato confirms, no question.
3. On-task screen for several 20 s checks → silence. Switch to an off-task screen → one nudge,
   then silence within cooldown.
4. Voice: "start a 25-minute block on my thesis intro" → starts, confirms once (no double-speak);
   "pause" / "resume" / "how much time is left?" / "skip the break" / "stop" → correct behavior + spoken confirmation.
5. No timer running and not holding the hotkey → Plato never speaks.

## 7. Out of scope / follow-ups

- Live Tutor hardening, worker, billing, web SDK.
- Persisting `lastFocusNudgeAt` across restarts (minor; restart mid-block could re-nudge once).
- Making the onboarding intro text-only (left as-is by decision).
