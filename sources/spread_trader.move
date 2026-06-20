/// altheia_sui_demo::spread_trader
///
/// Demo strategy: spread trader. The off-chain agent observes
/// DeepBook v3 mid-price and fires `execute_trade` when the spread
/// exceeds the configured bps threshold.
///
/// On-chain, the trade routes through the altheia vault → policy →
/// receipt path before any Coin moves: amount-cap, package-scope,
/// revocation, paused, and expiry are all enforced atomically by
/// altheia::policy::check_and_consume; the hot-potato
/// altheia::receipt::WithdrawalReceipt MUST be consumed before the
/// PTB ends, else the entire trade aborts.
///
/// The Move side is intentionally thin — strategy + policy enforcement.
/// The off-chain agent owns market observation, signing, submission.
module altheia_sui_demo::spread_trader;

use sui::clock::Clock;
use sui::coin::{Self, Coin};
use deepbook::pool::{Self as dbpool, Pool};
use token::deep::DEEP;
use altheia::vault::{Self, Vault};
use altheia::policy::{Self, Policy};
use altheia::agent::AgentCap;
use altheia::receipt;
use altheia::registry::{Self, AdapterRegistry};
use altheia_sui_demo::deepbook_adapter;

// === Constants ===

/// Minimum spread (basis points) below which a trade is rejected.
/// 5 bps = 0.05%. Stops noise fires.
const MIN_SPREAD_BPS: u64 = 5;

// === Errors ===

const ESpreadBelowThreshold: u64 = 1;
const EValueGuardNotConfigured: u64 = 2;
const EAdapterNotApproved: u64 = 3;

// === Entry ===

/// Execute a spread trade. The off-chain agent computes `spread_bps`
/// from DeepBook v3 mid-price, picks `amount` and `target_pool`, and
/// calls this with their AgentCap.
///
/// Aborts:
///   - ESpreadBelowThreshold if spread_bps < MIN_SPREAD_BPS
///   - any abort code from altheia::policy::check_and_consume
///     (revoked / paused / expired / over-tx-cap / over-day-cap /
///     package-not-allowed / wrong-policy)
///   - any abort code from altheia::vault::withdraw_with_receipt
///     (wrong-vault, insufficient-balance)
public fun execute_trade<T>(
    vault: &mut Vault<T>,
    cap: &AgentCap,
    policy: &mut Policy,
    spread_bps: u64,
    amount: u64,
    target_pool: address,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(spread_bps >= MIN_SPREAD_BPS, ESpreadBelowThreshold);
    let (coin, r) = vault::withdraw_with_receipt(
        vault,
        cap,
        policy,
        amount,
        target_pool,
        recipient,
        b"SPREAD_TRADE",
        clock,
        ctx,
    );
    // Hot-potato attest closes the receipt; without this call the PTB
    // cannot settle. The agent's downstream DeepBook swap (off-chain
    // PTB composition) would chain into this Coin.
    receipt::attest_simple(r, recipient);
    coin
}

/// CLI/operator entry wrapper: execute_trade and deliver the Coin to
/// `recipient`. `sui client call` can't handle execute_trade's Coin
/// return; PTB builders compose the returned Coin directly via the
/// public fun above.
entry fun execute_trade_entry<T>(
    vault: &mut Vault<T>,
    cap: &AgentCap,
    policy: &mut Policy,
    spread_bps: u64,
    amount: u64,
    target_pool: address,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let coin = execute_trade<T>(
        vault, cap, policy, spread_bps, amount, target_pool, recipient, clock, ctx,
    );
    transfer::public_transfer(coin, recipient);
}

/// Withdraw `amount` Base from the vault, swap it on `pool` via DeepBook,
/// and attest the output against DeepBook's mid_price — atomically.
///
/// `min_quote_out` is passed to DeepBook as 0; the output floor is enforced
/// instead by `receipt::attest_value_conservation` using the policy's
/// `max_slippage_bps` and `base_scalar` (operator-set, read on-chain here).
/// Scope is the pool's own object id, not a caller argument.
///
/// Requires the pool to be whitelisted (DEEP fee paid as `coin::zero<DEEP>`).
///
/// Aborts:
///   ESpreadBelowThreshold     spread_bps < MIN_SPREAD_BPS
///   EValueGuardNotConfigured  policy.base_scalar == 0
///   (policy)                  revoked / paused / expired / over-cap / out-of-scope
///   EUnderMinValue            swap output below the computed floor
public fun execute_trade_guarded<Base, Quote>(
    vault: &mut Vault<Base>,
    cap: &AgentCap,
    policy: &mut Policy,
    pool: &mut Pool<Base, Quote>,
    registry: &AdapterRegistry,
    adapter_pkg: address,
    spread_bps: u64,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(spread_bps >= MIN_SPREAD_BPS, ESpreadBelowThreshold);
    // Global governance gate: the venue adapter must be approved. Admin can
    // remove it from the registry to kill all agents' access at once.
    assert!(registry::is_approved(registry, adapter_pkg), EAdapterNotApproved);
    let slippage = policy::max_slippage_bps(policy);
    let scalar = policy::base_scalar(policy);
    assert!(scalar > 0, EValueGuardNotConfigured);

    // Scope is the actual pool object — agent can't point policy at one
    // pool and swap on another.
    let target_pool = object::id(pool).to_address();

    let (coin_in, r) = vault::withdraw_with_receipt(
        vault, cap, policy, amount, target_pool, recipient, b"SWAP", clock, ctx,
    );

    // Real DeepBook swap. min_quote_out = 0 on purpose (see doc above);
    // the adapter's policy-bound attest is the real check.
    let deep_in = coin::zero<DEEP>(ctx);
    let (base_left, coin_out, deep_left) = dbpool::swap_exact_base_for_quote<Base, Quote>(
        pool, coin_in, deep_in, 0, clock, ctx,
    );

    // Adapter closes the hot potato; reverts the whole tx if coin_out is
    // below the operator's fair-rate floor.
    deepbook_adapter::attest_value_conservation<Base, Quote>(
        r, &coin_out, pool, clock, slippage, scalar, recipient,
    );

    transfer::public_transfer(coin_out, recipient);
    transfer::public_transfer(base_left, recipient);
    transfer::public_transfer(deep_left, recipient);
}

public fun min_spread_bps(): u64 { MIN_SPREAD_BPS }
