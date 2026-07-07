# Plato Pointing — Definitive Root-Cause Report (Round 4 Synthesis)

> Produced 2026-07-07 by a 15-agent Opus-xhigh investigation (5 dimension investigators → triage → adversarial verification per candidate → synthesis). 34 raw findings → 8 candidates → 7 survived (5 CONFIRMED, 2 PLAUSIBLE), 1 refuted. All cited lines verified against HEAD (97d91d7).

## Executive summary — the two symptoms are the two ends of ONE dial

The whole pointing system has only two terminal states for any turn: **commit a visual anchored on an imprecise source**, or **commit nothing**. It has no "commit *precise*" state for the surfaces where pointing matters most. Therefore:

- **SYMPTOM 1 (near-but-not-on)** = the app committed a visual, but the anchor under it was imprecise (raw model pixel on a downscaled JPEG, a wrong AX sibling, or a whole OCR text line).
- **SYMPTOM 2 (only talks)** = the app refused to commit a visual (the model never called the tool, *or* a resolution gate declined and a decline emits nothing).

Because there is no third state, the two symptoms share **one knob** (`AXCandidateScoring`/`HighlightGeometry` decline thresholds + prompt pressure). Every prior round turned that one knob and traded one symptom for the other — which is exactly the "improved but never eliminated" shape. And every round turned it **blind**, because declines are uninstrumented and the least-accurate outcome logs identically to the most-accurate one.

```
      commit imprecise  ◄─────────── ONE KNOB ───────────►  commit nothing
        = SYMPTOM 1          (608e6fe/97d91d7 push right)       = SYMPTOM 2
                             (83580b5 pushes left, harder)
        ▲ there is no third position: "commit PRECISE on canvas/web/PDF/icons" ▲
```

The smallest set of causes that fully explains both symptoms and the trade pattern is **five**: two primary drivers (one per symptom), two cross-cutting causes that create the trade and the blindness, and precision-layer defects that set the accuracy ceiling.

---

## SYMPTOM 1 — Inaccurate pointing

### P1 (PRIMARY, CONFIRMED) — Only two code paths produce a *precise* anchor; both are structurally absent on Plato's real target surfaces, so the fallback anchor is the model's raw pixel guess on a ≤1280 px JPEG — an irreducible error floor. (C1)

**Causal chain.** A precise ring/cursor is produced by exactly two "snap to a real frame" sources:
- AX name-resolution → `addHighlight(controlFrame)` — `CompanionManager.swift:1822-1841`
- OCR text-match → `addHighlight(globalFrame)` — `CompanionManager.swift:1904-1921`

Every other sink anchors on the model's guessed pixel: inline `[POINT]` maps the raw pixel with **no AX, no ring** (`CompanionManager.swift:1698-1715`); the OCR-miss hedge sets `detectedElementScreenLocation = modelPoint` ("around here", **no ring**, `:1926-1931`); `highlight_region` with snap omitted draws a **ring** at the raw model bbox. That guess originates on a capture downscaled to `maxDimension = 1280` (`CompanionScreenCaptureUtility.swift:84`), and `HighlightGeometry.globalPointFromScreenshotPixel` (`:31-57`) linearly scales screenshot-px → display-pt by `displayFrame.width / 1280` (~1.2 pt/px on a laptop, ~2.0 on a 2560-pt display), so a routine few-pixel vision-localization error amplifies to tens of points on screen. Crucially, the map divides by the *same* per-image pixel dimensions the model was told to answer in (`CompanionManager.swift:2350-2351`, `:2225-2237`), so this is **not** a systematic scaling bug — it is genuine, uncorrectable model localization error. AX/OCR cannot rescue it on the surfaces that need it: `AXElementResolver.pointableRoles` walks the frontmost app's AX tree for button/menu/image leaves (`AXElementResolver.swift:101-104`), and Blender/AE/Premiere/DaVinci/Figma canvases plus web/PDF graphical controls expose no matching leaf; OCR matches text only. Both fall through to the raw point.

**Verdict: CONFIRMED (primary).** The only unverifiable link is the *magnitude* of the model's localization error on a 1280px image; its existence and its concentration on non-AX/OCR surfaces are certain from the code. This is precisely why AX-adding rounds improved (more native controls snap exactly) but never eliminated (the un-snappable raw-coord floor was never touched).

