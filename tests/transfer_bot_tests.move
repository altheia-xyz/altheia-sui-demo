/// altheia_sui_demo::transfer_bot_tests
///
/// Substrate-reuse proof: a SECOND, unrelated agent (transfer_bot) on the
/// SAME altheia-sui primitive is bounded by the same policy. Shows the
/// enforcement is the substrate's, not the agent's — exactly two cases:
///   A. allowed under cap        → transfer settles
///   B. over per-tx cap          → ECapExceededPerTx (4), same as spread_trader
#[test_only]
module altheia_sui_demo::transfer_bot_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia_sui_demo::transfer_bot;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const RECIPIENT: address = @0xFACE;
const ALLOWED_PKG: address = @0xDEEB;

fun setup(): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(10_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let pid = vault::mint_policy(
        &v, &owner, b"transfer-bot", 100, 500, vector[ALLOWED_PKG],
        1_000_000_000_000, &clk, ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(&v, &owner, pid, b"transfer-bot", AGENT, ts::ctx(&mut scenario));
    ts::return_shared(v);
    (scenario, owner, clk)
}

#[test]
fun transfer_allowed_under_cap() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let coin_out = transfer_bot::send(
        &mut v, &cap, &mut p, 40, ALLOWED_PKG, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    assert!(coin::value(&coin_out) == 40, 0);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerTx)]
fun transfer_over_cap_denied_by_same_substrate() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let coin_out = transfer_bot::send(
        &mut v, &cap, &mut p, 101, ALLOWED_PKG, RECIPIENT, &clk, ts::ctx(&mut scenario),
    );
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
