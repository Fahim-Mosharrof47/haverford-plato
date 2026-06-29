# Research: Visual pointing & highlighting — translucent regions, ripple pulses, arrows, spotlight

**Date:** 2026-06-29
**Question:** How do we let Plato's overlay cursor *highlight* things on screen — translucent colored rectangles, a "click here" ripple pulse, scroll/arrow affordances, a spotlight/dim mask — to (1) highlight a section of a research paper to study/include and tell the user to scroll to it, and (2) point a user at the right button in software they don't know?

**Scope:** This is the **visual / highlighting layer only**. Pointing and highlighting — *not* moving the real cursor, *not* clicking, *not* performing actions. The actuation side (warping the real cursor, synthetic clicks, AX press) is covered separately in [`real-cursor-control.md`](./real-cursor-control.md) and is **explicitly out of scope here**; this doc references it where the two intersect but does not duplicate it.

---

## TL;DR

1. **The rendering half is easy and low-risk.** Plato's overlay is already a full-screen, click-through, per-screen `NSWindow` hosting a SwiftUI `BlueCursorView` ZStack with a 60fps timer. Translucent rects, a ripple pulse, an arrow, and a spotlight cutout are all just additional SwiftUI `Shape` layers driven by new `@Published` state on `CompanionManager`. No new windows, no new permissions, no new coordinate math beyond what already exists.
2. **The hard half is *localization*: knowing WHERE to draw.** There is no single answer. Three strategies trade off precision vs. coverage:
   - **(i) Model-returned bounding box** (extend `[POINT]` → a region tag with `w,h`). Cheap, universal, *imprecise* — the model is bad at exact pixel coords. Fine for "roughly this area."
   - **(ii) Accessibility (AX) API element frame** — pixel-precise for native app controls (buttons, toolbars). **Zero coverage** for canvas/GPU apps (Blender, Figma canvas, games) and gated/sparse for Electron. The win for "point at the right button."
   - **(iii) Vision-framework OCR where the MODEL returns the TEXT and the APP resolves the rect** — the key enabler for **paper/section highlighting**. Removes the model's unreliable coordinate-estimation step entirely.
3. **Recommended: a hybrid resolver.** Text → OCR for documents/papers; AX for native app controls; model bounding-box as the universal fallback. All three funnel into the **same** existing coordinate chain (`mapScreenshotPixelCoordinateToGlobalScreenPoint`) and the **same** overlay.
4. **"Scroll to a section" is a voice-guided, re-capture-until-visible loop — not a programmatic scroll.** Plato cannot read another app's document structure (PDFKit is in-process only) and cannot (by scope) scroll for the user. It instructs, shows a directional affordance, re-captures, and highlights once the target text becomes visible via OCR.
5. **Highlights must be momentary, not persistent.** An absolute-screen-coordinate box goes stale the instant the user scrolls/resizes/moves a window. The existing pointer already commits to this (fly → hold ~3s → clear). Box highlights should match: time-boxed TTL, re-anchored per turn, auto-dismissed on first scroll/mouse-down.

### How this complements `real-cursor-control.md`

| | `real-cursor-control.md` (out of scope here) | This doc (visual-pointing-highlighting.md) |
|---|---|---|
| Goal | Act *for* the user | Show the user *where* |
| Primitive | `CGWarpMouseCursorPosition`, `CGEvent.post`, `AXUIElementPerformAction(kAXPressAction)` | SwiftUI shapes in the overlay |
| Touches real cursor / clicks | Yes | **Never** |
| New permission risk | Possibly (event posting) | **None** beyond grants already held |
| Shared machinery | AX element-frame read; AppKit↔CG coordinate flips; `OverlayWindow` | AX element-frame read; same coordinate chain; same `OverlayWindow` |

The two docs share the **AX element-frame resolution** code and the **`OverlayWindow`** host. If both ship, factor the AX resolver into one file (`AXElementResolver.swift`) consumed by both. This doc owns the *drawing*; that doc owns the *acting*.

---

## 1. Current state — the extension surface

### 1.1 The overlay host (drawing surface already exists)

One borderless `NSWindow` per screen, sized to `screen.frame`, transparent, click-through, always-on-top, visible across Spaces and over fullscreen apps:

- `OverlayWindow.swift:14-53` — `isOpaque=false`, `backgroundColor=.clear`, `level=.screenSaver`, `ignoresMouseEvents=true` (click-through), `collectionBehavior=[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`, `canBecomeKey/Main=false` (no focus stealing).
- `OverlayWindow.swift:821-850` — `OverlayWindowManager.showOverlay()` instantiates **one window per `NSScreen`**, wraps `BlueCursorView(screenFrame:companionManager:)` in an `NSHostingView`, and `orderFrontRegardless()`.

Because the window is already click-through and full-screen, **any** new shape we add (filled rect, ripple, arrow, spotlight mask) is automatically non-interactive and correctly layered above other apps. No window work needed.

### 1.2 The SwiftUI view tree (where shapes get added)

`BlueCursorView` is a `ZStack` whose children cross-fade by opacity and are positioned by a 60fps `Timer`:

- `OverlayWindow.swift:198-412` — the ZStack: compositing helper → onboarding video/bubble → realtime response bubble → navigation pointer bubble → cursor icon → waveform → spinner.
- `OverlayWindow.swift:565-638` — `animateBezierFlightArc()`: `Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true)`, smoothstep + quadratic bezier, tangent-based rotation, scale pulse. This is the animation idiom new highlights should follow (or use SwiftUI `withAnimation`/`.repeatForever` for the ripple).
- `OverlayWindow.swift:520-524` — `convertScreenPointToSwiftUICoordinates(_:)`: global AppKit (bottom-left) → overlay-local SwiftUI (top-left). New highlight rects reuse this (plus a height term — see §3a).

### 1.3 The `[POINT]` pipeline (the protocol + coordinate chain to extend)

