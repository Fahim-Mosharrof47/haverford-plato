# Visual Pointing & Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Plato's overlay the ability to *highlight* things on screen — translucent shaded rectangles, a "click here" ripple pulse, a scroll/arrow affordance, and a spotlight/dim mask — driven by the model so it can highlight a paper section to study, ring the right button in unfamiliar software, and guide the user to scroll to off-screen content.

**Architecture:** Plato already hosts a full-screen, click-through, per-screen `NSWindow` with a SwiftUI cursor view and a function-call pointing pipeline (`point_at_element`). This feature is **purely additive**: a new `activeHighlights` collection on `CompanionManager`, new SwiftUI shape views in the existing overlay, three localization strategies that all end at one global-AppKit `CGRect` (model bounding-box → OCR text resolution → Accessibility element frame), and new Realtime tools that mirror the `point_at_element` mechanism. **No new windows, no new permissions, no clicking or cursor control** (actuation is covered separately in `docs/research/real-cursor-control.md` and is out of scope here).

**Tech Stack:** Swift 6 / SwiftUI / AppKit (`NSWindow`, `NSHostingView`), the OpenAI Realtime function-call protocol, Apple's **Vision** framework (`VNRecognizeTextRequest`, macOS 14.2 classic API), the **Accessibility** API (`AXUIElement…`), and the existing ScreenCaptureKit capture pipeline. Reference spec: `docs/research/visual-pointing-highlighting.md`.

## Global Constraints

- **Deployment target is macOS 14.2** — use the classic `VNRecognizeTextRequest` + `VNImageRequestHandler` (the async `RecognizeTextRequest` struct is macOS 15+). Do not use macOS 15-only APIs.
- **Always `import Combine`** in any file that uses `@Published` (`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` enforces explicit module imports).
- **Mark every Plato addition** with `// MARK: - Plato` for merge hygiene; changes to existing (upstream) files must be additive.
- **New `leanring-buddy/*.swift` files auto-compile** via the project's `PBXFileSystemSynchronizedRootGroup` (Xcode 16, objectVersion 77) — no `project.pbxproj` edits. New `leanring-buddyTests/*.swift` files likewise join the test target automatically.
- **Do NOT run `xcodebuild`** from the terminal — it invalidates TCC permissions. See the Testing & Verification Model below.
- **Naming:** clear and specific, no abbreviations (`screenshotWidthInPixels`, not `w`). Match the surrounding code's idiom.
- **Do not** fix the known non-blocking warnings (Swift 6 concurrency, deprecated `onChange`), add features beyond this plan, or rename the project/scheme.
- **AX coordinate facts (verified, from the spec):** AX geometry is global **top-left-origin points** anchored to the **primary (menu-bar) screen** — no `backingScaleFactor`/pixel scaling. `AXUIElementCopyElementAtPosition` takes C `Float` (must write `Float(...)`). The AX API is **not thread-safe** — keep all AX calls on the main thread. Treat both `.success` and `-25205` from setting `AXManualAccessibility` as "applied."
- **Vision coordinate fact (verified):** `VNRecognizedTextObservation.boundingBox` is normalized `0…1`, **bottom-left origin** — same handedness as `displayFrame`, so OCR rects need **no Y-flip** (unlike the model-pixel path).

## Testing & Verification Model

The implementer **cannot compile or run the app** (no `xcodebuild`; TCC). Therefore:

- **Test framework:** the codebase uses **Swift Testing** (`import Testing` / `@Test` / `#expect`), not XCTest. The XCTest-style snippets in the tasks below are illustrative — **write the tests as Swift Testing** (`struct …Tests { @Test func … { #expect(a == b) } }`, `#expect(x == nil)` for nil checks). Add `import CoreGraphics` where `CGRect`/`CGPoint` are used.
- **Pure-logic steps** ship as real Swift Testing cases in `leanring-buddyTests/`. At each `[verify-test]` step, the **developer runs the test target in Xcode (⌘U)**. "Expected: PASS/FAIL" means the developer confirms the result in Xcode's test navigator.
- **UI / system-integration steps** are verified by **build & run (⌘R)** plus the described manual observation. "Expected:" describes exactly what the developer should see on screen.
- **Every code step shows the full code.** The implementer writes the code; a checkpoint review + the developer's Xcode run together close each task.

---

## File Structure

**New source files (`leanring-buddy/`):**

| File | Responsibility |
|---|---|
| `PlatoHighlight.swift` | The `PlatoHighlight` value type, its `Kind`/`ArrowDirection` enums, and the color-name → `Color` mapping. Pure model. |
| `HighlightGeometry.swift` | Pure coordinate math: screenshot-pixel-rect → global AppKit rect; Vision-normalized-box → global AppKit rect; global rect → overlay-local SwiftUI rect; AX top-left frame → AppKit rect. **Unit-tested.** |
| `PlatoHighlightView.swift` | The SwiftUI shapes (`filledRegion`/`strokedRegion`/`ripplePulse`/`directionalArrow`/`spotlight`), `ArrowShape`, `SpotlightMask`. Renders one `PlatoHighlight`. |
| `ScreenshotTextRecognizer.swift` | `OCRLine` model, the Vision OCR wrapper (`recognizeText(in:)`), and `ScreenshotTextMatcher` (pure text→box matching with multi-line union). Matcher is **unit-tested**. |
| `AXElementResolver.swift` *(Phase 3)* | Accessibility element resolution: hit-test a point, search the focused app's tree by label, read the element frame, Electron wake. Pure flip helper is **unit-tested**. |

**New test files (`leanring-buddyTests/`):**

| File | Covers |
|---|---|
| `HighlightGeometryTests.swift` | All four `HighlightGeometry` conversions. |
| `ScreenshotTextMatcherTests.swift` | Normalization, single-line, and multi-line-union matching. |
| `AXElementResolverGeometryTests.swift` *(Phase 3)* | The AX top-left → AppKit bottom-left flip. |

**Modified files:**

| File | Change |
|---|---|
| `CompanionManager.swift` | `activeHighlights` state + `addHighlight`/`clearAllHighlights` + expiry timer; tool-arg decode helpers; the `apply*Directive` handlers; tool dispatch cases (`:2168`); per-turn + session-stop clears (`:1807`, `:2199`, `:2440`). |
| `OverlayWindow.swift` | Highlight `ForEach` layer in `BlueCursorView` (`:199` ZStack); per-screen filter helper. |
| `OpenAIRealtimeClient.swift` | New tool definitions near `:364-449`; append them to the `tools` array (`:491`). |
| `SkillPromptComposer.swift` | Extend the Layer-5 pointing instruction (`:205-214`) to teach the highlight tools. |
| `SkillValidation.swift` | Extend the banned inline-tag check (`:257-261`) to the new tags. |

---

## PHASE 1 — Rendering foundation + model-bounding-box highlights (the low-risk core)

Delivers: shaded/outlined rectangles and a "click here" ripple, driven end-to-end by the model using bounding boxes it estimates from the screenshot. Reuses the entire existing coordinate chain. After Phase 1, both "shade roughly this area" and "ripple where to click" work.

---

### Task 1: Pure highlight geometry + model

**Files:**
- Create: `leanring-buddy/HighlightGeometry.swift`
- Create: `leanring-buddy/PlatoHighlight.swift`
- Test: `leanring-buddyTests/HighlightGeometryTests.swift`

**Interfaces:**
- Produces:
  - `enum HighlightGeometry` with static funcs:
    - `globalRectFromScreenshotPixelRect(x:Int, y:Int, width:Int, height:Int, screenshotWidthInPixels:Int, screenshotHeightInPixels:Int, displayFrame:CGRect) -> CGRect`
    - `globalRectFromNormalizedVisionBox(_ box:CGRect, displayFrame:CGRect) -> CGRect`
    - `localRectFromGlobalRect(_ globalFrame:CGRect, screenFrame:CGRect) -> CGRect`
    - `appKitRectFromAXFrame(axOrigin:CGPoint, axSize:CGSize, primaryScreenHeight:CGFloat) -> CGRect`
  - `struct PlatoHighlight: Identifiable` with `kind: Kind`, `globalFrame: CGRect`, `label: String?`, `createdAt: Date`, `timeToLive: TimeInterval`; nested `enum Kind` and `enum ArrowDirection`; static `color(forName:) -> Color`.

- [ ] **Step 1: Write the failing geometry tests**

Create `leanring-buddyTests/HighlightGeometryTests.swift`:

