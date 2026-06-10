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
use sui::coin::Coin;
use altheia::vault::{Self, Vault};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia::receipt;

// === Constants ===

/// Minimum spread (basis points) below which a trade is rejected.
/// 5 bps = 0.05%. Stops noise fires.
const MIN_SPREAD_BPS: u64 = 5;

// === Errors ===

const ESpreadBelowThreshold: u64 = 1;

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

public fun min_spread_bps(): u64 { MIN_SPREAD_BPS }
