# Research: Giving Plato real cursor control (move / highlight / click)

**Date:** 2026-06-28
**Question:** How do we let Plato actually move the system cursor, highlight elements, and click — "like the latest heyclicky version it's based off"?

---

## TL;DR

1. **No version in Plato's fork lineage actually clicks.** Plato, its parent `tryskilly/skilly`, and the original `farzaa/clicky` (open source) all use a *purely visual overlay cursor*. None of them move the real macOS cursor or synthesize clicks.
2. **The "latest heyclicky" is closed-source.** Per Farza's own README (dated **April 27, 2026**): *"for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go to heyclicky.com."* Whatever the live app does, it is **not** in any repo we can read.
3. **Clicky left one relevant scaffold:** `ElementLocationDetector.swift` uses Claude's **Computer Use API** to get accurate element coordinates — but it is **dead code**, never called anywhere in the repo. Plato doesn't even have this file (Plato moved to the unified OpenAI Realtime pipeline; `clicky/main` is an *older* chained architecture).
4. **Conclusion:** Real cursor control + clicking is **net-new work** — but Plato already has ~80% of the hard scaffolding (permissions, accurate target point, coordinate mapping, the overlay). The actual cursor-move + click is a focused addition of well-known macOS APIs.

---

## Should Plato take over the main cursor, or have its own? (verified)

> Answering the design question: *"Should Plato take over my main cursor? Shouldn't it have its own cursor so it can help me simultaneously?"* — backed by adversarial verification of the macOS platform claims.

**Short answer: don't take over the main cursor by default. The intuition ("its own cursor / help simultaneously") is right — but the way to achieve it is not a second cursor, it's cursor-free action via the Accessibility API.**