```swift
// MARK: - Plato
import XCTest
@testable import leanring_buddy

final class HighlightGeometryTests: XCTestCase {

    private let primaryDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // A full-image screenshot rect should map to the whole display.
    func testScreenshotFullRectMapsToWholeDisplay() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 1280, height: 800,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    // A box in the TOP-LEFT quarter of the screenshot maps to the TOP-LEFT of the
    // display, which in AppKit (bottom-left origin) is the HIGH-Y half.
    func testScreenshotTopLeftQuarterMapsToTopLeftAppKit() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 640, height: 400,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        // width 640/1280 -> 720; height 400/800 -> 450; top edge at AppKit y=900,
        // so origin.y = 900 - 450 = 450.
        XCTAssertEqual(rect, CGRect(x: 0, y: 450, width: 720, height: 450))
    }

    // Vision box is already bottom-left normalized: no Y flip.
    func testVisionBoxMapsWithoutYFlip() {
        let box = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let rect = HighlightGeometry.globalRectFromNormalizedVisionBox(box, displayFrame: primaryDisplay)
        XCTAssertEqual(rect, CGRect(x: 720, y: 450, width: 720, height: 450))
    }

    // Global AppKit rect -> overlay-local SwiftUI rect (top-left origin) on a
    // secondary screen whose origin is offset.
    func testGlobalRectToLocalRectFlipsAndOffsets() {
        let screenFrame = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        // A 100x100 rect whose AppKit bottom edge is at y=800 (top edge y=900 = top of screen).
        let globalFrame = CGRect(x: 1540, y: 800, width: 100, height: 100)
        let local = HighlightGeometry.localRectFromGlobalRect(globalFrame, screenFrame: screenFrame)
        // x: 1540 - 1440 = 100; top edge -> local y = (0+900) - (800+100) = 0.
        XCTAssertEqual(local, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    // AX frame is top-left points anchored to primary; flip Y only, against primary height.
    func testAXFrameFlipsAgainstPrimaryHeight() {
        let rect = HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: CGPoint(x: 10, y: 50), axSize: CGSize(width: 100, height: 30),
            primaryScreenHeight: 900
        )
        // appKit y = 900 - 50 - 30 = 820.
        XCTAssertEqual(rect, CGRect(x: 10, y: 820, width: 100, height: 30))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Developer action: in Xcode, ⌘U.
Expected: FAIL — `HighlightGeometry` is not defined (compile error).

- [ ] **Step 3: Implement `HighlightGeometry`**

Create `leanring-buddy/HighlightGeometry.swift`:

```swift
// MARK: - Plato
//
//  HighlightGeometry.swift
//  leanring-buddy
//
//  Pure coordinate math for visual highlights. Three coordinate spaces are in
//  play and getting them wrong silently flips/offsets boxes:
//   - Screenshot pixels: TOP-LEFT origin, +Y down (what the model returns).
//   - Vision normalized:  BOTTOM-LEFT origin, 0...1 (what VNRecognizedText gives).
//   - Global AppKit:      BOTTOM-LEFT origin, points (NSEvent.mouseLocation,
//                         NSScreen.frame, displayFrame, the overlay's space).
//  Everything in this file is pure so it can be unit-tested without the app.
//

import CoreGraphics

enum HighlightGeometry {

    /// Screenshot pixel rect (top-left origin) -> global AppKit rect (bottom-left
    /// origin). Mirrors CompanionManager.mapScreenshotPixelCoordinateToGlobalScreenPoint
    /// but for a rect: width/height scale by the same normalization factor as x/y
    /// because all four originate in the same screenshot pixel space.
    static func globalRectFromScreenshotPixelRect(
        x: Int, y: Int, width: Int, height: Int,
        screenshotWidthInPixels: Int, screenshotHeightInPixels: Int,
        displayFrame: CGRect
    ) -> CGRect {
        let safeWidthInPixels = max(screenshotWidthInPixels, 1)
        let safeHeightInPixels = max(screenshotHeightInPixels, 1)

        let clampedX = max(0, min(x, screenshotWidthInPixels))
        let clampedY = max(0, min(y, screenshotHeightInPixels))

        let normalizedX = CGFloat(clampedX) / CGFloat(safeWidthInPixels)
        let normalizedY = CGFloat(clampedY) / CGFloat(safeHeightInPixels)
        let normalizedWidth = CGFloat(max(0, width)) / CGFloat(safeWidthInPixels)
        let normalizedHeight = CGFloat(max(0, height)) / CGFloat(safeHeightInPixels)

        let globalX = displayFrame.minX + (displayFrame.width * normalizedX)
        // The screenshot's TOP edge maps to a HIGH AppKit Y (bottom-left origin).
        let globalTopEdgeY = displayFrame.maxY - (displayFrame.height * normalizedY)
        let globalWidth = displayFrame.width * normalizedWidth
        let globalHeight = displayFrame.height * normalizedHeight
        // Subtract the height to get the bottom-left ORIGIN of the rect.
        return CGRect(x: globalX, y: globalTopEdgeY - globalHeight,
                      width: globalWidth, height: globalHeight)
    }

    /// Vision normalized box (0...1, bottom-left origin) -> global AppKit rect.
    /// No Y flip: Vision and AppKit share bottom-left handedness. Normalized
    /// coordinates are dimensionless, so the 1280px capture downscale and the
    /// Retina backing scale are both irrelevant here.
    static func globalRectFromNormalizedVisionBox(_ box: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + (box.minX * displayFrame.width),
            y: displayFrame.minY + (box.minY * displayFrame.height),
            width: box.width * displayFrame.width,
            height: box.height * displayFrame.height
        )
    }

    /// Global AppKit rect (bottom-left origin) -> overlay-local SwiftUI rect
    /// (top-left origin) for the overlay window covering `screenFrame`. Mirrors
    /// BlueCursorView.convertScreenPointToSwiftUICoordinates but flips the whole
    /// rect: the rect's TOP edge in SwiftUI = its global TOP edge (origin.y + height).
    static func localRectFromGlobalRect(_ globalFrame: CGRect, screenFrame: CGRect) -> CGRect {
        let localX = globalFrame.origin.x - screenFrame.origin.x
        let localY = (screenFrame.origin.y + screenFrame.height) - (globalFrame.origin.y + globalFrame.height)
        return CGRect(x: localX, y: localY, width: globalFrame.width, height: globalFrame.height)
    }

    /// AX element frame (global TOP-LEFT-origin points, anchored to the primary
    /// screen) -> global AppKit rect (bottom-left origin). X is identical; flip Y
    /// only, against the PRIMARY screen height. No pixel/backingScaleFactor math.
    static func appKitRectFromAXFrame(axOrigin: CGPoint, axSize: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        let appKitY = primaryScreenHeight - axOrigin.y - axSize.height
        return CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
    }
}
```

- [ ] **Step 4: Implement `PlatoHighlight`**

Create `leanring-buddy/PlatoHighlight.swift`:

```swift
// MARK: - Plato
//
//  PlatoHighlight.swift
//  leanring-buddy
//
//  The data model for one on-screen teaching highlight. Anchored in GLOBAL
//  AppKit coordinates (bottom-left origin) — the same space as displayFrame and
//  NSEvent.mouseLocation — so the overlay can convert it per screen. Highlights
//  are always momentary (see timeToLive); absolute-coordinate boxes go stale the
//  instant the user scrolls.
//

import SwiftUI

struct PlatoHighlight: Identifiable {
    enum ArrowDirection {
        case up, down, left, right
    }

    enum Kind {
        /// Translucent shaded rectangle — "study / include this area of the paper".
        case filledRegion(color: Color)
        /// Crisp ring with no fill — a tight outline around an app control.
        case strokedRegion(color: Color, lineWidth: CGFloat)
        /// Expanding "click here" pulse centered on the rect.
        case ripplePulse(color: Color)
        /// A directional affordance — "scroll down to the section".
        case directionalArrow(direction: ArrowDirection, color: Color)
        /// Dim the whole screen except this rect, to focus attention.
        case spotlight(dimOpacity: CGFloat)
    }

    let id = UUID()
    let kind: Kind
    /// GLOBAL AppKit frame (bottom-left origin), same space as displayFrame.
    let globalFrame: CGRect
    let label: String?
    let createdAt: Date
    /// Auto-expiry. Always finite — never persistent. Recommend 3–5s.
    let timeToLive: TimeInterval

    /// Maps the model's color name to an intentional, legible highlight color.
    /// Colors are paired with an outline + label by the views, never hue alone,
    /// so red/green remain distinguishable for color-blind users.
    static func color(forName colorName: String?) -> Color {
        switch (colorName ?? "blue").lowercased() {
        case "red":    return Color(hex: "#FF3B30")
        case "green":  return Color(hex: "#34C759")
        case "yellow": return Color(hex: "#FFD60A")
        case "blue":   return Color(hex: "#0A84FF")
        default:       return Color(hex: "#0A84FF")
        }
    }
}
```

> `Color(hex:)` is defined in `DesignSystem.swift` and is in the same module.

- [ ] **Step 5: Run the tests to verify they pass**

Developer action: ⌘U.
Expected: PASS — all five `HighlightGeometryTests` green.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/HighlightGeometry.swift leanring-buddy/PlatoHighlight.swift leanring-buddyTests/HighlightGeometryTests.swift
git commit -m "feat: add PlatoHighlight model and pure HighlightGeometry conversions"
```

---

### Task 2: Highlight state + lifecycle on CompanionManager

**Files:**
- Modify: `leanring-buddy/CompanionManager.swift` (state near the other overlay `@Published` vars; clears at `:1807-1811`, `:2199-2207`, `:2440`)

**Interfaces:**
- Consumes: `PlatoHighlight` (Task 1).
- Produces: `@Published var activeHighlights: [PlatoHighlight]`; `func addHighlight(_:)`; `func clearAllHighlights()`.

- [ ] **Step 1: Add the published state and lifecycle methods**

In `CompanionManager.swift`, near the existing detected-element `@Published` properties (the same group as `detectedElementScreenLocation`), add:

```swift
    // MARK: - Plato — Visual highlights
    /// Momentary teaching highlights drawn by the overlay. Always time-boxed;
    /// cleared at every turn boundary so a stale absolute-coordinate box never
    /// lingers after the user scrolls.
    @Published var activeHighlights: [PlatoHighlight] = []
    private var highlightExpirationTimer: Timer?

    func addHighlight(_ highlight: PlatoHighlight) {
        activeHighlights.append(highlight)
        startHighlightExpirationTimerIfNeeded()
    }

    func clearAllHighlights() {
        guard !activeHighlights.isEmpty || highlightExpirationTimer != nil else { return }
        activeHighlights.removeAll()
        highlightExpirationTimer?.invalidate()
        highlightExpirationTimer = nil
    }

    /// Prunes expired highlights ~5x/sec. Runs only while highlights exist, then
    /// stops itself — no always-on timer. Mirrors the bezier flight's Timer idiom.
    private func startHighlightExpirationTimerIfNeeded() {
        guard highlightExpirationTimer == nil else { return }
        highlightExpirationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                self.activeHighlights.removeAll { now.timeIntervalSince($0.createdAt) > $0.timeToLive }
                if self.activeHighlights.isEmpty {
                    self.highlightExpirationTimer?.invalidate()
                    self.highlightExpirationTimer = nil
                }
            }
        }
    }
```

> `import Combine` is already present in `CompanionManager.swift` (it has other `@Published` vars) — confirm it stays.

- [ ] **Step 2: Clear highlights at the push-to-talk per-turn reset**

In the push-to-talk turn-reset block (around `CompanionManager.swift:1807-1811`, where `currentTurnScreenCaptures = []` and `didReceivePointToolCallForCurrentTurn = false`), add immediately after those lines:

```swift
        // MARK: - Plato — drop last turn's highlights before a new turn
        clearAllHighlights()
```

- [ ] **Step 3: Clear highlights at the VAD (live-tutor) per-turn reset**

In the `.speechStarted` reset block (around `CompanionManager.swift:2199-2207`, the second site where `currentTurnScreenCaptures = []` appears, right after `clearDetectedElementLocation()`), add:

```swift
            // MARK: - Plato — drop last turn's highlights before a new turn
            clearAllHighlights()
```

- [ ] **Step 4: Clear highlights on session stop**

Near `CompanionManager.swift:2440` (the `clearDetectedElementLocation()` call in the session-teardown path), add immediately after it:

```swift
        // MARK: - Plato
        clearAllHighlights()
```

- [ ] **Step 5: Verify it builds**

Developer action: ⌘B (build only — no behavior to observe yet).
Expected: Build succeeds; no new warnings beyond the known-tolerated ones.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/CompanionManager.swift
git commit -m "feat: add activeHighlights state, expiry timer, and per-turn clears"
```

---

### Task 3: Render highlights in the overlay

**Files:**
- Create: `leanring-buddy/PlatoHighlightView.swift`
- Modify: `leanring-buddy/OverlayWindow.swift` (`BlueCursorView` ZStack at `:199`)

**Interfaces:**
- Consumes: `PlatoHighlight`, `HighlightGeometry.localRectFromGlobalRect` (Task 1); `companionManager.activeHighlights` (Task 2).
- Produces: `struct PlatoHighlightView: View`; `struct ArrowShape: Shape`; `struct SpotlightMask: Shape`.

- [ ] **Step 1: Implement the highlight views**

Create `leanring-buddy/PlatoHighlightView.swift`:

```swift
// MARK: - Plato
//
//  PlatoHighlightView.swift
//  leanring-buddy
//
//  Renders one PlatoHighlight inside the existing click-through overlay window.
//  Because the host NSWindow is full-screen and ignoresMouseEvents, nothing here
//  can intercept input — every shape is purely visual. Coordinates arrive in
//  GLOBAL AppKit space and are converted to overlay-local SwiftUI space here.
//

import SwiftUI

struct PlatoHighlightView: View {
    let highlight: PlatoHighlight
    /// This overlay window's screen frame, in global AppKit coordinates.
    let screenFrame: CGRect

    @State private var rippleProgress: CGFloat = 0

    var body: some View {
        let localRect = HighlightGeometry.localRectFromGlobalRect(highlight.globalFrame, screenFrame: screenFrame)

        Group {
            switch highlight.kind {
            case .filledRegion(let color):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(color.opacity(0.95), lineWidth: 2)
                    )
                    .frame(width: localRect.width, height: localRect.height)
                    .position(x: localRect.midX, y: localRect.midY)

            case .strokedRegion(let color, let lineWidth):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: localRect.width, height: localRect.height)
                    .position(x: localRect.midX, y: localRect.midY)

            case .ripplePulse(let color):
                // Expanding "click here" pulse. A repeating SwiftUI animation
                // loops cleanly and auto-stops when the view leaves the tree on TTL.
                Circle()
                    .stroke(color, lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .scaleEffect(1.0 + (rippleProgress * 1.6))
                    .opacity(Double(1.0 - rippleProgress))
                    .position(x: localRect.midX, y: localRect.midY)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            rippleProgress = 1.0
                        }
                    }

            case .directionalArrow(let direction, let color):
                ArrowShape(direction: direction)
                    .fill(color.opacity(0.95))
                    .frame(width: 40, height: 40)
                    .shadow(color: color.opacity(0.5), radius: 8)
                    .position(x: localRect.midX, y: localRect.midY)

            case .spotlight(let dimOpacity):
                // Dim the entire overlay EXCEPT the highlight rect (even-odd cutout).
                SpotlightMask(holeRect: localRect)
                    .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A chevron arrow pointing in one of four directions, drawn inside its frame.
struct ArrowShape: Shape {
    let direction: PlatoHighlight.ArrowDirection

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .down:
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .up:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .right:
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Full overlay rect with a rounded-rect hole punched out via the even-odd rule.
struct SpotlightMask: Shape {
    let holeRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: holeRect, cornerSize: CGSize(width: 8, height: 8))
        return path
    }
}
```

- [ ] **Step 2: Add the highlight layer to `BlueCursorView`**

In `OverlayWindow.swift`, inside the `ZStack` in `BlueCursorView.body` (starts at `:199`), add the highlight `ForEach` **after** the response/onboarding bubble views and **before** the cursor triangle view (around `:349`, so the cursor renders on top):

```swift
            // MARK: - Plato — Visual highlight layer
            ForEach(companionManager.activeHighlights.filter { highlightBelongsOnThisScreen($0) }) { highlight in
                PlatoHighlightView(highlight: highlight, screenFrame: screenFrame)
            }
```

Then add the per-screen filter helper next to `convertScreenPointToSwiftUICoordinates` (`:520`), mirroring the existing element per-screen test at `:453`:

```swift
    // MARK: - Plato
    /// Only draw a highlight on the overlay window whose screen contains the
    /// highlight's center (matches the cursor's per-screen filter at :444-459).
    private func highlightBelongsOnThisScreen(_ highlight: PlatoHighlight) -> Bool {
        screenFrame.contains(CGPoint(x: highlight.globalFrame.midX, y: highlight.globalFrame.midY))
    }
```

- [ ] **Step 3: Temporarily inject a debug highlight to verify rendering**

Add this **temporary** debug code at the end of `BlueCursorView.body`'s existing `.onAppear` (the one that calls `startTrackingCursor()`), to be removed in Step 5:

```swift
            // TEMP DEBUG — remove in Step 5
            if companionManager.activeHighlights.isEmpty {
                companionManager.addHighlight(PlatoHighlight(
                    kind: .filledRegion(color: PlatoHighlight.color(forName: "red")),
                    globalFrame: CGRect(x: screenFrame.midX - 150, y: screenFrame.midY - 100, width: 300, height: 200),
                    label: "debug",
                    createdAt: Date(),
                    timeToLive: 8.0
                ))
                companionManager.addHighlight(PlatoHighlight(
                    kind: .ripplePulse(color: PlatoHighlight.color(forName: "blue")),
                    globalFrame: CGRect(x: screenFrame.midX, y: screenFrame.midY, width: 0, height: 0),
                    label: nil, createdAt: Date(), timeToLive: 8.0
                ))
            }
```

- [ ] **Step 4: Build, run, and verify the shapes draw**

Developer action: ⌘R, then trigger the overlay (push-to-talk, or however the overlay first appears).
Expected: A translucent **red** rounded rectangle (~300×200) appears centered on screen with a solid red border, and a **blue** ring pulses outward from screen center, both fading away after ~8s. They must be **click-through** (you can click apps behind them).

- [ ] **Step 5: Remove the temporary debug code**

Delete the `// TEMP DEBUG` block from Step 3.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/PlatoHighlightView.swift leanring-buddy/OverlayWindow.swift
git commit -m "feat: render PlatoHighlight shapes in the overlay (filled/stroked/ripple/arrow/spotlight)"
```

---

### Task 4: Register the `highlight_region` and `ripple_here` Realtime tools

**Files:**
- Modify: `leanring-buddy/OpenAIRealtimeClient.swift` (tool defs near `:364-449`; tools array at `:491`)

**Interfaces:**
- Produces: two `[String: Any]` tool definitions appended to the session `tools` array, so `.functionCallDone` will deliver `highlight_region` and `ripple_here`.

- [ ] **Step 1: Define the two tools**

In `OpenAIRealtimeClient.updateSessionConfiguration`, after the `controlPomodoroTool` definition (`:449`), add:

```swift
        // MARK: - Plato — highlight_region tool
        // Draws a translucent shaded (or outlined) rectangle over a region of the
        // user's screen. Like point_at_element, this AUGMENTS speech and is never a
        // replacement for it. The model gives the region in screenshot pixels.
        let highlightRegionTool: [String: Any] = [
            "type": "function",
            "name": "highlight_region",
            "description": "Draw a colored rectangle over a region of the user's screen to highlight an area — for example a section of a paper to study, or a panel to look at. ONLY an addition to your spoken response, never a replacement: always speak normally too. Prefer highlight_text when highlighting specific visible text. Do not mention coordinates, colors-as-data, or this tool's name in speech.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "integer", "description": "Left edge X in screenshot pixels. Origin (0,0) is the image's top-left; x increases rightward."],
                    "y": ["type": "integer", "description": "Top edge Y in screenshot pixels. Origin (0,0) is the image's top-left; y increases downward."],
                    "width": ["type": "integer", "description": "Region width in screenshot pixels."],
                    "height": ["type": "integer", "description": "Region height in screenshot pixels."],
                    "color": ["type": "string", "enum": ["red", "blue", "green", "yellow"], "description": "Highlight color."],
                    "style": ["type": "string", "enum": ["filled", "outline"], "description": "'filled' shades the area; 'outline' draws only a ring. Defaults to filled."],
                    "label": ["type": "string", "description": "Short 1-3 word name of what is being highlighted."],
                    "screen": ["type": "integer", "description": "1-based screen index when multiple screenshots were provided. Omit for the cursor's screen."]
                ],
                "required": ["x", "y", "width", "height", "color"]
            ]
        ]

        // MARK: - Plato — ripple_here tool
        // Emphasizes a single point with an expanding "click here" pulse.
        let rippleHereTool: [String: Any] = [
            "type": "function",
            "name": "ripple_here",
            "description": "Show an expanding 'click here' pulse at a point on the user's screen, to draw the eye to a specific spot the user should click or look at. ONLY an addition to your spoken response, never a replacement. Do not mention coordinates or this tool's name in speech.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "integer", "description": "X in screenshot pixels (top-left origin)."],
                    "y": ["type": "integer", "description": "Y in screenshot pixels (top-left origin)."],
                    "label": ["type": "string", "description": "Short 1-3 word name of the target."],
                    "screen": ["type": "integer", "description": "1-based screen index; omit for the cursor's screen."]
                ],
                "required": ["x", "y"]
            ]
        ]