**Fix direction (architecture).** Stop treating the model's pixel as the anchor of last resort. Either (a) invert the addressing model so precision is the *default*, not a rescue: send the model an enumerated list of addressable elements (AX tree + a DOM/PDF/accessibility digest of the frontmost surface) and have it return an **element id**, mapping the pixel guess only to disambiguate; or (b) when no id-based anchor exists, do a **second high-resolution round-trip** — crop a native-res tile around the guess and ask the model to re-localize within the tile — converting one coarse global guess into a fine local one. Both replace "trust the downscaled guess" with "resolve against ground truth."

### P1-b (PRIMARY for the residual, PLAUSIBLE) — Even when the AX layer *does* fire, it can select a nearby wrong frame or an oversized frame, because the name-walk applies neither a size gate nor (for a lone match) a proximity gate. (C4)

**Causal chain.** `matchQuality` requires `normalizedText.contains(query)` (`AXCandidateScoring.swift:71`) and normalization strips only trailing role words (`:88-106`), yet the tool's own examples steer the model to descriptive labels — `label="color inspector"`, `label="source control"` (`CompanionManager.swift:1176-1178`) — that a shorter accessible name ("Color") cannot contain, so the walk returns nil and degrades to the guess. When it *does* match: `controlFrame` (`AXElementResolver.swift:129-185`) never calls `isPlausibleControlFrame` (that gate runs only on the hit-test path, `:217/:232`), and `pointableRoles` includes `kAXImageRole` (`:103`), so a name match on an oversized image/container frame is ringed and the cursor flies to its far center; and a lone `.exact` match returns at the `count == 1` early-out (`AXCandidateScoring.swift:188`) bypassing the spatial gate, so a same-named control far from intent gets ringed.

**Verdict: PLAUSIBLE (primary contributor to the Symptom-1 residual).** The verifier downgraded the frontmost-only-scope and exact-when-no-hint sub-claims as overstated/inert — drop those. The size-gate omission, the descriptive-vs-accessible-name mismatch, and the lone-exact proximity bypass are confirmed code facts and are the real residual drivers.

**Fix direction.** Make the name-walk apply the same `isPlausibleControlFrame` size/aspect gate the hit-test path already uses, add parent/child dedup with role priority (button over nested image), and require a proximity check even for a single exact match. Separately, align the tool's example labels and the matcher: either instruct the model to emit the *exact* accessible name, or make matching token-overlap/fuzzy rather than substring-containment so a descriptive spoken label resolves.

### P1-c (SECONDARY, CONFIRMED) — For text targets, OCR rings the whole recognized line / multi-line union, not the glyph — an offset, oversized ring. (C7)

**Causal chain.** `ScreenshotTextMatcher.matchResult` returns Vision's bounding box for an entire recognized **line** (`ScreenshotTextRecognizer.swift:74-77`), the largest-area box among duplicates (`:78-89`), or a multi-line **union** (`:93-106`); `HighlightGeometry.globalRectFromNormalizedVisionBox` maps it verbatim with no shrink (`:99-106`) and `PlatoHighlightView` centers the ring on the box midpoint. So "Export" inside a "File Export Share" row yields a fat ring centered on the row; a single-word duplicate returns `.ambiguous` → no ring (a Symptom-2 leak). A secondary edge: the native-res OCR recapture selects its display by exact `CGRect` equality (`CompanionScreenCaptureUtility.swift:149-151`) and silently falls back to the stale ≤1280 px turn JPEG on mismatch (`CompanionManager.swift:1888`) — but `NSScreen.frame` doesn't float-drift, so this bites only on a genuine mid-turn display-arrangement change.

**Verdict: CONFIRMED (secondary; dominant only for OCR-resolved PDF/web/canvas text).** No prior round touched the OCR box-anchoring math, so this residual survives all of them.

**Fix direction.** Resolve OCR matches to the **word/token sub-box** (Vision exposes per-observation character-range geometry via `boundingBox(for:)`) rather than the line, and shrink the union path to the query's actual span; decline-to-ambiguous should still move the cursor with a hedge rather than emit nothing.

---

## SYMPTOM 2 — Pointing doesn't happen when it should

### P2 (PRIMARY, CONFIRMED) — Pointing is advisory, never enforced: a probabilistic model decision under `tool_choice:auto`, guarded by a one-sided recovery net, with a structurally-dead inline fallback and a self-contradictory when-relevant prompt on 5 of 6 academic skills. (C3)

