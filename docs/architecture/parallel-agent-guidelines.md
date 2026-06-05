# Parallel Agent Collaboration Guidelines

> Purpose: let multiple agents work on this repo **at the same time** without contradicting each
> other. Read this before starting any multi-agent task. Pairs with `branch-triage-2026-06-03.md`.

## 1. The golden rules
1. **One branch per agent per task.** Never two agents on the same branch. Branch from the
   correct base (see §4) using `feature/<area>-<short-desc>` or `fix/<short-desc>`.
2. **Stay in your ownership lane (§3).** Do not edit files outside your lane without an explicit
   hand-off note. The most common collision is two agents editing the same Swift file.
3. **The Rust core is a coordinated zone (§5).** Changing a public type in `core/domain` ripples
   to THREE binding targets (Swift FFI, mobile UniFFI, web WASM). Never change it solo.
4. **Use git worktrees for isolation.** Each agent gets its own worktree so builds/checkouts don't
   stomp each other: `git worktree add ../skilly-<task> <base-branch>`.
5. **Write a status note before and after.** Drop/update `docs/architecture/status/<branch>.md`
   with: base branch, lane, files you will touch, current state, blockers. This is how agents
   avoid each other.
6. **Never force-push shared branches. Never merge to `main` without sign-off.**

## 2. Hard environment rules (from AGENTS.md — non-negotiable)
- **Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions. Build via Xcode
  only. Agents validate Swift by reasoning + `swift`-level checks, not full app builds.
- **Rust validation is the agent-safe build path**: `cargo check` / `cargo test` are fine and
  expected for any `core/**` or `apps/**` work.
- **All Skilly edits to upstream files** (`leanring_buddyApp.swift`, `CompanionManager.swift`,
  `MenuBarPanelManager.swift`, `CompanionPanelView.swift`) must be **additive** and marked
  `// MARK: - Skilly`. Keep diffs minimal for fork-merge hygiene.
- **No secrets in code.** All keys live as Cloudflare Worker secrets.
- **context-mode routing applies to every agent** (see AGENTS.md): no `curl`/`wget`/inline HTTP/
  `WebFetch`; use `ctx_*` tools; route large output through the sandbox.
- **`CLAUDE.md` is a symlink to `AGENTS.md`** — edit `AGENTS.md` only.

## 3. Ownership lanes (who may edit what)
| Lane | Paths | Notes |
| --- | --- | --- |
| **macOS shell** | `leanring-buddy/**`, `leanring-buddy.xcodeproj/**` | Additive + `// MARK: - Skilly`. No xcodebuild. |
| **Rust core** | `core/domain`, `core/policy`, `core/skills`, `core/realtime` | **Coordinated zone — §5.** |
| **Desktop FFI** | `core/ffi/**` + `leanring-buddy/Rust*Bridge.swift` | ABI changes must update both sides + version. |
| **Mobile SDK** | `core/mobile-sdk/**`, `sdk/ios/**`, `sdk/android/**`, `scripts/*mobile-sdk*` | UniFFI bindings are generated — regenerate, don't hand-edit `sdk/*/generated/`. |
| **Web SDK** | `sdk/web/**`, `@skilly/web` package, `core/*` WASM build config | New lane (Phase 8). |
| **Windows shell** | `apps/windows-shell/**`, `apps/windows-shell-gui/**` | Tauri 2. |
| **Linux shell** | `apps/linux-shell/**` | |
| **Backend (Next.js)** | `apps/web-backend/**` (new) | Next.js + TS + Tailwind + Postgres control plane + dashboard. Owns multi-tenancy + billing. |
| **Worker (retiring)** | `worker/**` | Being retired into the Next.js backend via coordinated cutover; do not add new features here. |
| **Skills content** | `skills/**` / `Skills/**` (⚠ casing — §6) | |
| **Docs/architecture** | `docs/architecture/**` | Each agent owns its own doc file; don't rewrite another's. |
| **CI** | `.github/workflows/**` | Coordinate; one agent owns CI per task. |

## 4. Branch model & base selection (critical — get this right)
**`develop` is the integration branch.** It is cut from `main` and holds ALL in-progress
structural work (the `skills-bridge-swift` slices, the Web SDK, the Next.js backend). **`main`
stays frozen at the stable shipping release** until the whole new structure is ready, then
`develop` → `main` in one reviewed promotion. This keeps the live macOS release pipeline safe
while large cross-platform work integrates.

Base selection:
- **All integration / cross-platform / Rust-core / SDK / backend work** → branch from **`develop`**
  and merge back to **`develop`** (never directly to `main`).
- **The `skills-bridge-swift` slices** (see `branch-triage-2026-06-03.md`) are merged **into
  `develop`**, not main — in reviewed slices, core-first.
- **Urgent macOS-only hotfixes that must ship now** → branch from **`main`**, merge to `main`,
  then forward-merge `main` → `develop` to keep them in sync.
- Do **not** branch from the stale `architecture/rust-core-native-shells`.

## 5. The Rust core coordinated zone
`core/domain` public types (`EntitlementState`, `PolicyInput`, `PolicyDecision`, `BlockReason`,
plus skills/realtime contracts) are the shared ABI for **all** consumers. Process for changing them:
1. Open a `docs/architecture/status/core-change-<desc>.md` proposal first.
2. A single "core agent" makes the change; binding agents (FFI/mobile/web) adapt downstream.
3. Bump the FFI version (`skilly_policy_ffi_version`) and update parity fixtures.
4. Run `cargo test` (fixtures) before any binding regen.
Binding agents must **pull the core change**, not re-edit core themselves.

## 6. Known traps (avoid re-introducing these)
- **`skills/` vs `Skills/` casing**: macOS is case-insensitive; the repo has both. Commit
  `33bdde3` already recovered a Houdini skill from a "feature branch case-mismatch." Pick one
  canonical path per task and confirm with `git ls-files` before adding files.
- **`architecture/rust-core-native-shells` is stale** — do not branch from it or merge it; it's a
  subset of `skills-bridge-swift`.
- **`sdk/*/generated/**` is machine-generated** — edit the UniFFI source + regenerate, never by hand.
- **Duplicate fixes**: the Polar `products[]` fix exists twice (`d6690c5` on main, `51ad722` on a
  branch). Check `git log --all --oneline | grep <subject>` before "fixing" something again.

## 7. Merge protocol
1. Rebase/merge your base branch into your work branch and resolve conflicts **in your lane**.
2. Run lane validation (`cargo test` for Rust; reasoning + targeted checks for Swift).
3. Update your `docs/architecture/status/<branch>.md` to "ready for review".
4. Request review (another agent or human). **Only the integrator merges to `main`.**
5. After merge, delete the work branch and update the triage doc.

## 8. Conflict-avoidance quick checklist (per agent, per task)
- [ ] Correct base branch chosen (§4)?
- [ ] Own worktree created?
- [ ] My files are inside my lane (§3)?
- [ ] Not touching `core/domain` public types without a proposal (§5)?
- [ ] Status note written (§1.5)?
- [ ] No `xcodebuild`, no secrets, additive Swift edits marked `// MARK: - Skilly`?
