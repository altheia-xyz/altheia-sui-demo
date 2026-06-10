/// altheia_sui_demo::scenarios_tests
///
/// Six-scenario demo. Each test is a single, runnable assertion of one
/// row in the demo matrix:
///   1. allowed under cap          → trade settles
///   2. over per-tx cap            → ECapExceededPerTx (4)
///   3. over per-day cap           → ECapExceededPerDay (5)
///   4. disallowed package         → EPackageNotAllowed (6)
///   5. paused agent               → EPolicyPaused      (3)
///   6. revoked agent              → EPolicyRevoked     (1)
///
/// Plus one strategy-local check:
///   7. spread below threshold     → ESpreadBelowThreshold (demo-local, 1)
///
/// Run with: `sui move test`
#[test_only]
module altheia_sui_demo::scenarios_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia_sui_demo::spread_trader;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const RECIPIENT: address = @0xFACE;
const POOL_SUI_USDC: address = @0xDEEB;   // allowed
const POOL_RANDOM: address = @0xBADD;     // disallowed

const PER_TX_CAP: u64 = 100;
const PER_DAY_CAP: u64 = 500;

/// One-shot setup: provision vault, fund it, mint policy + AgentCap,
/// return everything the scenarios need.
fun setup(): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(10_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let pid = vault::mint_policy(
        &v, &owner, b"spread-trader",
        PER_TX_CAP, PER_DAY_CAP, vector[POOL_SUI_USDC],
        1_000_000_000_000, &clk, ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(&v, &owner, pid, b"spread-trader", AGENT, ts::ctx(&mut scenario));
    ts::return_shared(v);
    (scenario, owner, clk)
}

fun take_trade_handles(
    scenario: &ts::Scenario,
): (Vault<SUI>, AgentCap, Policy) {
    let v = ts::take_shared<Vault<SUI>>(scenario);
    let cap = ts::take_from_sender<AgentCap>(scenario);
    let p = ts::take_shared<Policy>(scenario);
    (v, cap, p)
}

fun return_trade_handles(
    scenario: &ts::Scenario,
    v: Vault<SUI>,
    cap: AgentCap,
    p: Policy,
) {
    let _ = scenario;
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
}

// =========================================================================
// Scenario 1 — allowed under cap → trade settles
// =========================================================================

#[test]
fun scenario_1_allowed_under_cap() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let (mut v, cap, mut p) = take_trade_handles(&scenario);
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        10,                 // spread_bps (above MIN_SPREAD_BPS=5)
        50,                 // amount (under PER_TX_CAP=100)
        POOL_SUI_USDC,
        RECIPIENT,
        &clk,
        ts::ctx(&mut scenario),
    );
    assert!(coin::value(&coin_out) == 50, 0);
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// =========================================================================
// Scenario 2 — over per-tx cap → ECapExceededPerTx (4)
// =========================================================================

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerTx)]
fun scenario_2_over_per_tx_cap() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let (mut v, cap, mut p) = take_trade_handles(&scenario);
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        10, 101,            // amount = 101 > PER_TX_CAP = 100 → ABORT
        POOL_SUI_USDC, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// =========================================================================
// Scenario 3 — over per-day cap → ECapExceededPerDay (5)
// =========================================================================

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerDay)]
fun scenario_3_over_per_day_cap() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let (mut v, cap, mut p) = take_trade_handles(&scenario);

    // Five 100-amount trades = 500 (= PER_DAY_CAP). All allowed.
    let mut i = 0;
    while (i < 5) {
        let coin_out = spread_trader::execute_trade(
            &mut v, &cap, &mut p,
            10, 100, POOL_SUI_USDC, RECIPIENT, &clk, ts::ctx(&mut scenario),
        );
        test_utils::destroy(coin_out);
        i = i + 1;
    };

    // Sixth trade pushes cumulative to 600 > 500 → ABORT
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        10, 100, POOL_SUI_USDC, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// =========================================================================
// Scenario 4 — disallowed package → EPackageNotAllowed (6)
// =========================================================================

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPackageNotAllowed)]
fun scenario_4_disallowed_package() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let (mut v, cap, mut p) = take_trade_handles(&scenario);
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        10, 50,
        POOL_RANDOM,        // NOT in allowed_packages → ABORT
        RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// =========================================================================
// Scenario 5 — paused agent → EPolicyPaused (3)
// =========================================================================

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyPaused)]
fun scenario_5_paused_agent() {
    let (mut scenario, owner, clk) = setup();
    // Operator pauses the policy.
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault<SUI>>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_pause_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    // Agent tries to trade → aborts on pause.
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        10, 50, POOL_SUI_USDC, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// =========================================================================
// Scenario 6 — revoked agent → EPolicyRevoked (1)
// =========================================================================

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyRevoked)]
fun scenario_6_revoked_agent() {
    let (mut scenario, owner, clk) = setup();
    // Operator revokes the policy.
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault<SUI>>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_revoke_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    // Agent tries to trade after revoke → aborts.
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        10, 50, POOL_SUI_USDC, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// =========================================================================
// Scenario 7 (strategy-local) — spread below threshold → ESpreadBelowThreshold
// =========================================================================

#[test]
#[expected_failure(abort_code = ::altheia_sui_demo::spread_trader::ESpreadBelowThreshold)]
fun scenario_7_spread_below_threshold() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let (mut v, cap, mut p) = take_trade_handles(&scenario);
    let coin_out = spread_trader::execute_trade(
        &mut v, &cap, &mut p,
        3,                  // spread_bps < MIN_SPREAD_BPS=5 → ABORT
        50, POOL_SUI_USDC, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    return_trade_handles(&scenario, v, cap, p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