Two parallel paths feed a single observable target:

- **Preferred — Realtime function call.** Tool `point_at_element` is registered in `OpenAIRealtimeClient.swift:364-395` (added to the `tools` array at `:491`, sent via `session.update` at `:499-504`). On `response.output_item.done` with `item.type=="function_call"` (`OpenAIRealtimeClient.swift:869-885`) it emits `.functionCallDone(name:argumentsJSON:callId:)`. `CompanionManager.swift:2157-2185` dispatches `point_at_element` → `applyPointDirectiveFromToolCall()` (`CompanionManager.swift:1585-1647`). Coordinates never enter the audio/TTS stream.
- **Legacy fallback — inline text tag.** `[POINT:x,y:label:screenN]` parsed by `parsePointDirective()` (`CompanionManager.swift:1649-1703`), applied by `applyPointDirectiveIfPresent()` (`:1562-1578`) **only** when no tool call arrived for the turn (`:2129-2130`, gate at `:1129-1131`).

Both resolve the target screenshot then call `mapScreenshotPixelCoordinateToGlobalScreenPoint()` (`CompanionManager.swift:1720-1734`) and publish into:

- `detectedElementScreenLocation: CGPoint?` (global AppKit point)
- `detectedElementDisplayFrame: CGRect?`
- `detectedElementBubbleText: String?`

`BlueCursorView` observes `detectedElementScreenLocation` (`OverlayWindow.swift:444-459`), flies the bezier arc (`:529-559`, `:565-638`), holds the label bubble ~3s, then flies back and **clears** the location (`startPointingAtElement`, `:642-718`). This clear-on-finish is the lifecycle model highlights should inherit (§4).

### 1.4 The capture metadata (the coordinate-space ground truth)

`CompanionScreenCapture` (`CompanionScreenCaptureUtility.swift:13-22`) carries everything localization needs:

- `displayFrame: CGRect` — **AppKit, bottom-left origin**, same space as the overlay and `NSEvent.mouseLocation`.
- `screenshotWidthInPixels` / `screenshotHeightInPixels` — JPEG resolution, **downscaled to `maxDimension = 1280`** (`CompanionScreenCaptureUtility.swift:83-92`), JPEG 0.8 (`:99-100`). **No Retina/backingScaleFactor scaling** anywhere — scale is encoded implicitly in the pixel-vs-displayFrame ratio.
- `displayWidthInPoints` / `displayHeightInPoints`.

Per-turn captures are stored in `currentTurnScreenCaptures` (`CompanionManager.swift:133-138`) at turn start (`:1802-1856`) and each is described to the model with its exact pixel coordinate space and 1-based screen number (`:1835-1848`).

---

## 2. Two core problems, treated separately

The feature decomposes cleanly into **rendering** (§3a — easy) and **localization** (§3b — hard). Build the rendering primitives first against the cheap model-bbox source, then upgrade the localization source without touching the renderer.

---

## 3a. RENDERING — the visual primitive set

All primitives are SwiftUI shapes added to the existing `BlueCursorView` ZStack, driven by a new observable highlight collection. Because the host window is click-through and full-screen, nothing here can intercept input or break layering.

### Highlight model + state

```swift
// MARK: - Plato — Visual highlight model
import SwiftUI

struct PlatoHighlight: Identifiable {
    enum Kind {
        case filledRegion(color: Color)            // translucent shaded rectangle (study/include a paper section)
        case strokedRegion(color: Color, lineWidth: CGFloat)  // crisp ring around an app control
        case ripplePulse(color: Color)             // expanding "click here" pulse circle
        case directionalArrow(direction: ArrowDirection, color: Color)  // "scroll down" affordance
        case spotlight(dimOpacity: CGFloat)        // dim everything except this rect
    }
    enum ArrowDirection { case up, down, left, right }

    let id = UUID()
    let kind: Kind
    let globalFrame: CGRect           // GLOBAL AppKit coords (bottom-left), same space as displayFrame
    let label: String?
    let createdAt: Date
    let timeToLive: TimeInterval      // auto-expiry; see §4. Recommend 3-5s; never nil/persistent.
}
```

```swift
// MARK: - Plato — Highlight state (CompanionManager, near :25-48)
import Combine   // required: SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY enforces explicit Combine import for @Published
@Published var activeHighlights: [PlatoHighlight] = []

func addHighlight(_ highlight: PlatoHighlight) { activeHighlights.append(highlight) }
func clearAllHighlights() { activeHighlights.removeAll() }
```

A **collection** (not a single field) because a paper turn may want a shaded region *plus* a "scroll down" arrow. Render order = array order (first = rearmost). Each carries its own `id` for targeted removal and its own `timeToLive`.

### Rendering in the ZStack

Insert a `ForEach` into the `BlueCursorView` ZStack **before** the cursor icon (so the cursor draws on top), around `OverlayWindow.swift:349`:

```swift
// MARK: - Plato — Highlight layer
ForEach(companionManager.activeHighlights.filter { highlightBelongsOnThisScreen($0) }) { highlight in
    PlatoHighlightView(highlight: highlight, screenFrame: screenFrame)
}
```

Filter per screen the same way the cursor does (`OverlayWindow.swift:444-459`): only draw a highlight whose `globalFrame` center lies inside this overlay window's `screenFrame`. (A region spanning two displays is an edge case — for v1, draw on whichever screen contains the center.)

### The primitive views

