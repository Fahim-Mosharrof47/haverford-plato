//! WebAssembly surface for selected Skilly core APIs.
//!
//! Browser sibling of `core/mobile-sdk` (UniFFI): the SAME shared core
//! (`policy`, `realtime`, `skills`) exposed to JavaScript via `wasm-bindgen`.
//!
//! Structure:
//! - `Web*` serde mirror types + pure `*_impl` functions are always compiled
//!   and host-testable (no wasm toolchain needed), mirroring `Mobile*`.
//! - The `wasm-bindgen` glue lives in the `wasm` module, compiled only for
//!   `wasm32`, and converts JS values via `serde-wasm-bindgen`.
//!
//! Unlike mobile, the web surface also exposes `compose_prompt` (skills),
//! because the browser widget composes the host site's teaching prompt
//! client-side. See `docs/architecture/web-sdk-prd.md` (§8a/§10).

use serde::{Deserialize, Serialize};
use skilly_core_domain::{BlockReason, EntitlementState, PolicyConfig, PolicyInput};
use skilly_core_policy::{can_start_turn, trial_is_exhausted, usage_is_over_cap};
use skilly_core_realtime::{replay_events, RealtimeEvent};
use skilly_core_skills::{compose_prompt, SkillDefinition, SkillProgress};

// ---------------------------------------------------------------------------
// Web mirror types (serde) — JS passes/receives these as plain objects.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum WebEntitlementState {
    None,
    Trial,
    Active,
    CanceledValid,
    CanceledExpired,
    Expired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum WebBlockReason {
    TrialExhausted,
    CapReached,
    SubscriptionInactive,
    Expired,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebPolicyInput {
    #[serde(default)]
    pub user_id: Option<String>,
    pub entitlement_state: WebEntitlementState,
    pub trial_seconds_used: u64,
    pub usage_seconds_used: u64,
    #[serde(default)]
    pub admin_workos_user_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebPolicyDecision {
    pub allowed: bool,
    pub reason: Option<WebBlockReason>,
    pub is_admin_user: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebRealtimeReplaySummary {
    pub phase_name: String,
    pub turns_completed: u64,
}

/// Input for `compose_prompt`. `skill` and `progress` reuse the core/skills
/// serde types directly (no mirror needed — they already derive Serialize).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebComposePromptInput {
    pub base_prompt: String,
    pub skill: SkillDefinition,
    pub progress: SkillProgress,
}

// ---------------------------------------------------------------------------
// Pure implementations (host-testable; the wasm glue is a thin wrapper).
// ---------------------------------------------------------------------------

fn web_policy_config(input: &WebPolicyInput) -> PolicyConfig {
    PolicyConfig {
        admin_workos_user_ids: input.admin_workos_user_ids.clone(),
        ..PolicyConfig::default()
    }
}

pub fn can_start_turn_impl(input: WebPolicyInput) -> WebPolicyDecision {
    let policy_config = web_policy_config(&input);
    let policy_input = PolicyInput {
        user_id: input.user_id,
        entitlement_state: map_web_entitlement_state(input.entitlement_state),
        trial_seconds_used: input.trial_seconds_used,
        usage_seconds_used: input.usage_seconds_used,
    };

    let decision = can_start_turn(&policy_config, &policy_input);
    WebPolicyDecision {
        allowed: decision.allowed,
        reason: map_web_block_reason(decision.reason),
        is_admin_user: decision.is_admin_user,
    }
}

pub fn trial_is_exhausted_impl(input: &WebPolicyInput) -> bool {
    let policy_config = web_policy_config(input);
    let policy_input = PolicyInput {
        user_id: input.user_id.clone(),
        entitlement_state: EntitlementState::Trial,
        trial_seconds_used: input.trial_seconds_used,
        usage_seconds_used: 0,
    };

    trial_is_exhausted(&policy_config, &policy_input)
}

pub fn usage_is_over_cap_impl(input: &WebPolicyInput) -> bool {
    let policy_config = web_policy_config(input);
    let policy_input = PolicyInput {
        user_id: input.user_id.clone(),
        entitlement_state: EntitlementState::Active,
        trial_seconds_used: 0,
        usage_seconds_used: input.usage_seconds_used,
    };

    usage_is_over_cap(&policy_config, &policy_input)
}

pub fn compose_prompt_impl(input: &WebComposePromptInput) -> String {
    compose_prompt(&input.base_prompt, &input.skill, &input.progress)
}

pub fn replay_realtime_events_from_json_impl(events_json: &str) -> Option<WebRealtimeReplaySummary> {
    let parsed_events: Vec<RealtimeEvent> = serde_json::from_str(events_json).ok()?;
    let final_state = replay_events(&parsed_events).ok()?;
    Some(WebRealtimeReplaySummary {
        phase_name: final_state.phase_name().to_string(),
        turns_completed: final_state.turns_completed,
    })
}

fn map_web_entitlement_state(entitlement_state: WebEntitlementState) -> EntitlementState {
    match entitlement_state {
        WebEntitlementState::None => EntitlementState::None,
        WebEntitlementState::Trial => EntitlementState::Trial,
        WebEntitlementState::Active => EntitlementState::Active,
        WebEntitlementState::CanceledValid => EntitlementState::Canceled {
            access_still_valid: true,
        },
        WebEntitlementState::CanceledExpired => EntitlementState::Canceled {
            access_still_valid: false,
        },
        WebEntitlementState::Expired => EntitlementState::Expired,
    }
}

fn map_web_block_reason(block_reason: Option<BlockReason>) -> Option<WebBlockReason> {
    match block_reason {
        Some(BlockReason::TrialExhausted) => Some(WebBlockReason::TrialExhausted),
        Some(BlockReason::CapReached) => Some(WebBlockReason::CapReached),
        Some(BlockReason::SubscriptionInactive) => Some(WebBlockReason::SubscriptionInactive),
        Some(BlockReason::Expired) => Some(WebBlockReason::Expired),
        None => None,
    }
}

// ---------------------------------------------------------------------------
// wasm-bindgen glue — compiled only for the browser (wasm32).
// JS calls these with plain objects; serde-wasm-bindgen does the conversion.
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
mod wasm {
    use super::*;
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen(js_name = canStartTurn)]
    pub fn can_start_turn(input: JsValue) -> Result<JsValue, JsValue> {
        let parsed: WebPolicyInput = serde_wasm_bindgen::from_value(input)?;
        let decision = can_start_turn_impl(parsed);
        Ok(serde_wasm_bindgen::to_value(&decision)?)
    }

    #[wasm_bindgen(js_name = trialIsExhausted)]
    pub fn trial_is_exhausted(input: JsValue) -> Result<bool, JsValue> {
        let parsed: WebPolicyInput = serde_wasm_bindgen::from_value(input)?;
        Ok(trial_is_exhausted_impl(&parsed))
    }

    #[wasm_bindgen(js_name = usageIsOverCap)]
    pub fn usage_is_over_cap(input: JsValue) -> Result<bool, JsValue> {
        let parsed: WebPolicyInput = serde_wasm_bindgen::from_value(input)?;
        Ok(usage_is_over_cap_impl(&parsed))
    }

    #[wasm_bindgen(js_name = composePrompt)]
    pub fn compose_prompt(input: JsValue) -> Result<String, JsValue> {
        let parsed: WebComposePromptInput = serde_wasm_bindgen::from_value(input)?;
        Ok(compose_prompt_impl(&parsed))
    }

    #[wasm_bindgen(js_name = replayRealtimeEvents)]
    pub fn replay_realtime_events(events_json: String) -> Result<JsValue, JsValue> {
        let summary = replay_realtime_events_from_json_impl(&events_json);
        Ok(serde_wasm_bindgen::to_value(&summary)?)
    }
}

// ---------------------------------------------------------------------------
// Native parity tests — prove the web surface matches the shared core.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_start_turn_web_blocks_exhausted_trial() {
        let decision = can_start_turn_impl(WebPolicyInput {
            user_id: Some("user-1".to_string()),
            entitlement_state: WebEntitlementState::Trial,
            trial_seconds_used: 901,
            usage_seconds_used: 0,
            admin_workos_user_ids: Vec::new(),
        });

        assert!(!decision.allowed);
        assert_eq!(decision.reason, Some(WebBlockReason::TrialExhausted));
        assert!(!decision.is_admin_user);
    }

    #[test]
    fn can_start_turn_web_allows_admin_regardless() {
        let decision = can_start_turn_impl(WebPolicyInput {
            user_id: Some("admin-1".to_string()),
            entitlement_state: WebEntitlementState::Expired,
            trial_seconds_used: 99_999,
            usage_seconds_used: 99_999,
            admin_workos_user_ids: vec!["admin-1".to_string()],
        });

        assert!(decision.allowed);
        assert!(decision.is_admin_user);
    }

    /// Reuses the shared `core/skills` fixture to prove the web `compose_prompt`
    /// produces byte-identical output to the core (and therefore to desktop).
    #[test]
    fn compose_prompt_web_matches_core_skills_fixture() {
        let fixture_path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/fixtures/compose_prompt_fixture.json"
        );
        let fixture_json =
            std::fs::read_to_string(fixture_path).expect("skills fixture should be readable");
        let fixture: serde_json::Value =
            serde_json::from_str(&fixture_json).expect("fixture should parse");

        let input = WebComposePromptInput {
            base_prompt: fixture["base_prompt"].as_str().unwrap().to_string(),
            skill: serde_json::from_value(fixture["skill"].clone()).expect("skill should parse"),
            progress: serde_json::from_value(fixture["progress"].clone())
                .expect("progress should parse"),
        };

        let composed = compose_prompt_impl(&input);
        assert_eq!(composed, fixture["expected_prompt"].as_str().unwrap());
    }

    #[test]
    fn replay_realtime_events_web_returns_summary() {
        let events_json = r#"[
            {"type":"turn_started","turn_id":"turn-1"},
            {"type":"audio_capture_committed","turn_id":"turn-1"},
            {"type":"response_started","turn_id":"turn-1"},
            {"type":"response_completed","turn_id":"turn-1"}
        ]"#;

        let summary = replay_realtime_events_from_json_impl(events_json)
            .expect("valid event sequence should produce a summary");
        assert_eq!(summary.phase_name, "completed");
        assert_eq!(summary.turns_completed, 1);
    }
}