**Causal chain.** The session registers 8 tools with `output_modalities:["audio"]` and `tool_choice:"auto"` (`OpenAIRealtimeClient.swift:586,591-592`) and **no temperature pin** (`:583-593`) — so whether any visual fires is a sampling outcome with run-to-run variance. The only runtime safety net is one-sided: `shouldForceSpokenFollowUp` fires solely for *tool-without-speech* (`CompanionManager.swift:2590-2592`); there is **no mirror** for *spoke-without-pointing on a where-is question*, and no where-is intent classifier anywhere (the only classifier is `classifyFocus` for off-task vision). The legacy inline `[POINT]` fallback is dead: `realtimeResponseText` is fed only by `.audioTranscriptDelta` (`:2562-2564`) — the spoken transcript — and the model is told never to voice coordinates/brackets, so `applyPointDirectiveIfPresent` (`:2639`) parses text that can never contain `[POINT:...]`. There is thus **no redundancy** behind the single probabilistic tool call. Finally, the pointing instruction is Layer 5, appended last / highest-recency (`SkillPromptComposer.swift:116-120`), and for `.whenRelevant` skills it opens "point... when it would genuinely help... **Don't point at things that are obvious**" (`:213`) directly concatenated with "**Default to showing**" (`:207`) — a self-contradiction in one string — and all five academic app skills (`latex`, `word`, `obsidian`, `rstudio`, `zotero`) are `pointing_mode: when-relevant`; 83580b5 flipped only `plato-academic-tutor` to `.always`.

**Verdict: CONFIRMED (primary).** Nothing in the code makes pointing deterministic, so prompt/tool-description rounds (83580b5, tool rewrites) can only raise the probability — the exact "improved but not eliminated" shape. Co-mechanism: some Symptom-2 turns are the model *calling* the tool but the resolver *declining* it (see C2), which yields the identical talk-only experience and also has zero deterministic recovery.

**Fix direction.** Add a lightweight **where-is intent gate** (classify the user turn: is it asking to locate an on-screen thing?). On a positive classification, make pointing enforced, not requested: either issue a per-turn `tool_choice:{type:"function",name:"point_at_element"}`, or add the **mirror recovery net** (spoke-without-pointing on a where-is turn → force a `point_at_element` follow-up) symmetric to the existing tool-without-speech net. Pin `temperature`. Collapse the 6 overlapping visual tools toward one `show(target)` verb, and resolve the when-relevant contradiction (the base "default to showing" should not be immediately negated by a recency-weighted "don't point at obvious things").

### P2-b (SECONDARY, PLAUSIBLE) — Every decline feeds `{ok:false, "describe it in words instead"}` into the persistent session, plausibly training the model to stop pointing as the turn count grows. (C5)

**Causal chain.** `sendFunctionCallOutput` emits `function_call_output` with no delete/truncate (`OpenAIRealtimeClient.swift:725-743`) on a connection reused across turns, and `honestLocateFailureReason` is literally "...describe where it is in words instead" (`CompanionManager.swift:1736-1738`). The OCR-miss hedge is self-contradictory reinforcement: it moves the cursor yet returns `ok:false` telling the model it failed (`:1926-1935`).

**Verdict: PLAUSIBLE (secondary aggravator).** The decisive link — the model generalizing accumulated `ok:false` into ceasing tool calls — is unobservable statically, and a fresh session with zero declines still exhibits Symptom 2, so this cannot be primary. The candidate's "static prompt gets buried" sub-argument is **wrong** (the show-first block is re-sent as `session.instructions` every turn via `updateSessionConfiguration`) — drop it. Not every decline carries the "describe in words" text (malformed-arg declines say "could not read the pointing request", `:1764-1809`).

**Fix direction.** Don't teach the model that pointing fails. On a decline, return a neutral/actionable result ("target not directly resolvable — offer the menu path") rather than "describe it in words," and reconcile the hedge (if you moved the cursor, report a qualified success, not a failure). Consider truncating stale tool-failure items from the running context.

---

## CROSS-CUTTING — why 3 rounds improved but never eliminated

### X1 (CONFIRMED) — "Decline > mis-point" is a single dial with no third state; tightening Symptom 1 mechanically widens Symptom 2, and this is where Round 3 made the trade. (C2)

