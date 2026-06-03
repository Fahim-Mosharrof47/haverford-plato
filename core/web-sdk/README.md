# skilly-core-web-sdk

WebAssembly surface for selected Skilly core APIs — the **browser sibling of
`core/mobile-sdk`** (UniFFI). The same shared core (`policy`, `realtime`,
`skills`) exposed to JavaScript via `wasm-bindgen`. This is **Phase 8.0** of the
Web SDK plan (`docs/architecture/web-sdk-prd.md`).

## Exposed API (JS names)

| JS function | Input | Output | Core source |
|-------------|-------|--------|-------------|
| `canStartTurn(input)` | `WebPolicyInput` | `WebPolicyDecision` | `core/policy` |
| `trialIsExhausted(input)` | `WebPolicyInput` | `boolean` | `core/policy` |
| `usageIsOverCap(input)` | `WebPolicyInput` | `boolean` | `core/policy` |
| `composePrompt(input)` | `{ base_prompt, skill, progress }` | `string` | `core/skills` |
| `replayRealtimeEvents(eventsJson)` | JSON string | `WebRealtimeReplaySummary \| null` | `core/realtime` |

`composePrompt` is web-specific (not in the mobile surface): the browser widget
composes the host site's teaching prompt client-side.

## Build layout

- Pure `*_impl` functions + `Web*` serde types are **always compiled** and
  host-testable — no wasm toolchain required.
- The `wasm-bindgen` glue is gated to `target_arch = "wasm32"` (and the
  `wasm-bindgen`/`serde-wasm-bindgen` deps are `wasm32`-only), so
  `cargo check --workspace` and `cargo test --workspace` stay green on macOS
  without any wasm tooling.

## Validate (host — no wasm toolchain)

```bash
cargo test -p skilly-core-web-sdk
```

Includes `compose_prompt_web_matches_core_skills_fixture`, which reuses the
shared `core/skills` fixture to prove the web prompt output is byte-identical to
the core (and therefore to desktop/mobile).

## Build the browser package (wasm)

```bash
./scripts/build-web-sdk.sh   # wasm-pack → sdk/web/generated/
```

Requires a clean rustup toolchain with `wasm32-unknown-unknown` + `wasm-pack`.
NOTE: a host with both Homebrew rust and rustup at the same version can fail the
wasm32 build with "can't find crate for `core`"; prefer a single rustup
toolchain or run in CI.