```

- [ ] **Step 2: Append the tools to the session**

Change the `tools` array (`:491`) from:

```swift
            "tools": [pointAtElementTool, searchScholarTool, controlPomodoroTool],
```

to:

```swift
            "tools": [pointAtElementTool, searchScholarTool, controlPomodoroTool, highlightRegionTool, rippleHereTool],
```

- [ ] **Step 3: Verify it builds**

Developer action: ⌘B.
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add leanring-buddy/OpenAIRealtimeClient.swift
git commit -m "feat: register highlight_region and ripple_here Realtime tools"
```

---

### Task 5: Dispatch + handlers for `highlight_region` and `ripple_here`

**Files:**
- Modify: `leanring-buddy/CompanionManager.swift` (handlers near the pointing handlers `:1585-1647`; dispatch switch at `:2168`)

**Interfaces:**
- Consumes: `addHighlight` (Task 2), `HighlightGeometry` + `PlatoHighlight` (Task 1), existing `resolveTargetScreenCapture(for:)` (`:1705`), `mapScreenshotPixelCoordinateToGlobalScreenPoint` (`:1720`), `ParsedPointDirective` (`:1555`), `openAIRealtimeClient.sendFunctionCallOutput(callId:output:)`.
- Produces: `decodeToolArguments(_:) -> [String: Any]?`, `integerValue(from:) -> Int?`, `applyHighlightRegionDirective(argumentsJSON:)`, `applyRippleDirective(argumentsJSON:)`.

- [ ] **Step 1: Add shared tool-argument decode helpers**

In `CompanionManager.swift`, near the pointing directive helpers (after `applyPointDirectiveFromToolCall`, `:1647`), add:

```swift
    // MARK: - Plato — Tool argument decoding helpers (shared by highlight tools)
    private func decodeToolArguments(_ argumentsJSON: String) -> [String: Any]? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Accepts Int or Double (the model sometimes emits 12.0 for an integer field).
    private func integerValue(from value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return nil
    }
```

- [ ] **Step 2: Add the `highlight_region` handler**

Immediately after the helpers from Step 1, add:

```swift
    // MARK: - Plato — highlight_region handler
    private func applyHighlightRegionDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let x = integerValue(from: arguments["x"]),
              let y = integerValue(from: arguments["y"]),
              let width = integerValue(from: arguments["width"]),
              let height = integerValue(from: arguments["height"]) else {
            return
        }
        let colorName = arguments["color"] as? String
        let style = (arguments["style"] as? String) ?? "filled"
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])

        // Reuse the pointing resolver, which only reads oneBasedScreenNumber.
        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: x, screenshotYInPixels: y,
            elementLabel: label ?? "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = resolveTargetScreenCapture(for: resolverDirective) else { return }

        let globalFrame = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: x, y: y, width: width, height: height,
            screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
            displayFrame: targetScreenCapture.displayFrame
        )

        let highlightColor = PlatoHighlight.color(forName: colorName)
        let kind: PlatoHighlight.Kind = (style == "outline")
            ? .strokedRegion(color: highlightColor, lineWidth: 2.5)
            : .filledRegion(color: highlightColor)

        addHighlight(PlatoHighlight(kind: kind, globalFrame: globalFrame,
                                    label: label, createdAt: Date(), timeToLive: 4.0))
    }
```

- [ ] **Step 3: Add the `ripple_here` handler**

Immediately after the `highlight_region` handler, add:

```swift
    // MARK: - Plato — ripple_here handler
    private func applyRippleDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let x = integerValue(from: arguments["x"]),
              let y = integerValue(from: arguments["y"]) else {
            return
        }
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])

        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: x, screenshotYInPixels: y,
            elementLabel: label ?? "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = resolveTargetScreenCapture(for: resolverDirective) else { return }

        let globalPoint = mapScreenshotPixelCoordinateToGlobalScreenPoint(
            screenshotXInPixels: x, screenshotYInPixels: y, screenCapture: targetScreenCapture
        )
        // Zero-size rect: the ripple view centers on its midpoint.
        let globalFrame = CGRect(x: globalPoint.x, y: globalPoint.y, width: 0, height: 0)
        addHighlight(PlatoHighlight(kind: .ripplePulse(color: PlatoHighlight.color(forName: "blue")),
                                    globalFrame: globalFrame, label: label,
                                    createdAt: Date(), timeToLive: 4.0))
    }
```

- [ ] **Step 4: Wire the dispatch cases**

In the `.functionCallDone` `switch name` (`:2168`), add these cases before `default:`:

```swift
            case "highlight_region":
                applyHighlightRegionDirective(argumentsJSON: argumentsJSON)
                // Reuse the point_at_element follow-up safety net: marks that a
                // visual tool fired (so the inline-tag fallback is skipped and a
                // tool-only response still triggers a forced spoken follow-up),
                // and closes THIS call now without eliciting a new response.
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
            case "ripple_here":
                applyRippleDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
```

> **Why `sendFunctionCallOutput` (not `sendToolResultAndContinue`):** the former closes the function call without triggering a new model response — verified by its use in the forced-follow-up at `:2089`. `sendToolResultAndContinue` (used by `search_scholar`/`control_pomodoro`) deliberately elicits a spoken follow-up; we don't want that here because the model already spoke. Closing each call immediately also handles multiple visual tools in one turn (each closes its own `callId`), avoiding the single-slot `pendingToolCallIdForCurrentTurn` collision.

- [ ] **Step 5: Build, run, and verify end-to-end**

Developer action: ⌘R. With a paper or any app on screen, push-to-talk and say: *"Highlight the area around the top toolbar."* Then: *"Show me where to click to save."*
Expected: A translucent rectangle appears over roughly the named area (~4s, then fades); a blue ripple pulses at roughly the save control. The model still **speaks** its explanation in both cases. No double/echoed responses.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/CompanionManager.swift
git commit -m "feat: dispatch + handlers for highlight_region and ripple_here tools"
```

---

### Task 6: Teach the tools in the prompt + ban the inline tags

**Files:**
- Modify: `leanring-buddy/SkillPromptComposer.swift` (`pointingModeInstruction`, `:205-214`)
- Modify: `leanring-buddy/SkillValidation.swift` (banned-tag check, `:257-261`)

**Interfaces:**
- Consumes: nothing new — edits prompt text + validation.

- [ ] **Step 1: Extend the Layer-5 pointing instruction**

In `SkillPromptComposer.pointingModeInstruction` (`:205`), append a shared highlight clause to each returned string. Replace the `switch mode` body so each case ends with the same highlight guidance:

```swift
    private static func pointingModeInstruction(mode: PointingMode, targetApp: String) -> String {
        let highlightGuidance = " Beyond pointing, you can emphasize regions visually. To highlight a region of a document or paper for the user to study or include, call highlight_region (or, once you know the exact visible text, highlight_text). To draw the eye to a single click target, call ripple_here. If the thing the user needs is scrolled off-screen, call show_scroll_affordance with the direction and tell them to scroll; highlight it once it becomes visible. Every highlight only ever ADDS to your spoken answer — always speak normally too. Highlights are momentary; never rely on them persisting. Never say coordinates, colors-as-data, or tool names aloud."

        switch mode {
        case .always:
            return "When helping with \(targetApp), aggressively point at UI elements using the vocabulary above. The user is learning and needs visual guidance. Err on the side of pointing rather than not pointing." + highlightGuidance
        case .whenRelevant:
            return "When helping with \(targetApp), point at UI elements when it would genuinely help the user find something they're looking for. Don't point at things that are obvious or that the user is already looking at." + highlightGuidance
        case .minimal:
            return "When helping with \(targetApp), only point at UI elements when the user explicitly asks where something is or is clearly lost. Default to verbal descriptions unless pointing adds significant clarity." + highlightGuidance
        }
    }