What macOS actually permits (verified):
- **There is exactly ONE user-visible system cursor**, owned by WindowServer. Every pointing device (and synthetic event) merges into it. **There is no supported API to create a second visible cursor that also clicks.** True multi-pointer is Linux/X11-only. *(Confirmed.)*
- **Plato's blue overlay already IS "its own cursor"** in the only sense macOS allows: a drawn graphic in a click-through window that Plato positions itself and that only *reads* the real pointer, never moves it. That's why two pointers can appear at once today — only one is a real OS cursor.
- **To go from pointing → acting without touching your real cursor, the primitive is `AXUIElementPerformAction(el, kAXPressAction)`** — it invokes the control through the target app's accessibility handler, with **no cursor movement and no synthetic pointer event**. *(Confirmed core mechanism.)* This is the path that delivers "help simultaneously."
- **By contrast, any synthetic click via `CGEvent.post(tap:)` visibly warps the single shared cursor** to the click location (the warp comes from the event's location field — true for `.cghidEventTap` *and* `.cgSessionEventTap`). So "synthetic clicking" inherently seizes your pointer. *(Confirmed.)*
- **`CGEvent.postToPid(pid)` is the only synthetic-event path that does NOT move the cursor**, but it's reliable mainly on native AppKit/SwiftUI apps — Chromium/Electron drop synthetic clicks, and canvas/GPU/game apps force a foreground activation that then warps the cursor anyway.

Important honest caveats the verification surfaced:
- **"Cursor-free" ≠ "interference-free."** `kAXPressAction` doesn't move the cursor and doesn't raise/activate the app *by itself* (`kAXRaiseAction` is separate) — but the *target app's own handler* may self-activate or grab keyboard focus as a side effect. Non-interference is the **common case for native controls, not a guarantee**.
- **AX action coverage is uneven:** native AppKit/SwiftUI = good; **canvas/GPU apps (Blender, games, WebGL) expose no per-control AX elements** → must fall back to pointing-only or an explicit takeover; Electron/Chromium need `AXEnhancedUserInterface`/`AXManualAccessibility` set first.
- **`kAXPressAction` can return success while silently doing nothing** on modal/popover children, Control Center, some menu extras → always re-read state after acting to confirm.
- **Secure-input fields (passwords) are invisible to AX and reject synthetic input** — acting there is impossible by any method.
- **Truly parallel, fully-isolated automation requires a separate login session / VM** — which is *not your live screen*, so it's the wrong fit for a companion tutor.

**Recommended architecture (escalate only with consent):**
1. **Overlay cursor = the teaching pointer** (today's behavior). Plato's own pointer, coexists with yours.
2. **Highlight ring** around the real target element (one AX rect fetch). Cheap, high legibility — do this before any clicking.
3. **Act via AX (`kAXPressAction`) as the primary actuation** — cursor-free, focus-preserving in the native-control case, covered by Plato's existing Accessibility grant. Verify by re-reading state.
4. **Fallback `CGEvent.postToPid`** for native apps that expose no usable AX action.
5. **AX-blind UIs (Blender/games/canvas) → point only** + honest "I can point but can't click this one for you here."
6. **Real-cursor warp-and-click = explicit, momentary, user-consented "do it for me" only** — clearly signaled, never silent, never an autonomous loop.

---

## What we verified

### Plato today (current `main`)
- Blue cursor is a SwiftUI image in a **transparent, click-through `NSWindow`** (`.ignoresMouseEvents = true`, level `.screenSaver`) — `OverlayWindow.swift:14-52`, `BlueCursorView` at `:359-392`.
- The model emits `[POINT:x,y:label:screenN]`; parsed in `CompanionManager.swift:1649-1703` (`parsePointDirective`), screen resolved at `:1705-1718`, pixels→global-AppKit at `:1720-1734` (`mapScreenshotPixelCoordinateToGlobalScreenPoint`).
- Overlay flies to the target via a 60fps bezier arc (`OverlayWindow.swift:565-638`). **Visual only.**
- **No** `CGWarpMouseCursorPosition`, `CGEvent` mouse posting, or AX press anywhere.
- Accessibility (`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`) and Screen Recording (`CGPreflightScreenCaptureAccess`) are **already requested/granted** — AX is currently used only for window shrinking (`WindowPositionManager.swift:204-256`, reading `kAXPositionAttribute`/`kAXSizeAttribute`).
- `OnboardingTargetFrameReporter.swift` measures SwiftUI view frames (via `window.convertToScreen`) for the onboarding tour — not AX, not relevant to clicking, but a model for "draw a ring around a known frame."

### Upstream lineage
- `farzaa/clicky` `main`: overlay-only. `ElementLocationDetector.detectElementLocation(...)` defined but **never called**. No `.post(tap:)`, no warp, no AX press.
- `tryskilly/skilly` `main` and `develop`: overlay-only, no real clicking either.

---

## The capability gap

| Capability | Plato has it? | Notes |
|---|---|---|
| Accessibility permission (required to post events) | ✅ | Already used for window shrinking |
| Screen Recording | ✅ | For screenshots |
| Accurate-ish target point | ⚠️ | From Realtime `[POINT]` tag; good enough to *point*, often **not** good enough to *click* |
| Overlay to draw a highlight | ✅ | `OverlayWindow` — just needs a ring shape |
| Coordinate conversion helpers | ✅ | `mapScreenshotPixelCoordinateToGlobalScreenPoint`, `convertScreenPointToSwiftUICoordinates` |
| Move the real cursor | ❌ | Build |
| Highlight the actual element (ring around its frame) | ❌ | Build (needs the element *frame*, via AX) |
| Click / double / right-click / drag / type | ❌ | Build |
| Pixel-accurate target for clicking | ❌ | Optional: revive Computer Use detector |
| Action protocol from model (`[CLICK]`, `[DRAG]`…) | ❌ | Build |

---

## How to build it — the macOS APIs

### A. Move the real cursor
```swift
// Instant teleport. Point is GLOBAL, TOP-LEFT origin (CG space), spanning all displays.
CGWarpMouseCursorPosition(globalTopLeftPoint)
// Avoid the post-warp "stuck cursor": re-associate mouse with cursor.
CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
```
For *smooth* motion synced with the existing bezier arc, post a move event per frame instead of teleporting:
```swift
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: pointThisFrame, mouseButton: .left)?
    .post(tap: .cghidEventTap)
```

### B. Click — two strategies (use a hybrid)

**Strategy 1 — Synthetic HID events.** Works *everywhere*, including canvas/GPU apps (Blender, games, Electron) that don't expose accessibility actions:
```swift
let source = CGEventSource(stateID: .hidSystemState)
let p = globalTopLeftPoint
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,   mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
// double-click: set .mouseEventClickState = 2 on both events
// right-click:  .rightMouseDown / .rightMouseUp
// drag:         leftMouseDown @ start → series of .leftMouseDragged → leftMouseUp @ end
```

**Strategy 2 — Accessibility press.** Robust for native controls; *doesn't move the visible cursor* and works even on background windows:
```swift
let systemWide = AXUIElementCreateSystemWide()
var element: AXUIElement?
// x,y are GLOBAL, TOP-LEFT (matches kAXPositionAttribute that WindowPositionManager already reads)
AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &element)
if let element { AXUIElementPerformAction(element, kAXPressAction as CFString) }
```
Many custom UIs return no element or no `kAXPressAction`. **Recommended hybrid:** try AX press first; if it fails, warp + synthetic click.

### C. Highlight an element (the "highlight" the user asked for)
A point is not enough to draw a ring — you need the element's **frame**:
```swift
let systemWide = AXUIElementCreateSystemWide()
var element: AXUIElement?
AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &element)
// Read kAXPositionAttribute + kAXSizeAttribute (Plato already does this for windows)
// → element rect in CG top-left coords → convert to overlay coords → draw rounded-rect halo.
```
Render the ring in the existing `OverlayWindow` (reuse `convertScreenPointToSwiftUICoordinates`). Fall back to a fixed-radius halo around the point when AX yields no frame.

### D. Coordinate systems (the #1 source of bugs)
Three spaces are in play:
- **CG / Computer Use / event space:** top-left origin, +Y down, global across displays. Used by `CGWarpMouseCursorPosition`, `CGEvent`, `AXUIElementCopyElementAtPosition`, `kAXPositionAttribute`.
- **AppKit space:** bottom-left origin, +Y up. `NSScreen.frame`, `NSEvent.mouseLocation`, and Plato's `[POINT]` mapping output.
- Plato's `mapScreenshotPixelCoordinateToGlobalScreenPoint` returns a **global AppKit (bottom-left)** point.

To click/warp, convert AppKit-bottom-left → CG-top-left:
```swift
let primaryHeight = NSScreen.screens.first!.frame.height
let cgPoint = CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
```
Note: Clicky's `ElementLocationDetector` already does the **reverse** flip (CG→AppKit) at the end of `detectElementLocation` — mirror that logic.

### E. Permissions / entitlements
- **AX actions** (`AXUIElementPerformAction`, reading frames) run under the **Accessibility** grant Plato already holds — **no new TCC prompt**. This is a reason to prefer the AX path.
- **Synthetic event posting + cursor warping** require Accessibility trust at minimum. ⚠ One verification agent claimed event posting needs a *separate* `CGRequestPostEventAccess` grant distinct from Accessibility — **treat this as unverified**: macOS has a distinct "Input Monitoring" grant (`CGRequestListenEventAccess`) for *listening* to event taps, but historically *posting* has fallen under Accessibility. **Confirm against the current macOS at implementation time** before assuming an extra prompt is/ isn't needed.
- The app must **not** be App-Sandboxed for this (it isn't — it uses AX + ScreenCaptureKit).
- **Will be rejected by:** secure input fields (passwords), apps with secure keyboard entry, the login window, and some DRM/full-screen contexts. Detect and refuse gracefully.

### F. Accuracy — the real challenge
Pointing tolerates error (a ring *near* the button reads fine). Clicking does **not** — a few px off hits the wrong control or nothing. Mitigations, in order of value:
1. **AX hit-test + snap to element center.** Resolve the element under the model's point, then click its frame center, not the raw point.
2. **Revive `ElementLocationDetector` (Computer Use API).** Markedly more accurate at pixel coordinates than the Realtime model's `[POINT]`. Costs a separate Claude call (~latency + $) — so use it *only when a CLICK is requested*, not for every point.
3. **Confirmation UX** as the backstop (below).

### G. Model action protocol
Extend the existing `[POINT:...]` convention and parse alongside `parsePointDirective`:
- `[CLICK:x,y:label:screenN]`, `[DOUBLECLICK:…]`, `[RIGHTCLICK:…]`
- `[DRAG:x1,y1:x2,y2:screenN]`, `[TYPE:text]`
Reuse the same coordinate mapping. Teach the tags in the system prompt / `SkillPromptComposer` pointing-mode layer.

### H. Safety & pedagogy (do not skip — this is a *teaching* tool)
Auto-clicking is irreversible and the pedagogical value is usually the *user* doing the action. Recommend three modes:
- **Guide (default):** highlight + narrate; user clicks. (Today's behavior + a real ring.)
- **Assist:** move the *real* cursor to the spot; user clicks. (Training wheels — high "wow," low risk.)
- **Auto:** actually click — gated behind explicit per-action confirmation, a visible countdown, and an easy abort (move mouse / Esc).
Never act on password/secure-input fields. Log every synthetic action.

---

## Recommended phasing

| Phase | Deliverable | Risk |
|---|---|---|
| 1 | Move the **real** cursor to the `[POINT]` target (sync system cursor with the overlay's bezier flight) | Low — high "wow" |
| 2 | AX element resolution + accurate **highlight ring** around the real element frame | Low |
| 3 | **Click** synthesis (hybrid AX-press / synthetic) behind confirmation; `[CLICK]`/`[DRAG]` protocol | Med |
| 4 | (Optional) Computer Use detector for pixel-accurate click targets; typing/drag | Med |

## Files likely touched
- **New** `CursorControlManager.swift` — warp, frame-synced animate, click synth, AX press. `// MARK: - Skilly`.
- **New** `AXElementResolver.swift` — element-at-position, frame read, press.
- **Modify** `CompanionManager.swift` — parse `[CLICK]`/`[DRAG]`, AppKit→CG conversion, call into the managers.
- **Modify** `OverlayWindow.swift` — highlight-ring rendering; optionally drive the real cursor from the bezier arc.
- **Optional** port `ElementLocationDetector.swift` from `clicky/main` (Computer Use) — note it needs the `computer-use-2025-11-24` beta header + an Anthropic key path through the Worker.
- **Modify** system prompt / `SkillPromptComposer` pointing layer — teach action tags.

## Remotes added during research
- `clicky` → `https://github.com/farzaa/clicky.git`
- (`upstream` already = `https://github.com/tryskilly/skilly.git`)