**Causal chain.** `globalPointFromScreenshotPixel` returns nil for coords >2% out of bounds (`HighlightGeometry.swift:24,41-46`); that nil flows to `modelPoint` and the directive `declinedSynchronously` — and on that branch **OCR is never attempted** (`CompanionManager.swift:1847-1850`), even though `resolvePointDirectiveByOCR` is coordinate-free; OCR is only reachable via `.needsAsyncTextResolution`, gated on a non-nil `modelPoint` (`:1856-1860`). An explicit-but-wrong screen index hard-declines *before* AX/OCR run (`PointDirectiveParsing.swift:126-129` → `CompanionManager.swift:1806-1810`). A synchronous decline draws no visual **and** sets `didReceivePointToolCallForCurrentTurn = true` (`:2698`), disabling the inline fallback too (`:2638`). And the nil-hint exact-only gate (`AXCandidateScoring.swift:171-173`) + the 40 pt tie margin (`:196-199`) suppress legitimate weak/ambiguous matches. **The trade, precisely:** 608e6fe added the out-of-bounds decline and 97d91d7 the nil-hint exact-only gate — both kill wrong rings (help Symptom 1) but emit *nothing* (hurt Symptom 2); the same round's 83580b5 pushed the model to attempt pointing far more often. More attempts × unchanged/tightened decline gates that emit nothing = simultaneously more silence **and** more near-misses.

**Verdict: CONFIRMED (secondary contribution to each symptom, but the primary explanation of the *trade*).** Correction to the candidate: the 0.33×display-edge proximity gate is ~hundreds of points and is **not** tripped by tens-of-points hint error — strike that reasoning; the real weak-match suppressors are the nil-hint exact-only gate and the 40 pt tie margin.

**Fix direction.** Introduce the missing third state. Before any decline, always run the coordinate-free OCR pass (it needs no pixel), and let a genuine where-is intent degrade to an *explicit, enforced* spoken menu-path answer rather than silence. Architecturally, **decouple the accuracy knob from the frequency knob**: the decision "how confident must a match be to *draw*" must be separate from "did the user ask us to locate something" — today one threshold governs both.

### X2 (CONFIRMED) — The system was tuned blind: declines are uninstrumented and the least-accurate outcome logs identically to the most-accurate one. (C6)

**Causal chain.** `SkillyAnalytics` has exactly one pointing event, `trackElementPointed(label)` (`SkillyAnalytics.swift:130-135`), fired at four sites that are **indistinguishable**: inline raw-coord (`CompanionManager.swift:1714`), AX hit (`:1840`), OCR hit (`:1919`), and the no-ring OCR-miss hedge (`:1930`). None of the ~11 decline sites emit anything; there is no `trackPointDeclined`, no path/gate/offset/accuracy field, no where-is-vs-factual classifier. `RealtimeTelemetry.RealtimeTurnRow` has no pointing fields (`RealtimeTelemetry.swift:20-46`), `recordVisionUsed()` is unconditional (`CompanionManager.swift:2342`), and the on-disk telemetry is stale (newest row 2026-06-24, predating every pointing fix) with null tokens on 27/27 rows.

**Verdict: CONFIRMED (enabling cause of non-convergence).** Because a precise AX ring and a known-inaccurate hedge fire the same success event and zero declines are logged, neither an accuracy rate (Symptom 1) nor a decline/only-talked rate (Symptom 2) was ever a measurable number. Every round was tuned against eyeballing, so each fix was unfalsifiable.

**Fix direction.** See "What to instrument first" — this must be fixed *before* Round 5 touches any threshold.

---

## What to instrument first (you have debugged blind 3 times — fix this before anything else)

1. **Split the success event by anchor source and precision.** Replace the single `element_pointed(label)` with `point_outcome{ path: ax_name|ax_hittest|ocr_line|ocr_union|raw_inline|hedge_no_ring, drew_ring: bool, resolved_frame_area, model_guess_to_resolved_offset_pt }`. The offset field is the only way to measure Symptom 1; today an AX ring and a hedge are the same row.
2. **Instrument every decline.** Add `point_declined{ gate: out_of_bounds_2pct | ax_nil_hint_exact_only | ax_tie_margin | wrong_screen_index | malformed_args | ocr_ambiguous | ocr_miss, had_model_point: bool }` at all sites in `CompanionManager.swift:1764/1775/1782/1788/1809/1848` and the AX/OCR nil returns. This turns "the model never pointed" vs "the app declined" from indistinguishable into two numbers.
3. **Tag intent.** Add a `where_is_intent: bool` classification per turn so you can compute the true Symptom-2 rate = (where-is turns with no visual) / (where-is turns), and separate "model never called the tool" from "tool called then declined."
4. **Fix the base telemetry.** `endTurn(usage:)` is receiving nil usage and `recordVisionUsed()` is unconditional — the existing metrics are non-functional; repair them so cost/vision data returns.

