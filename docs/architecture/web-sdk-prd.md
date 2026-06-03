# PRD + Execution Plan: Skilly for Web (Embeddable SDK)

> Status: **Draft for review** (not yet an accepted ADR). Proposed as **Phase 8** on top of the
> Rust-core + native-shells architecture. Companion to `web-sdk-sketch.md`,
> `rust-core-native-shells-prd.md`, and `phase-7-windows-shell-prd.md`.
> Numbered Phase 8 because Phase 7 (Windows shell) already exists on `feature/skills-bridge-swift`.

## 1. Summary
Ship an **embeddable Skilly** that a website owner installs on their own web app (one `<script>`
tag) so that **their end-users** get a Skilly companion living *inside the host website*:
guided onboarding and live customer support that **sees the page, points at the right UI
element, and talks the user through it** — driven by a `SKILL.md` the site owner authors about
their own product.

This is a **B2B reframe** of Skilly: desktop/mobile Skilly is B2C (the end-user installs it); Web
Skilly is SaaS the **site owner** installs and pays for; their visitors are the end-users.

## 2. Problem
- Skilly's teaching value (see → point → guide by voice) is locked to a macOS app a user must
  install. Websites cannot offer it to their own visitors.
- Existing in-app guidance tools (Intercom, Pendo, Appcues, CommandBar) are static tours or chat
  — none combine voice + a companion that physically points at the live UI element.
- The Rust core was built to be reused; there is no web/JS consumer of it yet.

## 3. Goals
1. A website owner can add Skilly to their site with one script tag + an authored SKILL.md.
2. Their visitors can ask "how do I X?" and watch a Skilly cursor point at the real element.
3. **Reuse the shared Rust core** (`core/skills`, `core/policy`, `core/realtime`) via **WASM** —
   prompt composition, curriculum, budget, and policy identical to desktop/mobile.
4. Multi-tenant, metered, and billable to the site owner without leaking provider API keys.

## 4. Non-goals (v1)
1. Running the desktop Skilly app inside a browser (it needs OS capture/hotkey/overlay — out).
2. Reading cross-origin iframes inside the host page (browser-blocked).
3. Pixel-perfect parity with the desktop overlay animation.
4. A visual no-code skill builder (v1 = author SKILL.md + minimal config UI).

## 5. Users
- **Site owner / developer** (buyer): installs the widget, authors the skill, pays per usage.
- **End-user / visitor** (consumer): the site's customer who gets onboarding/support.
- **Skilly platform**: multi-tenant backend operator.

## 6. The core reframe: "screen" → DOM
Desktop Skilly is browser-blocked because it needs OS-level capture/hotkey/overlay. The embedded
case needs none of that — the host page *is* the surface.

| Desktop concept | Web equivalent | Note |
| --- | --- | --- |
| ScreenCaptureKit screenshot | **DOM digest**: a11y tree + visible text + element registry (selectors + bounding rects); optional `html2canvas` frame | Cheaper, more accurate, privacy-friendlier |
| `[POINT:x,y:label:screenN]` | **`[POINT:selector:label]`** → resolve selector → `getBoundingClientRect()` → animate overlay; re-resolve on scroll/resize | More robust than coords |
| NSPanel / overlay window | **Shadow-DOM widget** mounted in host page (style-isolated) | No OS window, no permissions |
| Screen-recording + a11y permission | none — only the host page | #1 desktop friction removed |
| Global push-to-talk CGEvent tap | `getUserMedia` mic + in-widget button | Browser-native |

## 7. Architecture (see `web-sdk-sketch.md` for the diagram)
1. **`@skilly/web` SDK** — script tag + npm package. Mounts a **Shadow-DOM** widget (cursor
   overlay, mic button, response bubble). Owns DOM reading, selector-based pointing, and the
   browser Realtime voice pipeline (`getUserMedia` → OpenAI Realtime WS → Web Audio TTS).
2. **`skilly-core.wasm`** — `core/{domain,policy,skills,realtime}` compiled via `wasm-bindgen`.
   Same parity fixtures as desktop/mobile. This is the **third binding target** alongside the
   desktop C-ABI (`core/ffi`) and mobile UniFFI (`core/mobile-sdk`).