```

> `highlight_text` and `show_scroll_affordance` are introduced in Phases 2 and 4; naming them now is harmless (the model simply won't have those tools until then) and avoids re-editing this string. If you prefer strict alignment, drop those two clauses until their phases land.

- [ ] **Step 2: Update the SkillPromptComposer test for the new clause**

`SkillPromptComposerTests.swift` already asserts on the composed prompt. Add (or extend) a test that the highlight guidance is present:

```swift
    // MARK: - Plato
    func testComposedPromptIncludesHighlightGuidance() {
        let composed = composedPromptForTestSkill()   // reuse the suite's existing helper
        XCTAssertTrue(composed.contains("highlight_region"))
        XCTAssertTrue(composed.contains("ripple_here"))
    }
```

> If the suite has no `composedPromptForTestSkill()` helper, inline the existing suite's standard compose call used by its other tests.

- [ ] **Step 3: Ban the new inline tags in skill vocabulary**

In `SkillValidation.swift`, extend the banned-tag check (`:257`). Replace:

```swift
            if lowercasedVocabularyName.contains("[point:") {
                violations.append(
                    "Vocabulary entry '\(escapedVocabularyName)' name: contains [POINT: tag pattern, which is not allowed"
                )
            }
```

with:

```swift
            // MARK: - Plato — also ban the highlight directive tags
            let bannedDirectiveTags = ["[point:", "[highlight:", "[ripple:", "[scroll:", "[spotlight:"]
            for bannedTag in bannedDirectiveTags where lowercasedVocabularyName.contains(bannedTag) {
                violations.append(
                    "Vocabulary entry '\(escapedVocabularyName)' name: contains \(bannedTag.uppercased()) tag pattern, which is not allowed"
                )
            }
```

- [ ] **Step 4: Run tests + verify**

Developer action: ⌘U (prompt + validation tests), then ⌘R and confirm a skill is active and asking to highlight still works.
Expected: PASS on the test target; live behavior unchanged from Task 5 plus the model now proactively highlights when a skill with `pointing_mode: always` is active.

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/SkillPromptComposer.swift leanring-buddy/SkillValidation.swift leanring-buddyTests/SkillPromptComposerTests.swift
git commit -m "feat: teach highlight tools in the prompt and ban their inline tags in skills"
```

**Phase 1 complete:** model-driven shaded/outlined regions + click-here ripple, end-to-end, zero new permissions.

---

## PHASE 2 — OCR text highlighting (the paper feature)

Delivers: the model names the *text* to highlight ("the Methods section", a sentence); the app OCRs the screenshot, finds the text, and shades its exact rectangle. This removes the model's unreliable pixel-guessing for documents.

---

### Task 7: Vision OCR recognizer + pure text matcher

**Files:**
- Create: `leanring-buddy/ScreenshotTextRecognizer.swift`
- Test: `leanring-buddyTests/ScreenshotTextMatcherTests.swift`

**Interfaces:**
- Produces:
  - `struct OCRLine { let text: String; let boundingBox: CGRect }` (boundingBox = Vision-normalized, bottom-left).
  - `enum ScreenshotTextRecognizer { static func recognizeText(in cgImage: CGImage) throws -> [OCRLine] }`
  - `enum ScreenshotTextMatcher { static func normalize(_:) -> String; static func bestMatchBoundingBox(for query: String, in lines: [OCRLine]) -> CGRect? }`

- [ ] **Step 1: Write the failing matcher tests**

Create `leanring-buddyTests/ScreenshotTextMatcherTests.swift`:

```swift
// MARK: - Plato
import XCTest
@testable import leanring_buddy

final class ScreenshotTextMatcherTests: XCTestCase {

    private func line(_ text: String, _ box: CGRect) -> OCRLine { OCRLine(text: text, boundingBox: box) }

    func testNormalizeLowercasesAndCollapses() {
        XCTAssertEqual(ScreenshotTextMatcher.normalize("  Methods,  Section! "), "methods section")
    }

    func testSingleLineSubstringMatchReturnsItsBox() {
        let lines = [
            line("Introduction", CGRect(x: 0.1, y: 0.9, width: 0.3, height: 0.03)),
            line("3. Methods", CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.03)),
            line("Results", CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.03)),
        ]
        let box = ScreenshotTextMatcher.bestMatchBoundingBox(for: "Methods", in: lines)
        XCTAssertEqual(box, CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.03))
    }

    func testMultiLineSpanUnionsBoxes() {
        let lines = [
            line("We measured the dependent", CGRect(x: 0.1, y: 0.50, width: 0.4, height: 0.03)),
            line("variable across conditions.", CGRect(x: 0.1, y: 0.46, width: 0.4, height: 0.03)),
        ]
        let box = ScreenshotTextMatcher.bestMatchBoundingBox(
            for: "dependent variable across conditions", in: lines
        )
        // Union of the two stacked line boxes.
        XCTAssertEqual(box, CGRect(x: 0.1, y: 0.46, width: 0.4, height: 0.07))
    }

    func testNoMatchReturnsNil() {
        let lines = [line("Conclusion", CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03))]
        XCTAssertNil(ScreenshotTextMatcher.bestMatchBoundingBox(for: "appendix", in: lines))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Developer action: ⌘U.
Expected: FAIL — `OCRLine` / `ScreenshotTextMatcher` undefined.

- [ ] **Step 3: Implement the recognizer + matcher**

Create `leanring-buddy/ScreenshotTextRecognizer.swift`:

```swift
// MARK: - Plato
//
//  ScreenshotTextRecognizer.swift
//  leanring-buddy
//
//  OCRs a captured screenshot (Vision) and matches the model's named text to a
//  bounding box, so "highlight the Methods section" resolves to an exact rect
//  instead of the model guessing pixels. The matcher is pure (operates on
//  [OCRLine]) so it is unit-tested without Vision. Vision boundingBoxes are
//  normalized 0...1, BOTTOM-LEFT origin — the same handedness as displayFrame,
//  so no Y flip is needed downstream (see HighlightGeometry).
//

import Vision
import CoreGraphics

/// One recognized line of text with its Vision-normalized (bottom-left) box.
struct OCRLine {
    let text: String
    let boundingBox: CGRect
}

enum ScreenshotTextRecognizer {
    /// Synchronous and CPU-bound — call OFF the main actor (e.g. Task.detached).
    /// Deployment target macOS 14.2 → classic VNRecognizeTextRequest.
    static func recognizeText(in cgImage: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate          // dense paper text, not live camera
        request.usesLanguageCorrection = true         // cleaner strings → better matching
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let topCandidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: topCandidate.string, boundingBox: observation.boundingBox)
        }
    }
}

enum ScreenshotTextMatcher {
    /// Lowercase, strip punctuation, collapse runs of whitespace.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " { return Character(scalar) }
            return " "
        }
        let collapsed = String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    /// Returns the normalized (0...1, bottom-left) union box of the best match,
    /// or nil if the query isn't confidently found.
    /// Strategy: (1) a single line that contains the query; (2) the shortest
    /// contiguous run of lines whose concatenation contains the query.
    static func bestMatchBoundingBox(for query: String, in lines: [OCRLine]) -> CGRect? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        // (1) Single-line containment.
        if let singleLine = lines.first(where: { normalize($0.text).contains(normalizedQuery) }) {
            return singleLine.boundingBox
        }

        // (2) Multi-line contiguous span.
        for startIndex in lines.indices {
            var concatenated = normalize(lines[startIndex].text)
            var unionBox = lines[startIndex].boundingBox
            if concatenated.contains(normalizedQuery) { return unionBox }
            var endIndex = startIndex + 1
            while endIndex < lines.count {
                concatenated += " " + normalize(lines[endIndex].text)
                unionBox = unionBox.union(lines[endIndex].boundingBox)
                if concatenated.contains(normalizedQuery) { return unionBox }
                // Bound the window so we don't union half the page.
                if concatenated.count > normalizedQuery.count + 240 { break }
                endIndex += 1
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Developer action: ⌘U.
Expected: PASS — all four `ScreenshotTextMatcherTests` green.

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/ScreenshotTextRecognizer.swift leanring-buddyTests/ScreenshotTextMatcherTests.swift
git commit -m "feat: Vision OCR recognizer + pure screenshot text matcher"
```

---

### Task 8: `highlight_text` tool + async OCR handler

**Files:**
- Modify: `leanring-buddy/OpenAIRealtimeClient.swift` (tool def + tools array)
- Modify: `leanring-buddy/CompanionManager.swift` (handler near the others; dispatch case)

**Interfaces:**
- Consumes: `ScreenshotTextRecognizer`, `ScreenshotTextMatcher`, `OCRLine` (Task 7); `HighlightGeometry.globalRectFromNormalizedVisionBox`, `addHighlight`, `resolveTargetScreenCapture(for:)`, `decodeToolArguments`, `integerValue(from:)`.
- Produces: `highlight_text` tool; `applyHighlightTextDirective(argumentsJSON:)`.

- [ ] **Step 1: Define and register the `highlight_text` tool**

In `OpenAIRealtimeClient.swift`, after `rippleHereTool` (Task 4), add:

```swift
        // MARK: - Plato — highlight_text tool
        // The document enabler: the model names the visible TEXT to highlight and
        // the app OCRs the screenshot to resolve the exact rectangle. Use this
        // instead of guessing pixel coordinates for any text/paragraph/heading.
        let highlightTextTool: [String: Any] = [
            "type": "function",
            "name": "highlight_text",
            "description": "Highlight specific visible text on the user's screen — a heading, sentence, or paragraph in a paper or document. Give the exact words as they appear on screen; the app finds and shades them. Use this for any document text instead of highlight_region. ONLY an addition to your spoken response. If the text is not currently visible, do not call this — guide the user to scroll first. Do not say coordinates or this tool's name aloud.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The exact visible text to highlight, e.g. 'Methods' or the first words of the paragraph."],
                    "color": ["type": "string", "enum": ["red", "blue", "green", "yellow"], "description": "Highlight color. Defaults to yellow."],
                    "label": ["type": "string", "description": "Short name of what is being highlighted."],
                    "screen": ["type": "integer", "description": "1-based screen index; omit for the cursor's screen."]
                ],
                "required": ["text"]
            ]
        ]