Without (1)–(3) there is no dataset to falsify a Round-5 change, and you will trade the symptoms a fourth time.

---

## Recommended fix ORDER (and why this order specifically avoids re-trading)

1. **X2 / C6 — Instrument first.** Cheapest, zero behavioral risk, and it unblocks everything: you cannot tell whether any later change helped without an accuracy offset and a decline rate. Do not skip to a "fix."
2. **X1 / C2 — Break the single dial (add the third state) before touching either primary.** Until "how confident to draw" is decoupled from "did the user ask to locate," fixing Symptom 1 will keep manufacturing Symptom 2 and vice-versa — this is the mechanism that defeated all 3 prior rounds. Concretely: always run coordinate-free OCR before a decline; make a where-is decline an enforced explicit spoken locator, not silence.
3. **P1 / C1 (+ C4, C7) — Attack the precision ceiling.** This is the hardest and most architectural, and it must precede re-enabling aggressive pointing: element-id addressing or a high-res second-round-trip for the anchor, plus the C4 size/dedup/proximity gates on the AX name-walk and the C7 token-sub-box for OCR. **Do this before P2.**
4. **P2 / C3 — Make pointing enforced *last*.** Enforcing "point every time" (where-is classifier + mirror recovery net + temperature pin + prompt de-contradiction) is high-leverage for Symptom 2, but if you do it *before* Step 3 you recreate the 83580b5 trap — more points routed through the imprecise anchor. The model-never-called-the-tool share is orthogonal to precision and may proceed in parallel; the enforce-a-draw share must wait for Step 3.
5. **P2-b / C5** falls out of Steps 2 and 4 (stop returning "describe in words"; reconcile the hedge).

Rationale in one line: **instrument → decouple → make it accurate → then make it frequent.** Every prior round did the last step without the first three.

---

## Refuted hypotheses (do not re-investigate in Round 5)

- **Cursor render offset / edge-clamp as root cause of Symptom 1.** REFUTED. `startNavigatingToElement` does offset the *cursor* +8/+12 and clamp 20 px inside the edge (`OverlayWindow.swift:554-563`), but the precise indicator on the primary path is the **ring**, drawn at the exact unclamped `controlFrame` with no offset/clamp (`PlatoHighlightView.swift`; `CompanionManager.swift:1836-1838`). The offset originates unchanged in the base fork commit (aebc793) — a constant would produce a constant residual, not the incremental improvement the 3 rounds actually showed. It is at most minor cosmetic behavior on the cursor-only fallback paths, where the dominant error is the model's guess anyway (P1).
- **A systematic coordinate-mapping / denominator bug.** REFUTED within C1 verification: the model is given each image's exact pixel dimensions and the map divides by those same dimensions (`CompanionManager.swift:2350-2351`, `:2225-2237`; `HighlightGeometry.swift:51-56`), and `appKitRectFromAXFrame` (`:121-124`) is geometrically correct. The residual is genuine model localization error, not a mapping flip/scale mismatch.
- **"Static show-first prompt gets buried as the transcript grows" (a sub-claim of C5).** REFUTED: `composedSystemPrompt` is re-sent as `session.instructions` every turn (`CompanionManager.swift:977-980` → `OpenAIRealtimeClient.swift:595-597`), so the show-first directive is re-asserted at a privileged position each turn.
- **Frontmost-only AX scope and the exact-when-no-hint gate as major Symptom-1 drivers (sub-claims of C4).** REFUTED/inert: the hit-test secondary uses the system-wide element (cross-app), Plato's target is almost always frontmost, and the exact-when-no-hint gate only fires when the guess is nil (rare, since the tool requires x/y). Keep C4's size-gate, name-mismatch, and lone-exact-proximity findings; drop these two.
