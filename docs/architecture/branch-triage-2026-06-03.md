# Branch Triage — 2026-06-03

> Snapshot of every branch: what it is, its state vs `main`, and the recommended action.
> Pairs with `parallel-agent-guidelines.md`. Verify with `git fetch --all` before acting.

## TL;DR
- **`feature/skills-bridge-swift` is the real cross-platform integration branch** — a *superset*
  of `architecture/rust-core-native-shells`, `feature/skills-core-rust`, and
  `feature/policy-parity-rust`. It has Phases 1–3 + mobile SDK (Phase 6) implemented.
- The `architecture/*` branch is **stale** (57 files behind bridge-swift). Do not use it.
- 5 product branches are **already merged** into main → safe to delete.
- 1 fix branch is a **duplicate** of a commit already on main → delete, don't merge.

## The Rust/cross-platform branch hierarchy (subset → superset)
```
feature/policy-parity-rust        (Phase 1: policy)            ⊂
feature/skills-core-rust          (Phase 1 + skills scaffold)  ⊂
architecture/rust-core-native-shells (integration, STALE)     ⊂
feature/skills-bridge-swift       ← CANONICAL cross-platform branch (Phases 1–3 + mobile SDK)
```
`git log skills-bridge-swift..architecture` is empty → bridge contains everything arch has, plus
57 more files. Branch all new cross-platform/SDK work from **`skills-bridge-swift`**.

## Per-branch table
| Branch | What it is | vs main | Recommendation |
| --- | --- | --- | --- |
| **`feature/skills-bridge-swift`** | Canonical cross-platform integration: Rust core (domain/policy/skills/realtime), desktop bridges, **mobile SDK + UniFFI iOS/Android bindings**, Windows (Tauri 2) + Linux shells, CI, validation reports, Houdini skill. 77 files, +15.2k. | ahead 20, **behind 27** | **KEEP — the integration branch.** Merge `main` into it (resolve Swift conflicts in `CompanionManager`/`EntitlementManager`), validate `cargo test`, then land **in reviewed slices**, not one 15k-line PR. Web SDK (Phase 8) branches from here. |
| `architecture/rust-core-native-shells` | Older integration branch. Subset of bridge-swift. | ahead 7, behind 27 | **ABANDON / DELETE.** Stale; superseded. Do not branch from or merge. |
| `feature/skills-core-rust` | Phase 1 + skills-core scaffold. Subset of bridge-swift. | ahead 6, behind 27 | **DELETE after bridge-swift lands.** Already contained upstream. |
| `feature/policy-parity-rust` | Phase 1 policy parity. Subset of bridge-swift. | ahead 4, behind 27 | **DELETE after bridge-swift lands.** Already contained upstream. |
| `fix/polar-checkout-products-field` | Polar `products[]` payload migration. | ahead 1, behind 9 | **DELETE — already on main** as `d6690c5` (branch commit `51ad722` is a duplicate). Do not merge. |
| `feature/recurring-free-tier` | Local-only branch pointed at old main commit `0367d18` (CONTRIBUTING.md). No remote, no unique diff detected. | local, ancestor of main | **VERIFY then DELETE.** Looks abandoned/stale; confirm it has no un-pushed work before removing. |
| `feature/byok-settings` | BYOK OpenAI key flow. | merged (ahead 0, behind 23) | **DELETE.** Merged via `b4ffb9c`. |
| `feature/admin-checkout-test` | Admin-only Test-checkout button. | merged (ahead 0, behind 6) | **DELETE.** Merged via `3d33e72`. |
| `feature/v1.7-realtime-endpoint-fix` | GA Realtime endpoint + version in UI. | merged (ahead 0, behind 13) | **DELETE.** Merged via `afb937e`. |
| `feature/v1.8-realtime-ga-protocol` | Full GA Realtime protocol migration. | merged (ahead 0, behind 10) | **DELETE.** Merged via `f87927a`. |
| `feature/v1.10-silent-failure-instrumentation` | Silent-failure observability (Swift + Worker). | merged (ahead 0, behind 3) | **DELETE.** Merged via `f1d7684`. |
| `upstream/main`, `upstream/websocket-fixes` | farzaa/clicky upstream. | n/a | **KEEP as upstream remotes** for fork merges. `websocket-fixes` may have stability fixes worth cherry-picking — evaluate separately. |

## What to merge, what to hold
**Merge to `main` (after review):**
- `feature/skills-bridge-swift` — but **NOT as one mega-PR.** Land in slices that match the
  roadmap phases and the ownership lanes, each reviewed:
  1. Rust core crates + fixtures + CI (`core/**`, `.github/workflows/rust-core-shells.yml`)
  2. Desktop bridges (`core/ffi`, `leanring-buddy/Rust*Bridge.swift`, Swift fallback parity)
  3. Mobile SDK (`core/mobile-sdk`, `sdk/ios`, `sdk/android`, packaging scripts + CI)
  4. Windows + Linux shells (`apps/**`)
  5. Docs + validation reports
  Reason: a single 15.2k-line / 77-file PR is unreviewable and high-risk against main's recent
  v1.7–v2.0 changes.

**Do NOT merge:**
- `architecture/rust-core-native-shells`, `feature/skills-core-rust`, `feature/policy-parity-rust`
  — superseded subsets; merging them would just create noise/conflicts.
- `fix/polar-checkout-products-field` — already on main; merging duplicates history.

**Delete now (merged or redundant):** `byok-settings`, `admin-checkout-test`,
`v1.7-realtime-endpoint-fix`, `v1.8-realtime-ga-protocol`, `v1.10-silent-failure-instrumentation`,
`fix/polar-checkout-products-field`. Verify-then-delete: `recurring-free-tier`.

## Conflict hot-spots for the bridge-swift → main merge
`skills-bridge-swift` branched before main's v1.7–v2.0 work, so expect conflicts in:
- `leanring-buddy/CompanionManager.swift` (both sides changed — realtime + instrumentation)
- `leanring-buddy/EntitlementManager.swift`, `TrialTracker.swift`, `UsageTracker.swift`
- `AGENTS.md` (both added sections — incl. the uncommitted context-mode block on `main`)
- `worker/src/index.ts` (arch branch trimmed it; main added instrumentation)
- `skills/` vs `Skills/` casing (see guidelines §6)

## Open questions for the reviewing agent
1. Is `feature/skills-bridge-swift` validated/buildable today, or do the validation reports
   predate main's v1.7–v2.0 changes? (Re-run `cargo test` after merging main in.)
2. Confirm `recurring-free-tier` has no unique un-pushed commits before deleting.
3. Should `upstream/websocket-fixes` be evaluated for cherry-pick into main independently?
4. Is the mobile SDK (Phase 6) intended to ship before or after Web SDK (Phase 8)?
