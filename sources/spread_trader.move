/// altheia_sui_demo::spread_trader
///
/// Demo agent strategy: spread trader on DeepBook v3.
/// Fires when DeepBook v3 mid-price spread exceeds a configured bps threshold.
/// Every action routes through altheia::agent::AgentCap::consume for
/// on-chain policy enforcement before signing.
///
/// On-chain Move side is intentionally thin  the policy enforcement +
/// audit logging live in the altheia-sui modules. This module owns the
/// strategy-specific entry function the off-chain agent calls.
///
/// Status: placeholder. Module body lands Jun 5-6 per
/// altheia-plan/01_PHASES/sui/SHIP_PLAN_2026_05_22.md.
module altheia_sui_demo::spread_trader;

use sui::tx_context::TxContext;

// === Errors ===

const ESpreadBelowThreshold: u64 = 1;

// === Entry functions ===

/// The agent calls this entry function when DeepBook v3 mid-price spread
/// exceeds the configured bps threshold. Routes through
/// altheia::agent::AgentCap::consume for cap + scope + revocation enforcement
/// before placing the DeepBook order.
///
/// Off-chain agent observes the spread, builds the tx, signs via session
/// key, and submits. This function is the trade-time on-chain consumer.
public fun execute_spread_trade(
    _spread_bps: u64,
    _amount: u64,
    _target_pool: address,
    _ctx: &mut TxContext,
) {
    // TODO(Jun 5-6):
    //   1. assert spread_bps > MIN_SPREAD_BPS else ESpreadBelowThreshold
    //   2. call altheia::agent::consume(cap, policy, amount, target_pool, ctx)
    //      (will abort on cap/scope/revocation violation  audit event fires here)
    //   3. on success, place DeepBook v3 order  amount routed to target_pool
    //   4. emit a strategy-level event ("spread trade executed at X bps")
    abort 0
}
