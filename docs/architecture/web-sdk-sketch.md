# Sketch: Skilly for Web (Embeddable SDK)

> Status: Exploratory sketch (not an accepted ADR). Proposed as a future **Phase 7** on top of
> the Rust-core + native-shells architecture. Companion to `rust-core-native-shells-prd.md`.

## The product, in one line
An embeddable widget + SDK that **website owners install on their own web app** so *their*
end-users get a Skilly companion — guided onboarding and live customer support that **sees the
page, points at the right UI element, and talks the user through it** — living directly inside
the host website.

This is a **B2B reframe** of Skilly. Desktop Skilly = a B2C app the end-user installs. Web Skilly
= a SaaS the *site owner* installs once; their visitors are the end-users.

## Why this fits the new architecture
The Rust-core migration already isolates deterministic, platform-agnostic logic
(`core/domain`, `core/policy`, `core/skills`). That core compiles to **WASM** with the same
boundary planned for the Phase 6 mobile SDK (UniFFI) — only the binding target changes
(`wasm-bindgen`/JS instead of Swift/Kotlin). So skill prompt composition, curriculum
advancement, budget trimming, and policy decisions are **shared and identical** to desktop.

## The key reframe: "screen" → DOM
Desktop Skilly is blocked from the browser because it needs OS-level screen capture, global
hotkeys, and an always-on-top overlay. **None of that is needed for the embedded use case** —
because the host page IS the surface:

| Desktop concept | Web equivalent | Notes |
| --- | --- | --- |
| ScreenCaptureKit screenshot | **DOM digest** (a11y tree + visible text + element registry) and/or `html2canvas` frame | Cheaper, more accurate, privacy-friendlier than pixels |
| `[POINT:x,y:label:screenN]` (screen coords) | **`[POINT:selector:label]`** → resolve selector → `getBoundingClientRect()` → animate overlay | Re-resolves on scroll/resize. More robust than coords |
| NSPanel / overlay window | **Shadow-DOM widget** mounted into host page (style-isolated) | No OS window, no permissions |
| OS screen-recording + accessibility permission | none — only reads the host page | Huge friction removed |
| Global push-to-talk CGEvent tap | `getUserMedia` mic + in-widget button | Browser-native |

Net: the web target is **architecturally unblocked AND easier than desktop** for this scope,
because semantic DOM access beats pixel screenshots and there are no OS permission walls.

## Architecture

```
 Host website (site owner's web app)
 ┌──────────────────────────────────────────────────────────┐
 │  <script src="cdn.tryskilly.app/web.js" data-key="pk_..."> │
 │                                                            │
 │   @skilly/web SDK  (Shadow DOM, style-isolated)            │
 │   ├─ Widget UI: cursor overlay · mic button · response bubble
 │   ├─ DOM reader: a11y tree + element registry + selectors  │
 │   ├─ Pointing: selector → bounding rect → bezier animation │
 │   ├─ Voice: getUserMedia → OpenAI Realtime WS → Web Audio  │
 │   └─ skilly-core.wasm  (domain · policy · skills)          │
 │            shared logic, identical to desktop              │
 └───────────────┬────────────────────────────────────────────┘
                 │ publishable key (origin-locked)
                 ▼
   Cloudflare Worker (multi-tenant)
   ├─ /web/token       mint ephemeral OpenAI Realtime secret, scoped per tenant
   ├─ /web/skill       serve the tenant's SKILL.md (their product knowledge)
   ├─ origin allowlist publishable key bound to site owner's domain(s)
   ├─ usage metering    per-conversation / per-minute → tenant billing
   └─ existing OpenAI key stays server-side (never in the widget)

   Site-owner dashboard (separate web app)
   ├─ Author SKILL.md: product knowledge, onboarding stages, UI vocabulary→selectors
   ├─ SkillValidation (reuse existing banned-phrase / injection scanner — critical for hosted multi-tenant)
   ├─ Configure widget: colors, trigger, voice, language
   └─ Billing + usage analytics
```

## What the Rust core powers on web (direct reuse)
- 5-layer skill prompt composition (`core/skills`)
- Curriculum engine / stage advancement on transcript+response signals
- Prompt budget trimming (vocabulary 6K ceiling)
- Policy/entitlement decisions (`core/policy`) — re-cast as **tenant metering**
- Shared telemetry event schema

## What is net-new for web (cannot reuse desktop shell)
- DOM digest instead of ScreenCaptureKit
- Selector-based pointing instead of screen coordinates
- Shadow-DOM widget instead of NSPanel/overlay window
- **Multi-tenancy**: tenant accounts, publishable/secret keys, origin allowlist
- **Site-owner authoring dashboard** + per-tenant skill storage
- **B2B usage billing** (site owner pays; metered per conversation/minute) — a new
  `EntitlementManager` dimension keyed by tenant, not end-user trial/cap

## What gets easier than desktop
- No OS permission prompts (screen recording / accessibility) — the #1 desktop friction, gone
- Semantic DOM > pixel screenshots → more reliable pointing and grounding
- Distribution is a `<script>` tag, not a notarized DMG + Sparkle appcast
- No sandbox-blocked capabilities, because we only need the host page — not the whole OS

## Hard problems / open decisions
1. **Pointing strategy**: auto-read DOM (zero setup, brittle to redesigns) vs. require site
   owners to annotate targets with `data-skilly="checkout-button"` (robust, setup cost). Likely
   hybrid: auto by default, annotations + text-match fallback for stability.
2. **Privacy/compliance**: end-user voice + DOM content flow to OpenAI. Needs tenant-configurable
   consent UX, PII redaction in the DOM digest, GDPR/data-processing terms. Site owner is the
   data controller; Skilly is a processor.
3. **Cross-origin iframes** inside the host page are unreadable — document the limitation.
4. **Selector resilience** across host-site deploys (aria/role/text fallbacks).
5. **Cost & latency at B2B scale** — Realtime voice per visitor is expensive; consider a
   text/chat-only tier and voice as premium.
6. **Key security** — publishable key is public; protect with strict origin allowlist + per-tenant
   rate limits + ephemeral-secret minting (never ship the OpenAI key).

## Proposed Phase 7 sub-phases
- **7.0** WASM-compile `core/{domain,policy,skills}` + `wasm-bindgen` JS bindings (parity fixtures reused)
- **7.1** `@skilly/web` embed skeleton: Shadow-DOM widget (cursor, mic, bubble), script + npm
- **7.2** DOM digest + selector-based pointing engine
- **7.3** Browser Realtime voice pipeline (mic → OpenAI Realtime → Web Audio TTS)
- **7.4** Multi-tenant Worker: publishable keys, origin allowlist, scoped token mint, metering
- **7.5** Site-owner authoring dashboard + per-tenant SKILL.md storage (reuse SkillValidation)
- **7.6** B2B usage billing (tenant entitlements, metered)

Smoke-test exit criteria (mirrors PRD style): a site owner can paste one `<script>` tag, author a
SKILL.md, and a visitor on their site can ask "how do I X?" and watch the Skilly cursor point at
the real button on the page — with prompt composition served by the shared Rust core.

## Comparison anchor
Closest market analogs: Intercom / Drift (in-app messaging), Pendon/Appcues/Userpilot (product
tours), CommandBar (in-app assistant). Skilly's wedge vs. all of them: **voice + a companion that
physically points at the live UI element**, driven by a site-authored "skill," not a static
scripted tour.