```

Then append it to the `tools` array:

```swift
            "tools": [pointAtElementTool, searchScholarTool, controlPomodoroTool, highlightRegionTool, rippleHereTool, highlightTextTool],
```

- [ ] **Step 2: Add the async OCR handler**

In `CompanionManager.swift`, after `applyRippleDirective` (Task 5), add:

```swift
    // MARK: - Plato — highlight_text handler (async OCR)
    private func applyHighlightTextDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let searchText = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !searchText.isEmpty else {
            return
        }
        let colorName = (arguments["color"] as? String) ?? "yellow"
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])

        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: 0, screenshotYInPixels: 0,
            elementLabel: label ?? searchText, oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = resolveTargetScreenCapture(for: resolverDirective) else { return }

        // Snapshot the value-type bits we need off the main actor.
        let jpegData = targetScreenCapture.imageData
        let displayFrame = targetScreenCapture.displayFrame

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cgImage = NSBitmapImageRep(data: jpegData)?.cgImage else { return }
            let recognizedLines = (try? ScreenshotTextRecognizer.recognizeText(in: cgImage)) ?? []
            guard let normalizedBox = ScreenshotTextMatcher.bestMatchBoundingBox(for: searchText, in: recognizedLines) else {
                // No confident match — do nothing (the model already spoke; never
                // shade the wrong paragraph). A future enhancement can speak a fallback.
                return
            }
            let globalFrame = HighlightGeometry.globalRectFromNormalizedVisionBox(normalizedBox, displayFrame: displayFrame)
            await MainActor.run {
                self?.addHighlight(PlatoHighlight(
                    kind: .filledRegion(color: PlatoHighlight.color(forName: colorName)),
                    globalFrame: globalFrame, label: label,
                    createdAt: Date(), timeToLive: 5.0
                ))
            }
        }
    }
```

> `NSBitmapImageRep` requires AppKit — `CompanionManager.swift` already imports it. The capture stored a 1280px JPEG; OCR decodes that. The resolution tension (small paper fonts) is noted in Open Questions — a higher-res OCR-only capture is a later enhancement.

- [ ] **Step 3: Wire the dispatch case**

In the `.functionCallDone` `switch name` (`:2168`), add before `default:`:

```swift
            case "highlight_text":
                applyHighlightTextDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
```

- [ ] **Step 4: Build, run, and verify on a real paper**

Developer action: ⌘R. Open a PDF/paper (Preview or browser). Push-to-talk: *"Highlight the Methods section."* and *"Highlight the sentence about the dependent variable."*
Expected: A shaded rectangle lands on the named heading / sentence within ~0.5s of the model finishing. The model also speaks. If a phrase isn't on screen, nothing is highlighted (and the model should tell you to scroll).

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/OpenAIRealtimeClient.swift leanring-buddy/CompanionManager.swift
git commit -m "feat: highlight_text tool with async Vision OCR resolution"
```

**Phase 2 complete:** both headline use cases (paper-section highlight + rough region) ship with zero new permissions.

---

## PHASE 3 — Accessibility element highlighting (the "ring the right button" feature)

Delivers: pointing/ringing the RIGHT control by resolving it via the Accessibility API **by name** (not by the model's guessed pixels), with the model's coordinates as the fallback. This is the fix for "asked how to print, pointed to the wrong icon": the model already names the control (e.g. "Print"), so the app asks macOS for the real frame of the control *named* that and snaps there. Precise on native + Safari + woken-Electron apps; gracefully degrades (falls back to coordinates, or a verbal instruction) on canvas/GPU apps and menu-only actions.

> **Why label search, not coordinate hit-testing:** snapping to whatever element sits under the model's guessed point does NOT help when the guess already landed on the wrong icon. Only resolving the control by its NAME corrects a grossly-wrong guess. Label search is therefore the primary strategy here (promoted from the original plan's "deferred follow-up").

---

### Task 9: AX element resolver + pure flip test

**Files:**
- Create: `leanring-buddy/AXElementResolver.swift`
- Test: `leanring-buddyTests/AXElementResolverGeometryTests.swift`

**Interfaces:**
- Consumes: `HighlightGeometry.appKitRectFromAXFrame` (Task 1).
- Produces: `enum AXElementResolver` (`@MainActor`) with:
  - `static func primaryScreenHeight() -> CGFloat`
  - `static func controlFrame(matchingLabel label: String) -> CGRect?` — **primary**: searches the frontmost app's AX tree for a pointable control whose title/description/help contains `label`; returns its global AppKit frame or nil.
  - `static func elementFrameAtAppKitPoint(_ appKitPoint: CGPoint) -> CGRect?` — secondary hit-test.

- [ ] **Step 1: Write the failing flip test**

Create `leanring-buddyTests/AXElementResolverGeometryTests.swift`:

```swift
// MARK: - Plato
import Testing
import CoreGraphics
@testable import leanring_buddy

struct AXElementResolverGeometryTests {
    // The AX→AppKit flip is the unit-testable core of the resolver.
    @Test func axTopLeftFrameFlipsToAppKitBottomLeft() {
        let rect = HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: CGPoint(x: 200, y: 100), axSize: CGSize(width: 80, height: 24),
            primaryScreenHeight: 1080
        )
        #expect(rect == CGRect(x: 200, y: 1080 - 100 - 24, width: 80, height: 24))
    }
}
```

- [ ] **Step 2: Run to verify it passes**

Developer action: ⌘U.
Expected: PASS — `appKitRectFromAXFrame` already exists from Task 1 (this test pins the behavior the resolver depends on).

- [ ] **Step 3: Implement the resolver**

Create `leanring-buddy/AXElementResolver.swift`:

```swift
// MARK: - Plato
//
//  AXElementResolver.swift
//  leanring-buddy
//
//  Resolves the on-screen FRAME of a UI control via the Accessibility API so the
//  overlay can point at / ring the REAL control instead of trusting the model's
//  guessed pixel coordinates. Reads only — no clicking, no actuation (that's
//  real-cursor-control.md, out of scope). Runs under the Accessibility grant
//  Plato already holds (no new TCC prompt).
//
//  Two strategies:
//   - controlFrame(matchingLabel:) — PRIMARY. Search the FRONTMOST app's AX tree
//     for a control whose title/description matches the model's label ("Print").
//     Robust to a grossly-wrong coordinate guess: finds the control by NAME.
//   - elementFrameAtAppKitPoint(_:) — secondary hit-test under a point.
//
//  COORDINATE FACTS (verified): AX geometry is global TOP-LEFT-origin POINTS
//  anchored to the PRIMARY screen — no backingScaleFactor. AXUIElementCopy-
//  ElementAtPosition takes C Float (must cast). The AX API is NOT thread-safe:
//  every call runs on the main thread (this enum is @MainActor).
//

import AppKit
import ApplicationServices

@MainActor
enum AXElementResolver {

    /// Height of the primary (menu-bar, origin == .zero) screen — the AX flip reference.
    static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// PRIMARY: searches the frontmost app's AX tree for a pointable control whose
    /// title/description/help contains `label` (case-insensitive), returning its
    /// global AppKit frame. nil if not found or the app is AX-blind. Bounded by a
    /// node budget + max depth; a short messaging timeout keeps a slow app from
    /// stalling the main thread.
    static func controlFrame(matchingLabel label: String) -> CGRect? {
        let primaryHeight = primaryScreenHeight()
        guard primaryHeight > 0 else { return nil }
        let normalizedQuery = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else { return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        let pointableRoles: Set<String> = [
            kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXMenuItemRole,
            kAXMenuBarItemRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXImageRole
        ]
        let titleAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
        var remainingNodeBudget = 2000

        func search(_ element: AXUIElement, depth: Int) -> CGRect? {
            if remainingNodeBudget <= 0 || depth > 60 { return nil }
            remainingNodeBudget -= 1

            if let role = stringAttribute(element, kAXRoleAttribute), pointableRoles.contains(role) {
                for attribute in titleAttributes {
                    if let text = stringAttribute(element, attribute),
                       text.lowercased().contains(normalizedQuery),
                       let frame = frameOfElement(element, primaryHeight: primaryHeight) {
                        return frame
                    }
                }
            }
            guard let children = childElements(element) else { return nil }
            for child in children {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(appElement, depth: 0)
    }

    /// SECONDARY: hit-tests the element under a GLOBAL AppKit point and returns its
    /// frame in global AppKit coordinates, or nil if AX exposes nothing there.
    static func elementFrameAtAppKitPoint(_ appKitPoint: CGPoint) -> CGRect? {
        let primaryHeight = primaryScreenHeight()
        guard primaryHeight > 0 else { return nil }

        // AppKit (bottom-left) -> AX/CG (top-left): X identical, flip Y.
        let topLeftX = Float(appKitPoint.x)
        let topLeftY = Float(primaryHeight - appKitPoint.y)

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(systemWide, topLeftX, topLeftY, &hitElement)
        guard hitStatus == .success, let element = hitElement else { return nil }
        return frameOfElement(element, primaryHeight: primaryHeight)
    }

    // MARK: - AX reading helpers

    /// Reads kAXPosition + kAXSize and converts to a global AppKit rect, or nil.
    private static func frameOfElement(_ element: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAXValue = positionValue, CFGetTypeID(positionAXValue) == AXValueGetTypeID(),
              let sizeAXValue = sizeValue, CFGetTypeID(sizeAXValue) == AXValueGetTypeID() else {
            return nil
        }
        var axOrigin = CGPoint.zero
        var axSize = CGSize.zero
        guard AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &axOrigin),
              AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &axSize),
              axSize.width > 0, axSize.height > 0 else {
            return nil
        }
        return HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: axOrigin, axSize: axSize, primaryScreenHeight: primaryHeight
        )
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func childElements(_ element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
```