```swift
// MARK: - Plato — Highlight shapes
struct PlatoHighlightView: View {
    let highlight: PlatoHighlight
    let screenFrame: CGRect
    @State private var rippleProgress: CGFloat = 0

    var body: some View {
        let local = convertGlobalFrameToLocal(highlight.globalFrame, in: screenFrame)
        Group {
            switch highlight.kind {
            case .filledRegion(let color):
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.9), lineWidth: 1.5))
                    .frame(width: local.width, height: local.height)
                    .position(x: local.midX, y: local.midY)

            case .strokedRegion(let color, let lineWidth):
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: local.width, height: local.height)
                    .position(x: local.midX, y: local.midY)

            case .ripplePulse(let color):
                // Expanding "click here" pulse at the rect center. Use a repeating animation
                // rather than the bezier Timer so it loops cleanly until TTL clears it.
                Circle()
                    .stroke(color, lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .scaleEffect(1.0 + rippleProgress * 1.6)
                    .opacity(Double(1.0 - rippleProgress))
                    .position(x: local.midX, y: local.midY)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            rippleProgress = 1.0
                        }
                    }

            case .directionalArrow(let direction, let color):
                ArrowShape(direction: direction)
                    .fill(color.opacity(0.95))
                    .frame(width: 36, height: 36)
                    .position(x: local.midX, y: local.midY)
                    .shadow(color: color.opacity(0.5), radius: 8)

            case .spotlight(let dimOpacity):
                // Dim the whole screen EXCEPT the highlight rect, via an even-odd cutout.
                SpotlightMask(holeRectInLocalCoords: local)
                    .fill(style: FillStyle(eoFill: true))
                    .foregroundColor(Color.black.opacity(dimOpacity))
                    .allowsHitTesting(false)   // belt-and-suspenders; window is already click-through
            }
        }
        .allowsHitTesting(false)
    }

    // Global AppKit (bottom-left) frame → overlay-local SwiftUI (top-left) frame.
    // Mirrors convertScreenPointToSwiftUICoordinates (OverlayWindow.swift:520-524) but flips the
    // WHOLE rect: the rect's TOP edge in SwiftUI = its global TOP edge = origin.y + height.
    private func convertGlobalFrameToLocal(_ globalFrame: CGRect, in screenFrame: CGRect) -> CGRect {
        let x = globalFrame.origin.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - (globalFrame.origin.y + globalFrame.height)
        return CGRect(x: x, y: y, width: globalFrame.width, height: globalFrame.height)
    }
}
```

```swift
// MARK: - Plato — Spotlight cutout (dim everything except the hole)
struct SpotlightMask: Shape {
    let holeRectInLocalCoords: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)                                   // full screen
        path.addRoundedRect(in: holeRectInLocalCoords,         // the hole
                            cornerSize: CGSize(width: 8, height: 8))
        return path                                             // eoFill punches the hole
    }
}
```

`ArrowShape` is a trivial `Shape` switching its `path(in:)` by direction (a chevron/triangle). Reuse `DS.Colors` tokens (`DesignSystem.swift:18-149`, e.g. `overlayCursorBlue`, `amber500`) so colors match the brand; map the model's color enum (`red`/`blue`/`green`/`yellow`) to DS tokens or `Color` literals.

### Lifecycle / auto-expiry

Add one expiry timer when the overlay appears (alongside `startTrackingCursor()`), mirroring the existing Timer idiom:

```swift
// MARK: - Plato — Highlight expiry
private func startHighlightExpirationTimer() {
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        let now = Date()
        companionManager.activeHighlights.removeAll {
            now.timeIntervalSince($0.createdAt) > $0.timeToLive
        }
    }
}
```

This is the **floor** of the lifecycle (§4 adds per-turn reset and scroll/mouse auto-dismiss). Drive the `[POINT]` cursor and a highlight in the *same* turn for the "fly there + shade it" effect.

### Animation approach

- **Ripple:** SwiftUI `.repeatForever(autoreverses: false)` on a scale+fade — clean loop, no manual Timer, auto-stops when the view leaves the tree on TTL clear.
- **Region fade-in / arrow entrance:** `withAnimation(.easeOut(duration: 0.25))` keyed on the highlight appearing — matches the bubble's spring-in feel.
- **Avoid** wiring the highlight into the bezier `animateBezierFlightArc` Timer (`:565-638`) — that timer is owned by the cursor flight; highlights are independent and should not couple to it.

### Performance / Retina gotchas

- **No Retina pixel math needed.** Everything is in **points**. The capture pipeline never applies `backingScaleFactor` (confirmed: no scale-factor references in the codebase); `displayFrame` is point-based; normalized→points (§3b) skips pixels entirely. SwiftUI draws in points and the framework handles the backing-store scale. Do **not** multiply by 2x anywhere.
- **Spotlight is the one cost to watch.** A full-screen dimming layer that animates can cause compositing churn. Keep `dimOpacity` modest (~0.45), avoid animating the mask itself, and prefer a static dim that fades in once. One spotlight at a time.
- **Cap concurrent highlights** (e.g. ≤4) to bound the ZStack and the per-screen filter cost; the 60fps cursor Timer already re-renders this view tree every frame.
- **Crisp 1.5px strokes:** at fractional point positions a 1px stroke can look soft; 1.5–2px reads cleanly on both Retina and non-Retina.

---

## 3b. LOCALIZATION — how to know WHERE to highlight (the hard part)

Three strategies, with a recommended hybrid. All three end at the **same** endpoint: a `CGRect` in **global AppKit (bottom-left)** coordinates stored as `PlatoHighlight.globalFrame`, drawn by the renderer above.

### Strategy (i) — Model-returned bounding box (extend `[POINT]` to a region)

The model returns `x, y, w, h` in screenshot pixel space; the app maps them through the existing chain. This is the **cheapest** path and reuses everything.

**Coordinate chain (extends `mapScreenshotPixelCoordinateToGlobalScreenPoint`, `:1720-1734`):**
Width/height scale by the **same** normalization factor as x/y because all four originate in the same screenshot pixel space and map to the same `displayFrame`. **No new conversion** — just normalize w,h and multiply by `displayFrame.width/height`:

```swift
// MARK: - Plato — Model pixel rect → global AppKit rect
// x,y are the TOP-LEFT of the region in screenshot pixels (screenshot origin = top-left).
let topLeftGlobal = mapScreenshotPixelCoordinateToGlobalScreenPoint(   // existing fn; flips Y at :1732
    screenshotXInPixels: x, screenshotYInPixels: y, screenCapture: cap)
let normW = CGFloat(w) / CGFloat(max(cap.screenshotWidthInPixels, 1))
let normH = CGFloat(h) / CGFloat(max(cap.screenshotHeightInPixels, 1))
let globalW = cap.displayFrame.width  * normW
let globalH = cap.displayFrame.height * normH
// mapScreenshotPixel… returns the point for the region's TOP edge (screenshot-top → larger AppKit Y),
// so subtract the height to get the AppKit bottom-left ORIGIN of the rect:
let globalFrame = CGRect(x: topLeftGlobal.x, y: topLeftGlobal.y - globalH, width: globalW, height: globalH)
```

> **Coordinate care (the #1 bug source):** the screenshot is **top-left origin**, AppKit is **bottom-left origin**. `mapScreenshotPixelCoordinateToGlobalScreenPoint` already flips Y for a *point* (`globalY = displayFrame.maxY - height*normY`, `:1732`). For a *rect*, that point is the **top** edge in AppKit terms; the rect's `origin.y` (bottom edge) is that minus `globalH`. Getting this wrong flips the box vertically.

**Verdict:** Universal (works on any app, including canvas/GPU), free (no extra call), but **imprecise** — the model is notoriously unreliable at exact pixel coordinates and especially at *extents* (w,h). Good for "shade roughly this area." Keep as the **fallback**.

### Strategy (ii) — Accessibility (AX) API element frame

Resolve a precise frame for an app control either by hit-testing a point or by searching the focused app's AX tree for a label, then read `kAXPosition`/`kAXSize`.

**Coordinate space (CONFIRMED, with corrections):** AX geometry — both `AXUIElementCopyElementAtPosition` parameters and `kAXPositionAttribute` — is in **global, TOP-LEFT-origin screen coordinates in POINTS**, whose `(0,0)` is the **top-left of the PRIMARY (menu-bar) screen**, with axes extending across all displays (a display above/left of primary yields **negative** AX coords). **There is no backingScaleFactor / pixel conversion** — values are points, matching `NSScreen`. Convert to AppKit (bottom-left) by flipping **only Y** against the **primary** screen height; X is identical:

```swift
// MARK: - Plato — AX (global top-left, points) → AppKit (global bottom-left, points)
func appKitRectFromAXFrame(axOrigin: CGPoint, axSize: CGSize) -> CGRect {
    guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
        return CGRect(origin: axOrigin, size: axSize)
    }
    let flipHeight = primary.frame.maxY                       // = primary screen height (the global flip reference)
    let appKitY = flipHeight - axOrigin.y - axSize.height     // bottom-left origin Y
    return CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
}
```

**Hit-test a point** (note: `x,y` are C `float` — **must** explicitly write `Float(...)`; SE-0307 CGFloat↔Double interchange does NOT cover Float; CONFIRMED):

```swift
let systemWide = AXUIElementCreateSystemWide()
var hit: AXUIElement?
let r = AXUIElementCopyElementAtPosition(systemWide, Float(topLeftX), Float(topLeftY), &hit)  // top-left coords
// r == .success → read kAXPositionAttribute + kAXSizeAttribute (Plato already does this for windows
// in WindowPositionManager.swift), then appKitRectFromAXFrame(...). Guard size.width/height > 0.
```

**Search by label** — DFS the focused app element (`AXUIElementCreateApplication(pid)` → `kAXWindows`/`kAXChildren`), matching `kAXRole` ∈ {`AXButton`,`AXMenuItem`,`AXPopUpButton`,`AXCheckBox`,…} against `kAXTitle`/`kAXDescription`/`kAXHelp`/`kAXIdentifier`. Bound by depth + node count + a wall-clock deadline; set `AXUIElementSetMessagingTimeout(app, 0.2)`. Batch per-node reads with `AXUIElementCopyMultipleAttributeValues(options: 0)` (one IPC round-trip/node; failed slots come back as `kAXValueAXErrorType` placeholders or `CFNull` — CFGetTypeID-guard before `as! AXValue`).

**Threading (REFUTED the "thread-safe for reads" assumption):** the AX API is **not** thread-safe and is **synchronous/blocking** cross-process IPC. Per Apple DTS, all AX calls should run on the **main thread**. Since the project is heavily `@MainActor` and results feed `@MainActor` UI anyway, **keep the DFS on the main thread** (or behind a single dedicated serial AX actor with a short messaging timeout) — never a concurrent background DFS.

**Coverage (honest):**

| App type | AX per-control frames? | Notes |
|---|---|---|
| Native AppKit / SwiftUI / Catalyst | **Yes, reliable** | Best case — toolbar/menu/button frames accurate. |
| Safari / WebKit web content (`AXWebArea`) | **Yes, no flag** (CONFIRMED) | Exposed to any AX client without VoiceOver; builds lazily (one query + brief settle). |
| Electron / Chromium (VS Code, Slack, Discord, Obsidian) | **Yes, after waking** | Set `AXManualAccessibility=true` on the **app** element; tree builds **async** (poll ~200–500ms). On Electron ≥23 returns `.success`; on older it returned `-25205` **but still took effect** — treat `.success` **and** `-25205` as "applied," don't fall back on `-25205`. `AXEnhancedUserInterface` is a defensive last resort only (undocumented; has an AppKit window-reflow side effect that can disturb native window managers — affects native apps too, not just Chromium). |
| Canvas / GPU / immediate-mode: **Blender, games, WebGL, Figma canvas** | **No — zero per-control elements** | The canvas is one opaque AX element. **Must fall back to model-bbox / OCR.** (Figma desktop is Electron: its *chrome* panels are Chromium web-AX nodes after waking, but the *canvas* interior is opaque.) |

**Permissions:** reading frames and setting `AXManualAccessibility` on another process need **only** the existing Accessibility grant (`AXIsProcessTrusted`) — **no new TCC prompt** (CONFIRMED; already exercised in `WindowPositionManager.swift`).

**Verdict:** **Precise where it works** (native + Safari + woken Electron) — the right primitive for "point at the right button." **Useless on canvas/GPU.** Use as the precision path for app controls, with model-bbox as the floor.

### Strategy (iii) — Vision-framework OCR (model returns TEXT, app resolves the rect)

**The key enabler for paper/section highlighting.** The model names the text ("Methods", "the dependent variable…") instead of guessing pixels; the app runs OCR over the captured screenshot, matches the text, and unions the matching line boxes into a rect. This **removes the model's unreliable coordinate-estimation step**.

**Deployment target is macOS 14.2**, so use the classic `VNRecognizeTextRequest` + `VNImageRequestHandler` (the async `RecognizeTextRequest` struct is macOS 15+). Add `import Vision` (no existing Vision usage in the repo).

```swift
// MARK: - Plato — OCR a captured screenshot into recognized lines + boxes
import Vision
struct RecognizedTextLine { let text: String; let observation: VNRecognizedTextObservation; let confidence: Float }

enum ScreenshotTextRecognizer {
    /// VNImageRequestHandler.perform is SYNCHRONOUS — run OFF @MainActor, hop back to draw.
    static func recognizeText(in cgImage: CGImage) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate        // dense paper text, not live camera
        request.usesLanguageCorrection = true       // fixes OCR noise → better matching against model's clean text
        request.recognitionLanguages = ["en-US"]    // widen per AppSettings language
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return RecognizedTextLine(text: top.string, observation: obs, confidence: top.confidence)
        }
    }
}
```

**Vision box coordinate space (CONFIRMED):** `VNRecognizedTextObservation.boundingBox` is **normalized 0..1 with a BOTTOM-LEFT origin**, relative to the image. This is the crucial difference from the `[POINT]` path: Vision is **already bottom-left**, matching `displayFrame`, so you do **NOT** flip Y the way the model-pixel code does — multiply normalized coords straight into `displayFrame`:

```swift
// MARK: - Plato — Vision normalized box → global AppKit rect (NO Y flip — Vision is already bottom-left)
func globalScreenRect(forNormalizedVisionBox box: CGRect, in cap: CompanionScreenCapture) -> CGRect {
    let f = cap.displayFrame   // AppKit global, bottom-left
    return CGRect(x: f.minX + box.minX * f.width,
                  y: f.minY + box.minY * f.height,    // bottom-left ↔ bottom-left: no flip
                  width:  box.width  * f.width,
                  height: box.height * f.height)
}
```

> **Why scale "just works":** normalized 0..1 is dimensionless. Going normalized→`displayFrame` (points) skips pixels, so the 1280px downscale and Retina backing scale are both irrelevant.

**Matching (model text won't byte-match OCR):** normalize both sides (lowercase, fold diacritics, strip soft-hyphens, collapse whitespace, drop punctuation), then layer: (1) heading/short-label exact-or-prefix match against a single line (the most common ask: "highlight Methods"); (2) exact normalized substring; (3) **multi-line span** — find the contiguous run of OCR lines whose concatenation best covers the model's tokens and **union their boxes** (`box.union`); (4) fuzzy fallback (token-set / normalized edit distance < ~0.25). For **two-column papers**, cluster observations by `boundingBox.minX` into columns and only union within one column + a contiguous y-run; reject a union wider than ~55% of image width unless the text genuinely spans columns.

**Latency (UNCERTAIN — must measure):** `.accurate` on Apple Silicon over a ~1280px image is plausibly ~100–300ms, but web reports span ~100ms to ~3s by image size/complexity. **Measure on a real Plato screenshot**: wrap `handler.perform` with `CACurrentMediaTime()` (monotonic — *not* `CFAbsoluteTimeGetCurrent`), run on a background queue, **discard the first run** (model warm-up), report the median of several. OCR runs *after* the model names the text (post-turn), so a few hundred ms off-main is acceptable.

**Resolution tension (real):** the LLM capture is downscaled to 1280px for cost/latency, but OCR wants **more** pixels for small dense paper fonts. Consider capturing the **cursor screen at higher/native resolution** specifically for the OCR path while keeping the 1280px capture for the LLM.

**Failure modes:** figures/equations OCR poorly → no match → **fall back to verbal "scroll to it"**, never a wrong box. Off-screen text can't be found (the §4 scroll loop). Multiple matches → prefer highest confidence / largest span / nearest cursor. **Advantage over AX/DOM:** OCR treats rendered *and* native PDFs as pixels, so it works on Preview/Chrome PDFs where AX is sparse.

**Verdict:** **The enabler for documents/papers.** Precise to the text, screenshot-only (no per-app integration), works where AX fails. The right primary path for the paper use case.

### Recommended hybrid resolver

Pick the source by intent, not by app:

```
resolve(highlight request):
  if request is a document/text target (paper section, sentence, heading):
        OCR the (high-res) screenshot, match the model's TEXT → union box   [Strategy iii]
        on no confident match → say "scroll to <text> and I'll highlight it" [§4]
  else if request names an app control (button/menu) AND front app is AX-capable:
        AX resolve label/point → element frame                              [Strategy ii]
        wake Electron first if needed; skip if canvas/GPU app
  else:
        use the model's bounding box                                        [Strategy i, fallback]
```

Every branch ends at a global AppKit `CGRect` → `PlatoHighlight.globalFrame` → renderer. The model communicates *intent + text/label*, not coordinates, wherever possible (§5).

---

## 4. "Scroll to a section" + staleness lifecycle

### Cross-app document structure is NOT readable

- **PDFKit is in-process only.** `PDFDocument(url:)` / `(data:)` give `outlineRoot`, `findString`, `selection.bounds` — but only for a document **Plato itself** opened. There is no API to reach into the `PDFDocument` that Preview/Chrome/Safari already has open in another process (memory-isolated Mach tasks; no IPC). Even if Plato opened its own copy of the same file, coordinates from *its* copy don't map to where the section sits in Preview's window. Informational only — not pixel-actionable.
- **AX is the only live cross-app structural signal, and it's sparse for PDFs.** Preview's PDF view exposes essentially a rendered image area with little per-heading structure; Chrome's PDFium and many Electron viewers are sparse/non-standard. So for documents, the realistic signal is **screenshot + OCR** (§3b-iii).

### The interaction loop (guide → re-capture → highlight)

Because Plato can't scroll for the user (out of scope) and can't see off-screen content:

1. **Reason over the current screenshot.** Model determines the target ("Methods") isn't currently visible.
2. **Speak the instruction** ("scroll down — Methods is a bit further") and optionally show a **downward arrow affordance** (`.directionalArrow(.down, …)`) near the bottom of the screen. This is a *hint*, not an anchored highlight, so staleness doesn't apply.
3. **Re-capture + detect.** Default: **turn-driven** — on the user's next push-to-talk turn, re-capture, re-OCR, check if the heading now appears. Optional opt-in: **bounded polling** — capture the cursor screen every ~600–1000ms for up to ~10s, cheap on-device OCR each frame for the normalized heading; stop on match, timeout, or new turn. (Polling is power-hungry and keeps the screen-recording indicator on — prefer turn-driven.)
4. **"Now visible" = OCR finds the heading** (normalized, allow section-number prefixes like "3. Methods") → box → momentary highlight.
5. **Not found after the window → say "keep scrolling," never point speculatively.**

> **Out of scope (mention only):** `AXUIElementPerformAction(el, kAXScrollToVisibleAction)` and setting `kAXSelectedTextRange` can scroll an app to an element — but that's *actuation*, excluded here, and unavailable for Preview PDFs anyway. See `real-cursor-control.md`.

### Staleness — momentary, not persistent

An absolute-screen-coordinate box is correct only for the exact frame it was computed from; the first scroll/resize/window-move makes it wrong. Since Plato only highlights (never locks the view), staleness is unavoidable and must be designed *around*. Combine three mechanisms; whichever fires first wins:

- **B1 — Time-boxed TTL (floor).** Every highlight self-removes after `timeToLive` (~3–5s) via the §3a expiry timer. Mirrors the existing pointer's ~3s hold (`OverlayWindow.swift:660-668`) and the 1s transient fade (`CompanionManager.swift:1500-1511`).
- **B2 — Re-anchor per turn.** At the top of each new turn / re-capture, `clearAllHighlights()` **before** computing new ones. Coords from turn N are meaningless in turn N+1. (The single-target `detectedElementScreenLocation` already does this implicitly by overwrite, `:1574`; the collection must reset explicitly.) Never carry a highlight across a capture boundary.
- **B4 — Auto-dismiss on first interaction.** Passive global monitors clear all highlights on the first sign the content moved:
  ```swift
  // MARK: - Plato — Dismiss highlights on scroll / mouse-down (passive; cannot consume)
  NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged]) { _ in
      companionManager.clearAllHighlights()   // window moves/resizes manifest as mouse-down + drag
  }
  ```
  Consistent with the app's existing global-input patterns (`GlobalPushToTalkShortcutMonitor`) and the held Accessibility grant. Global monitors are read-only (can't consume) — fine, we only react.

**AX-anchored highlights re-read live (B3) — but only where elements exist.** An `AXUIElement`'s `kAXPosition`/`kAXSize` reflect its *current* frame at read time, so re-querying AX after a scroll is more robust than a frozen box — but only for native controls (not Preview PDFs), the ref can go stale (`kAXErrorInvalidUIElement` on recycled rows → re-resolve), and AX reads are sync IPC (re-read on discrete events, not 60fps). Reserve live re-anchoring for a future "pin this control" affordance; the document MVP treats every highlight as a one-shot box that expires + re-anchors.

**UX recommendation: momentary by default.** A persistent box is *correct only until the first scroll* — which, for "scroll to section," is the very next thing the user does. Momentary also matches the established fly-point-return-clear idiom and is honest about capability (glance + get out of the way). Persistent-until-dismissed is the wrong default.

---

## 5. Protocol / prompt extension

Mirror the existing dual mechanism: **Realtime function calls (preferred)** + **inline text tags (legacy fallback)**. Function calls keep coordinates/text out of the TTS stream and reuse the `.functionCallDone` dispatch (`CompanionManager.swift:2157-2185`). New tools register in `OpenAIRealtimeClient.swift` alongside `point_at_element` (define near `:364-395`, add to the `tools` array at `:491`).

### New Realtime tools

**`highlight_region`** — translucent shaded rectangle (study/include a paper area; or a model-bbox region):
```jsonc
{ "name": "highlight_region",
  "parameters": { "x","y","width","height": integer (screenshot pixels, top-left origin),
                  "color": enum["red","blue","green","yellow"],
                  "style": enum["filled","outline"],          // filled = shade; outline = ring
                  "label": string, "screen": integer (optional, 1-based) },
  "required": ["x","y","width","height","color"] }
```

**`highlight_text`** — *the document enabler*: model names the TEXT, app OCR-resolves the rect:
```jsonc
{ "name": "highlight_text",
  "parameters": { "text": string (visible text / heading to highlight, e.g. "Methods"),
                  "color": enum[...], "label": string },
  "required": ["text","color"] }
```

**`ripple_here`** — expanding "click here" pulse at a point:
```jsonc
{ "name": "ripple_here",
  "parameters": { "x","y": integer (screenshot pixels), "label": string, "screen": integer (optional) },
  "required": ["x","y"] }
```

**`show_scroll_affordance`** — directional arrow for "scroll to a section" (§4):
```jsonc
{ "name": "show_scroll_affordance",
  "parameters": { "direction": enum["up","down","left","right"], "label": string, "screen": integer (optional) },
  "required": ["direction"] }
```

**`spotlight_region`** (Phase 4) — dim everything except a rect; same params as `highlight_region`.

### Dispatch + handlers

Add cases to the `switch name` at `CompanionManager.swift:2169`:
```swift
// MARK: - Plato — Visual highlight tool dispatch
case "highlight_region": applyHighlightRegionDirective(argumentsJSON: argumentsJSON)
case "highlight_text":   applyHighlightTextDirective(argumentsJSON: argumentsJSON)   // async OCR; hop to @MainActor to draw
case "ripple_here":      applyRippleDirective(argumentsJSON: argumentsJSON)
case "show_scroll_affordance": applyScrollAffordanceDirective(argumentsJSON: argumentsJSON)
```
Each handler parses JSON (accept Int or Double like the existing point parser), resolves a `globalFrame` via the §3b chain (model-bbox/OCR/AX), builds a `PlatoHighlight`, and calls `addHighlight(_:)`. `highlight_text` runs OCR off `@MainActor` and hops back to `addHighlight`. Track analytics by label/color/kind (privacy-first, like `SkillyAnalytics.trackElementPointed`).

### Inline text-tag fallbacks

Parse alongside `parsePointDirective` (`:1649-1703`), gated like `[POINT]` to fire only when no tool call arrived:
- `[HIGHLIGHT:x,y,w,h:color:label:screenN]`
- `[HItext:Methods:green]` (or reuse `[HIGHLIGHT]` with a text payload)
- `[RIPPLE:x,y:label:screenN]`, `[SCROLL:down:label]`

(SKILL.md vocabulary entries already ban embedded `[POINT:` tags — `SkillValidation.swift:257-260`; extend the banned-pattern check to the new tags so skills emit tools, not raw tags.)

### System-prompt instruction additions (`SkillPromptComposer`)

Extend the Layer-5 pointing instruction (`SkillPromptComposer.swift:205-213`, composed at `:116-120`), keyed by the skill's `pointingMode` (`SkillMetadata.swift:6-10`, default `.always`, `:353-363`). Add, after the existing point guidance:

> "Beyond pointing, you can emphasize regions visually. To highlight an area of a document or paper for the user to study or include, prefer **`highlight_text`** with the exact visible text or heading — never guess pixel coordinates for text. To shade or ring an arbitrary region, call **`highlight_region`**. To emphasize a click target, call **`ripple_here`**. If the thing the user needs is **not currently visible** (scrolled off), call **`show_scroll_affordance`** with the direction and tell them to scroll; once they scroll and it's visible, highlight it. Always speak normally in addition to any highlight tool — the tool augments speech, never replaces it. Highlights are momentary; do not rely on them persisting. Never mention coordinates, colors-as-numbers, or tool names in speech."

Scale aggressiveness by `pointingMode` exactly as the existing pointing layer does (`always` → highlight liberally; `minimal` → only on explicit request).

---

## 6. Capability-gap table

| Capability | Plato has it? | Notes |
|---|---|---|
| Full-screen click-through overlay window | ✅ | `OverlayWindow` per screen, `level=.screenSaver`, `ignoresMouseEvents` |
| SwiftUI shape-rendering surface (ZStack + 60fps Timer) | ✅ | `BlueCursorView` — add a `ForEach` of highlight views |
| Pixel→global-AppKit coordinate chain | ✅ | `mapScreenshotPixelCoordinateToGlobalScreenPoint` (handles w/h identically) |
| Global-AppKit→overlay-local conversion | ✅ | `convertScreenPointToSwiftUICoordinates` (extend to whole rect) |
| Per-turn screen capture metadata (displayFrame, pixel dims) | ✅ | `CompanionScreenCapture`, downscaled 1280px, no Retina scaling |
| Tool-call protocol + dispatch | ✅ | `point_at_element` pattern — add tools + switch cases |
| Accessibility permission (read element frames) | ✅ | Held for window shrinking; no new prompt |
| Screen Recording permission (capture for OCR) | ✅ | Already used for screenshots |
| Momentary lifecycle precedent (fly→hold→clear) | ✅ | Reuse for highlight TTL |
| Translucent rect / ripple / arrow / spotlight shapes | ❌ | **Build** (§3a) |
| Highlight state collection + expiry timer | ❌ | **Build** — `activeHighlights: [PlatoHighlight]` |
| Model bounding-box region tag (w,h) | ❌ | **Build** (§3b-i) — cheap, imprecise |
| Vision-framework OCR text→rect resolver | ❌ | **Build** (§3b-iii) — the paper enabler; `import Vision` |
| AX element-frame resolver (hit-test + label search) | ❌ | **Build** (§3b-ii) — share with `real-cursor-control.md` |
| Electron AX wake (`AXManualAccessibility`) | ❌ | **Build** — for VS Code/Slack/etc. controls |
| Scroll-to-section guide loop (re-capture + OCR detect) | ❌ | **Build** (§4) |
| Scroll/mouse-down auto-dismiss monitor | ❌ | **Build** (§4 B4) |
| New prompt/tool grammar + SkillPromptComposer layer | ❌ | **Build** (§5) |

---

## 7. Recommended phasing (low-risk first)

| Phase | Deliverable | Localization source | Risk |
|---|---|---|---|
| **1** | `PlatoHighlight` model + `activeHighlights` + `PlatoHighlightView` (filled/outline rect + **ripple pulse**) + expiry timer; `highlight_region` + `ripple_here` tools. Drive alongside the existing `[POINT]` cursor. | Model bounding box (i) | **Low** — pure additive rendering, reuses coordinate chain & overlay; high "wow" |
| **2** | `ScreenshotTextRecognizer` (Vision OCR) + matcher + `globalScreenRect(forNormalizedVisionBox:)`; `highlight_text` tool. **Paper/section highlighting.** | OCR text (iii) | **Low–Med** — off-main OCR, measure latency; matching tuning |
| **3** | `AXElementResolver` (hit-test + label DFS + frame read + Electron wake); route app-control highlights to a precise ring. | AX (ii) | **Med** — AX coverage/threading care; share resolver with cursor-control doc |
| **4** | Spotlight/dim mask; `show_scroll_affordance` + scroll-to-section re-capture/OCR loop; lifecycle polish (per-turn reset B2 + scroll/mouse auto-dismiss B4). | all | **Med** — spotlight compositing cost; polling power budget |

Phases 1–2 deliver both headline use cases (paper highlight + rough region) with zero new permissions and no AX risk. Phase 3 adds button-precision; Phase 4 adds the scroll loop and lifecycle polish.

---

## 8. Files likely touched

All Plato additions marked `// MARK: - Plato` per repo convention; `import Combine` wherever `@Published` is used. **Do not run `xcodebuild`** (invalidates TCC) — validate via Xcode build/run.

**New files:**
- `PlatoHighlight.swift` — `PlatoHighlight` value type + `Kind`/`ArrowDirection` enums.
- `PlatoHighlightView.swift` — the shape views (`filledRegion`/`strokedRegion`/`ripplePulse`/`directionalArrow`/`spotlight`), `ArrowShape`, `SpotlightMask`, global→local rect conversion. *(New `leanring-buddy/*.swift` files auto-compile via the project's `PBXFileSystemSynchronizedRootGroup` — no `project.pbxproj` edits.)*
- `ScreenshotTextRecognizer.swift` — `import Vision`; OCR + normalized matcher + multi-line/column union + `globalScreenRect(forNormalizedVisionBox:)` (Phase 2).
- `AXElementResolver.swift` — element-at-position, label DFS, `kAXPosition`/`kAXSize` read, `appKitRectFromAXFrame`, Electron wake (Phase 3; **share with `real-cursor-control.md`**).

**Modified files:**
- `CompanionManager.swift` — `activeHighlights` + `addHighlight`/`clearAllHighlights` (near `:25-48`); new tool dispatch cases (at `:2169`); `applyHighlightRegionDirective`/`applyHighlightTextDirective`/`applyRippleDirective`/`applyScrollAffordanceDirective`; the model-pixel-rect→global helper extending `mapScreenshotPixelCoordinateToGlobalScreenPoint` (`:1720-1734`); inline-tag parsers alongside `parsePointDirective` (`:1649-1703`); per-turn `clearAllHighlights()` reset.
- `OverlayWindow.swift` — `ForEach(activeHighlights)` in the `BlueCursorView` ZStack (~`:349`); `startHighlightExpirationTimer()` in `onAppear`; per-screen filter helper.
- `OpenAIRealtimeClient.swift` — new tool definitions near `:364-395`; add to `tools` array at `:491`.
- `SkillPromptComposer.swift` — extend the Layer-5 pointing instruction (`:205-213`) to teach the highlight/text/ripple/scroll tools.
- `SkillValidation.swift` — extend the banned inline-tag check (`:257-260`) to the new tags.
- `SkillyAnalytics.swift` — `trackRegionHighlighted` / `trackTextHighlighted` (label/color/kind, no content).
- *(Phase 4, optional)* a small global `NSEvent` monitor (in `CompanionManager` or a dedicated `HighlightDismissalMonitor.swift`) for scroll/mouse-down auto-dismiss.

---

## 9. Open questions / risks

1. **OCR latency (UNCERTAIN — must measure).** `.accurate` over a real ~1280px Plato screenshot on the target Apple Silicon: assumed ~100–300ms but reports range to ~3s. Measure with `CACurrentMediaTime()` off-main, discard warm-up run, median of several. Decides whether OCR is per-turn-only or can support the bounded scroll-poll loop.
2. **OCR resolution tension.** The 1280px LLM capture hurts small dense paper fonts. Capturing the cursor screen at native res *for OCR only* adds capture cost/complexity — worth it? Quantify accuracy delta on a real two-column PDF.
3. **`highlight_text` matching robustness.** Two-column union heuristics, equations/figures, repeated phrases, hyphenation. Risk of confidently highlighting the wrong paragraph — needs a confidence floor below which Plato says "I can't pinpoint that" rather than guessing.
4. **Electron wake side effects & timing.** `AXManualAccessibility` builds the tree async (poll ~200–500ms) — adds latency to the first control highlight in VS Code/Slack. `AXEnhancedUserInterface` fallback can reflow native windows; verify it's never needed for our target Electron versions (all ≥23 today).
5. **AX threading on the main actor.** Keeping the DFS on `@MainActor` risks a UI hitch if a target app is slow to answer IPC. Need a tight `AXUIElementSetMessagingTimeout` and possibly a dedicated serial AX actor — measure worst-case stall on a heavy app (Xcode, browser).
6. **Spotlight compositing cost.** A full-screen animated dim layer over the 60fps overlay may stutter. Prototype on a multi-monitor Retina setup before committing to Phase 4.
7. **Multi-display region spanning.** A highlight straddling two screens draws only on the center screen in v1. Acceptable, or split the rect per overlay window?
8. **Shared AX resolver ownership.** If `real-cursor-control.md` ships, both docs want `AXElementResolver.swift`. Coordinate so it's built once (this doc reads frames; that doc also acts) — avoid two divergent copies.
9. **Color accessibility.** Red/green shading is the obvious default but fails red-green color blindness; pair every color with the outline + label, don't rely on hue alone.