3. **Single backend — Next.js (TypeScript + Tailwind) + Postgres** (the team's standard stack).
   **Decision: retire the Cloudflare Worker** and consolidate everything here. The Worker's logic
   is TypeScript, so its routes are **ported (not rewritten)** into Next.js route handlers —
   reuse, not reinvention. The one backend owns both the web control plane *and* the existing
   desktop/mobile endpoints:
   - **Runtime (end-user widget) path**: `/api/web/token` — validate publishable key + **origin
     allowlist** + per-tenant **rate limit/quota**, then mint ephemeral OpenAI Realtime secret
     (OpenAI key stays server-side). `/api/web/skill` — serve the tenant's compiled SKILL.md.
   - **Control plane**: tenant accounts; **publishable (`pk_`) + secret (`sk_`) keys**; origin
     allowlists; per-tenant **SKILL.md storage** + compile/validate (reuse `SkillValidation` via
     the **core parser**, see §8b); **usage metering** (conversation/minute rows in Postgres) →
     **billing** (Polar; port existing checkout/webhook + Standard-Webhooks signature code).
   - **Site-owner dashboard UI** (Next.js + Tailwind): author SKILL.md, configure widget
     (colors/trigger/voice/lang), view usage/analytics. WorkOS for site-owner sign-in.
   - **Migrated desktop/mobile endpoints** (absorbed from the Worker): `/openai/token`,
     `/auth/url|callback|token`, `/entitlement`, `/checkout/create`, `/portal`, `/webhooks/polar`.

   ⚠ **Worker retirement is a coordinated cutover, not a delete.** The Worker currently serves the
   shipping macOS app. Sequence: stand up Next.js routes → re-point the app's worker base URL
   (`AppSettings`) behind a release → verify → *then* decommission the Worker. Keep the Worker
   alive until the desktop cutover ships, to preserve release continuity (PRD constraint #1).

## 8. What the Rust core powers vs. what's net-new
**Reused (core, identical to desktop/mobile):** 5-layer prompt composition, curriculum/stage
advancement, prompt budget trimming, policy decisions (re-cast as tenant metering), telemetry
schema.

**Net-new for web:** DOM digest, selector-based pointing, Shadow-DOM widget, **multi-tenancy**
(tenant accounts, publishable/secret keys, origin allowlist), **site-owner dashboard** (Next.js +
Tailwind), **B2B metered billing** (Postgres usage rows; a new tenant-keyed entitlement dimension).

**Easier than desktop:** no OS permission prompts; semantic DOM > pixel screenshots; `<script>`
distribution vs notarized DMG; nothing sandbox-blocked since we only need the host page.

### 8a. Reuse map — start from what already exists (do NOT re-code)
| Need (web) | Already built — reuse | Action |
| --- | --- | --- |
| Prompt composition / curriculum / budget | `core/skills` (`compose_prompt`, `trim_vocabulary`) | Reuse as-is via WASM |
| Policy / entitlement decisions | `core/policy` + fixtures | Reuse as-is via WASM |
| Realtime turn/session state machine | `core/realtime` (`apply_event`, `replay_events`) | Reuse as-is via WASM |
| Binding-layer pattern | `core/mobile-sdk` (UniFFI `Record`/`Enum` + `#[uniffi::export]`) | **Mirror it** as `core/web-sdk` with `wasm-bindgen`; extend exposed set to add `compose_prompt` |
| SDK package + sample layout | `sdk/ios`, `sdk/android` (+ sample apps) | Mirror as `sdk/web` |
| Bindgen + packaging | `scripts/generate-mobile-sdk-bindings.sh`, `package-mobile-sdk.sh` | Mirror as web equivalents |
| CI | `.github/workflows/{rust-core-shells,mobile-sdk-artifacts}.yml` | Mirror as `web-sdk-artifacts.yml` |
| Token mint + origin/secret handling | Worker `/openai/token`, key parsing | Reuse as edge gateway (§7.3) |
| Auth + billing | Worker WorkOS auth + Polar checkout/webhooks | Reuse for tenant auth + billing |
| Skill safety scan | `SkillValidation.swift` | Reuse (ideally via core parser — below) |

### 8b. The one real gap — parse-once-in-core (do NOT write a JS parser)
`core/skills` only **composes** prompts from an already-structured `SkillDefinition`; it does **not
parse** `SKILL.md`. Parsing currently lives only in Swift (`SkillDefinition.swift`,
`SkillMetadata.swift`, `CurriculumStage.swift`, `VocabularyEntry.swift`, `SkillValidation.swift`).
**Decision: port the parser + validator into `core/skills` (Rust)** so web, the dashboard, and
future shells all reuse one implementation, rather than writing a second JS parser. This converts
a reinvention into a reuse and is consistent with the architecture thesis ("logic in core").

## 9. Public SDK surface (draft — for the reviewing agent to critique)
```html
<script src="https://cdn.tryskilly.app/web/v1.js"
        data-skilly-key="pk_live_..."
        data-skilly-skill="acme-onboarding"
        defer></script>
```
```ts
// programmatic API
Skilly.init({ key, skill, theme?, voice?, locale?, consent? })
Skilly.start(goal?: string)          // open companion, optionally with an onboarding goal
Skilly.on('point', cb) / ('turn', cb) / ('complete', cb)
Skilly.identify(endUserId, traits?)  // optional, for tenant analytics
Skilly.destroy()
// element targeting fallback authored by site owner:
//   <button data-skilly="checkout-button"> ... </button>
```

## 10. Phasing — proposed Phase 8 sub-phases
- **8.0 WASM core**: compile `core/{domain,policy,skills}` via `wasm-bindgen`; reuse parity
  fixtures; publish `@skilly/core-wasm`. (Depends on Phase 2 `core/skills` — **already done** on
  `skills-bridge-swift`.)
- **8.1 Embed skeleton**: `@skilly/web` Shadow-DOM widget (cursor, mic, bubble); script + npm.
- **8.2 DOM digest + selector pointing engine** (auto + `data-skilly` annotation fallback).
- **8.3 Browser Realtime voice pipeline** (`getUserMedia` → OpenAI Realtime → Web Audio).
- **8.4 Next.js backend — control plane**: tenant accounts, `pk_`/`sk_` keys, origin allowlist,
  `/api/web/token` mint + rate limit, per-tenant SKILL.md storage. Postgres schema.
- **8.5 Site-owner dashboard** (Next.js + Tailwind): SKILL.md authoring (reuse `SkillValidation`
  via core parser), widget config, usage view.
- **8.6 B2B billing + metering**: Postgres usage rows, Polar (ported from Worker), tenant entitlements.
- **8.7 Worker retirement (coordinated)**: port desktop/mobile routes into Next.js → re-point app
  base URL behind a release → verify → decommission Worker. Gated on macOS release continuity.

**Dependencies:** 8.0 needs `core/skills` on the integration branch (already on
`skills-bridge-swift`). 8.3 reuses `core/realtime` (already there). 8.4–8.7 are the only phases
that need the backend decision (Next.js + Postgres, Worker retired). **8.0–8.3 run against a
single dev token and need none of it** — start there.

## 11. Acceptance criteria (v1 smoke test)
A site owner pastes one `<script>` tag, authors a SKILL.md, and a visitor on their live site asks
"how do I X?" and watches the Skilly cursor point at the real button — with prompt composition
served by the shared Rust core (WASM), token minted per-tenant, and the interaction metered.

## 12. Risks / open decisions (please pressure-test these, reviewer)
1. **Pointing strategy**: auto DOM-read (zero setup, brittle) vs. `data-skilly` annotations
   (robust, setup cost). Recommend hybrid: auto + annotation + text-match fallback.
2. **Privacy/GDPR**: visitor voice + DOM content flow to OpenAI. Site owner = data controller,
   Skilly = processor. Needs consent UX, PII redaction in the DOM digest, DPA terms.
3. **Cost/latency at scale**: Realtime voice per visitor is expensive → offer a text/chat tier;
   voice as premium.
4. **Publishable-key abuse**: strict origin allowlist + per-tenant rate limits + ephemeral-secret
   minting; never ship the OpenAI key.
5. **Selector resilience** across host-site deploys: prefer aria/role/text + `data-skilly`.
6. **Cross-origin iframes** unreadable — documented limitation; may need a host-side helper snippet.
7. **WASM bundle size / cold start** — measure; lazy-load core after first interaction.

## 13. Comparison anchor
Intercom/Drift (messaging), Pendo/Appcues/Userpilot (tours), CommandBar (in-app assistant).
Skilly's wedge: **voice + a companion that physically points at the live UI element**, driven by
a site-authored skill — not a static scripted tour.