- [ ] **Step 4: Build**

Developer action: ⌘B.
Expected: Build succeeds (`ApplicationServices` provides the AX symbols).

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/AXElementResolver.swift leanring-buddyTests/AXElementResolverGeometryTests.swift
git commit -m "feat: AXElementResolver — resolve controls by name (label search) + hit-test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Resolve pointed-at controls by name via AX (fix "pointed to the wrong icon")

When the model points at an app control, prefer the REAL control frame (resolved by name via AX) over the model's guessed pixels — and ring it. This is the fix for the observed "asked how to print → pointed to the wrong icon": the cursor + ring snap to the actual named control, or fall back to the model's coordinates when AX can't resolve it.

**Files:**
- Modify: `leanring-buddy/CompanionManager.swift` (the pointing path + `applyHighlightRegionDirective`)
- Modify: `leanring-buddy/OpenAIRealtimeClient.swift` (`highlight_region` `snap_to_control` param)
- Modify: `leanring-buddy/SkillPromptComposer.swift` (control-label guidance)

**Interfaces:**
- Consumes: `AXElementResolver.controlFrame(matchingLabel:)` + `elementFrameAtAppKitPoint` (Task 9), `addHighlight`, `PlatoHighlight`, the existing pointing fields + `mapScreenshotPixelCoordinateToGlobalScreenPoint`.
- Produces: `resolveControlGlobalFrame(label:approximatePoint:) -> CGRect?`.

- [ ] **Step 1: Add the shared resolver helper**

In `CompanionManager.swift`, next to the pointing handlers (after `applyPointDirectiveFromToolCall`), add:

```swift
    // MARK: - Plato — resolve the REAL control frame, preferring an AX label match
    // over the model's guessed pixels. nil → caller falls back to model coordinates.
    private func resolveControlGlobalFrame(label: String, approximatePoint: CGPoint) -> CGRect? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty, let frameByName = AXElementResolver.controlFrame(matchingLabel: trimmedLabel) {
            return frameByName
        }
        // Secondary: the element directly under the model's guessed point (only
        // helps when the guess already landed on the right control).
        return AXElementResolver.elementFrameAtAppKitPoint(approximatePoint)
    }
```

- [ ] **Step 2: Use it in the tool-call pointing path**

In `applyPointDirectiveFromToolCall`, the tail currently maps the model's pixels to `screenLocation` and assigns the detected-element fields. Replace that tail (the `let screenLocation = mapScreenshotPixelCoordinateToGlobalScreenPoint(...)` block through the `SkillyAnalytics.trackElementPointed(...)` line) with:

```swift
        let modelPoint = mapScreenshotPixelCoordinateToGlobalScreenPoint(
            screenshotXInPixels: parsedPointDirective.screenshotXInPixels,
            screenshotYInPixels: parsedPointDirective.screenshotYInPixels,
            screenCapture: targetScreenCapture
        )

        // MARK: - Plato — prefer the real control frame (by name) over guessed pixels
        if let controlFrame = resolveControlGlobalFrame(
            label: parsedPointDirective.elementLabel, approximatePoint: modelPoint
        ) {
            detectedElementScreenLocation = CGPoint(x: controlFrame.midX, y: controlFrame.midY)
            detectedElementDisplayFrame = targetScreenCapture.displayFrame
            detectedElementBubbleText = parsedPointDirective.elementLabel
            addHighlight(PlatoHighlight(
                kind: .strokedRegion(color: PlatoHighlight.color(forName: "blue"), lineWidth: 2.5),
                globalFrame: controlFrame, label: parsedPointDirective.elementLabel,
                createdAt: Date(), timeToLive: 4.0))
            SkillyAnalytics.trackElementPointed(elementLabel: parsedPointDirective.elementLabel)
            return
        }

        // Fallback: the model's guessed coordinates (previous behavior).
        detectedElementScreenLocation = modelPoint
        detectedElementDisplayFrame = targetScreenCapture.displayFrame
        detectedElementBubbleText = parsedPointDirective.elementLabel
        SkillyAnalytics.trackElementPointed(elementLabel: parsedPointDirective.elementLabel)
```

> The legacy inline-tag path (`applyPointDirectiveIfPresent`) keeps its existing coordinate behavior — the tool path is what gpt-realtime uses. (Optionally apply the same AX preference there later.)

- [ ] **Step 3: Add `snap_to_control` to `highlight_region` and use AX**

In `OpenAIRealtimeClient.swift`, add to the `highlightRegionTool` parameters:

```swift
                    "snap_to_control": ["type": "boolean", "description": "Set true when highlighting a single UI control (button, menu, icon) so the ring snaps to the real control via Accessibility. Omit/false for a free area like a paper region."],
```

In `applyHighlightRegionDirective`, after computing `globalFrame` and before building `kind`, insert:

```swift
        // MARK: - Plato — snap a single control to its real AX frame (by name, then point)
        if (arguments["snap_to_control"] as? Bool) ?? false {
            let centerPoint = mapScreenshotPixelCoordinateToGlobalScreenPoint(
                screenshotXInPixels: x + (width / 2),
                screenshotYInPixels: y + (height / 2),
                screenCapture: targetScreenCapture
            )
            if let axFrame = resolveControlGlobalFrame(label: label ?? "", approximatePoint: centerPoint) {
                addHighlight(PlatoHighlight(
                    kind: .strokedRegion(color: PlatoHighlight.color(forName: colorName), lineWidth: 2.5),
                    globalFrame: axFrame, label: label, createdAt: Date(), timeToLive: 4.0))
                return
            }
            // AX couldn't resolve (canvas/GPU app, no element) — fall through to the model bbox.
        }
```

(The existing `kind`/`addHighlight` lines remain as the model-bbox fallback.)

- [ ] **Step 4: Steer the prompt — accurate label, verbal fallback for menus**

In `SkillPromptComposer.pointingModeInstruction`, extend `highlightGuidance` (append one sentence):

```
" When you point at an app control (a button, menu, or icon), give its exact on-screen NAME as the label — Plato uses that name to find and ring the real control precisely. If the action lives only in a menu (e.g. File ▸ Print) with no on-screen button, do NOT point at a guess — say the menu path out loud instead."
```

- [ ] **Step 5: Build, run, verify (the regression that motivated this)**

Developer action: ⌘R. In the app where "how to print" previously mispointed, ask *"how do I print this?"* and *"where's the share button?"*.
Expected: the cursor + a tight ring land on the REAL control (resolved by name), not a guessed icon. If the action is menu-only, the companion describes the menu path instead of pointing at the wrong place. In an AX-blind app (canvas/GPU) it falls back to the model's approximate point without error.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/CompanionManager.swift leanring-buddy/OpenAIRealtimeClient.swift leanring-buddy/SkillPromptComposer.swift
git commit -m "feat: resolve pointed-at controls by name via AX (fix wrong-icon pointing)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> **Deferred (optional follow-ups):** Electron wake (`AXManualAccessibility`) for VS Code/Slack chrome, and ranking multiple label matches by proximity to the model's point (v1 returns the first role+name match). The spec (§3b-ii) has the wake caveats.

---

## PHASE 4 — Scroll affordance, spotlight, and lifecycle polish

Delivers: the "scroll to a section" guidance loop, the spotlight/dim mask, and auto-dismiss on user interaction.

---

### Task 11: `show_scroll_affordance` tool + arrow

**Files:**
- Modify: `leanring-buddy/OpenAIRealtimeClient.swift` (tool def + array)
- Modify: `leanring-buddy/CompanionManager.swift` (handler + dispatch)

- [ ] **Step 1: Define + register the tool**

After `highlightTextTool` (Task 8), add and append to the tools array:

```swift
        // MARK: - Plato — show_scroll_affordance tool
        let showScrollAffordanceTool: [String: Any] = [
            "type": "function",
            "name": "show_scroll_affordance",
            "description": "Show a directional arrow telling the user to scroll, when the thing they need is not currently visible on screen. Always also say aloud which way to scroll and what to look for. Once they scroll and the target is visible, highlight it. Do not say this tool's name aloud.",
            "parameters": [
                "type": "object",
                "properties": [
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "Which way the user should scroll."],
                    "label": ["type": "string", "description": "Short name of what they're scrolling to."],
                    "screen": ["type": "integer", "description": "1-based screen index; omit for the cursor's screen."]
                ],
                "required": ["direction"]
            ]
        ]
```

```swift
            "tools": [pointAtElementTool, searchScholarTool, controlPomodoroTool, highlightRegionTool, rippleHereTool, highlightTextTool, showScrollAffordanceTool],
```

- [ ] **Step 2: Add the handler**

After `applyHighlightTextDirective`, add:

```swift
    // MARK: - Plato — show_scroll_affordance handler
    private func applyScrollAffordanceDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let directionName = (arguments["direction"] as? String)?.lowercased() else {
            return
        }
        let direction: PlatoHighlight.ArrowDirection
        switch directionName {
        case "up": direction = .up
        case "left": direction = .left
        case "right": direction = .right
        default: direction = .down
        }
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])
        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: 0, screenshotYInPixels: 0,
            elementLabel: label ?? "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = resolveTargetScreenCapture(for: resolverDirective) else { return }

        // Place the arrow near the relevant edge of the target display.
        let frame = targetScreenCapture.displayFrame
        let arrowCenter: CGPoint
        switch direction {
        case .down:  arrowCenter = CGPoint(x: frame.midX, y: frame.minY + 80)
        case .up:    arrowCenter = CGPoint(x: frame.midX, y: frame.maxY - 80)
        case .left:  arrowCenter = CGPoint(x: frame.minX + 80, y: frame.midY)
        case .right: arrowCenter = CGPoint(x: frame.maxX - 80, y: frame.midY)
        }
        let globalFrame = CGRect(x: arrowCenter.x, y: arrowCenter.y, width: 0, height: 0)
        addHighlight(PlatoHighlight(
            kind: .directionalArrow(direction: direction, color: PlatoHighlight.color(forName: "blue")),
            globalFrame: globalFrame, label: label, createdAt: Date(), timeToLive: 4.0
        ))
    }
```

- [ ] **Step 3: Dispatch case**

In the `switch name` (`:2168`), before `default:`:

```swift
            case "show_scroll_affordance":
                applyScrollAffordanceDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
```

- [ ] **Step 4: Build, run, verify**

Developer action: ⌘R. Open a long document scrolled to the top. Push-to-talk: *"Take me to the references."*
Expected: A downward arrow appears near the bottom edge and the model says to scroll down. (Re-highlighting once scrolled is turn-driven: ask again after scrolling and `highlight_text` lands on it.)

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/OpenAIRealtimeClient.swift leanring-buddy/CompanionManager.swift
git commit -m "feat: show_scroll_affordance directional arrow tool"
```

---

### Task 12: `spotlight_region` tool

**Files:**
- Modify: `leanring-buddy/OpenAIRealtimeClient.swift`, `leanring-buddy/CompanionManager.swift`

- [ ] **Step 1: Define + register the tool**

```swift
        // MARK: - Plato — spotlight_region tool
        let spotlightRegionTool: [String: Any] = [
            "type": "function",
            "name": "spotlight_region",
            "description": "Dim the whole screen except one rectangular region, to focus the user's attention on it. Use sparingly, for a single important area. Same coordinates as highlight_region. ONLY an addition to speech.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "integer", "description": "Left edge X in screenshot pixels (top-left origin)."],
                    "y": ["type": "integer", "description": "Top edge Y in screenshot pixels (top-left origin)."],
                    "width": ["type": "integer", "description": "Region width in screenshot pixels."],
                    "height": ["type": "integer", "description": "Region height in screenshot pixels."],
                    "screen": ["type": "integer", "description": "1-based screen index; omit for the cursor's screen."]
                ],
                "required": ["x", "y", "width", "height"]
            ]
        ]
```

```swift
            "tools": [pointAtElementTool, searchScholarTool, controlPomodoroTool, highlightRegionTool, rippleHereTool, highlightTextTool, showScrollAffordanceTool, spotlightRegionTool],
```

- [ ] **Step 2: Add the handler**

```swift
    // MARK: - Plato — spotlight_region handler
    private func applySpotlightDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let x = integerValue(from: arguments["x"]),
              let y = integerValue(from: arguments["y"]),
              let width = integerValue(from: arguments["width"]),
              let height = integerValue(from: arguments["height"]) else {
            return
        }
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])
        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: x, screenshotYInPixels: y,
            elementLabel: "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = resolveTargetScreenCapture(for: resolverDirective) else { return }
        let globalFrame = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: x, y: y, width: width, height: height,
            screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
            displayFrame: targetScreenCapture.displayFrame
        )
        // Only one spotlight at a time — clear others first so dim layers don't stack.
        clearAllHighlights()
        addHighlight(PlatoHighlight(kind: .spotlight(dimOpacity: 0.45), globalFrame: globalFrame,
                                    label: nil, createdAt: Date(), timeToLive: 4.0))
    }
```

- [ ] **Step 3: Dispatch case**

```swift
            case "spotlight_region":
                applySpotlightDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
```

- [ ] **Step 4: Build, run, verify (watch for stutter)**

Developer action: ⌘R. Push-to-talk: *"Spotlight the abstract."*
Expected: The screen dims except a rounded rect over the abstract; it fades out after ~4s. Confirm the dim layer doesn't cause visible stutter on your setup (multi-monitor Retina is the worst case — note in Open Questions if it does).

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/OpenAIRealtimeClient.swift leanring-buddy/CompanionManager.swift
git commit -m "feat: spotlight_region dim-the-rest tool"
```

---

### Task 13: Auto-dismiss highlights on scroll / mouse-down

**Files:**
- Modify: `leanring-buddy/CompanionManager.swift` (a global monitor started where the overlay is set up)

**Interfaces:**
- Consumes: `clearAllHighlights()` (Task 2).
- Produces: `installHighlightDismissalMonitorIfNeeded()`.

- [ ] **Step 1: Add a passive global monitor**

In `CompanionManager.swift`, near the highlight state (Task 2), add:

```swift
    // MARK: - Plato — Auto-dismiss highlights on first user interaction
    private var highlightDismissalMonitor: Any?

    private func installHighlightDismissalMonitorIfNeeded() {
        guard highlightDismissalMonitor == nil else { return }
        // Absolute-coordinate highlights go stale the instant content moves; a
        // scroll/click/drag is the signal to clear them. Global monitors are
        // read-only (cannot consume), which is exactly what we want.
        highlightDismissalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in self?.clearAllHighlights() }
        }
    }
```

- [ ] **Step 2: Start the monitor when highlights can appear**

In `addHighlight(_:)` (Task 2), add `installHighlightDismissalMonitorIfNeeded()` as the first line so the monitor exists whenever a highlight is on screen:

```swift
    func addHighlight(_ highlight: PlatoHighlight) {
        installHighlightDismissalMonitorIfNeeded()
        activeHighlights.append(highlight)
        startHighlightExpirationTimerIfNeeded()
    }
```

- [ ] **Step 3: Build, run, verify**

Developer action: ⌘R. Trigger any highlight, then scroll or click.
Expected: The highlight vanishes immediately on the first scroll/click (rather than lingering at a now-wrong position), and reappears correctly on the next request.

- [ ] **Step 4: Commit**

```bash
git add leanring-buddy/CompanionManager.swift
git commit -m "feat: auto-dismiss highlights on first scroll/mouse-down"
```

**Phase 4 complete.**

---

## Out of scope / deliberate non-goals

- **Clicking, cursor warping, AX press, scrolling for the user** — actuation lives in `docs/research/real-cursor-control.md`. This feature only points and highlights.
- **Reading another app's document model** (PDFKit is in-process only). Document awareness comes from the screenshot + OCR.
- **Label-based AX tree search and Electron wake** — deferred follow-ups within Phase 3 (spec §3b-ii).
- **Higher-resolution OCR-only capture** — the MVP OCRs the existing 1280px JPEG (Open Question #1).
- **Analytics** — if desired later, mirror the existing `SkillyAnalytics.trackElementPointed(elementLabel:)` signature with `trackRegionHighlighted` / `trackTextHighlighted`; intentionally omitted here to avoid referencing un-audited symbols.

## Open questions / risks (carried from the research doc)

1. **OCR latency on a real 1280px screenshot is unmeasured** (estimates 100ms–3s). Measure with `CACurrentMediaTime()` off-main, discard the warm-up run. Decides whether OCR can ever support a bounded scroll-poll loop or stays per-turn only.
2. **OCR resolution tension:** 1280px hurts small dense paper fonts. If Phase 2 accuracy is poor, add a higher-res cursor-screen capture used only for OCR.
3. **`highlight_text` mis-match risk:** repeated phrases, equations/figures, hyphenation. Consider a confidence floor below which the model says "I can't pinpoint that."
4. **Spotlight compositing cost** on multi-monitor Retina (Task 12 Step 4).
5. **Shared `AXElementResolver` ownership** if `real-cursor-control.md` also ships — keep one copy (this plan reads frames; that one also acts).
6. **Color accessibility** — every highlight already pairs hue with an outline + label; keep that invariant.

## Self-review notes

- **Spec coverage:** rendering primitives (Tasks 1,3), model-bbox (Task 5), OCR text (Tasks 7–8), AX (Tasks 9–10), scroll loop (Task 11), spotlight (Task 12), lifecycle/staleness (Tasks 2,13), protocol+prompt (Tasks 4,6,8,11,12) — all spec sections map to a task.
- **Type consistency:** `addHighlight`/`clearAllHighlights`, `globalFrame`, `decodeToolArguments`/`integerValue(from:)`, `HighlightGeometry.*`, `OCRLine`/`ScreenshotTextMatcher.bestMatchBoundingBox(for:in:)`, `AXElementResolver.elementFrameAtAppKitPoint` are used identically everywhere they appear.
- **No placeholders:** every code step shows complete code; verification steps name the exact Xcode action and expected observation.
