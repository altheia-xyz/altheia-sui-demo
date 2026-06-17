/// altheia_sui_demo::transfer_bot
///
/// A second, deliberately trivial agent on the SAME altheia substrate.
///
/// Its only job: move funds to a recipient. It has no strategy, no spread
/// logic — nothing in common with spread_trader except that it imports the
/// same altheia-sui policy primitive and is bounded by it.
///
/// This is the substrate proof: two unrelated agents, one enforcement
/// primitive. Any Sui agent adds caps + scope + revocation + audit by
/// importing `altheia_sui` and routing withdrawals through the vault. No
/// bespoke enforcement code per agent — the way Solana agents inherit Swig.
module altheia_sui_demo::transfer_bot;

use sui::coin::Coin;
use sui::clock::Clock;
use altheia::vault::{Self, Vault};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia::receipt;

/// Send `amount` of T to `recipient`, bounded by the agent's policy.
/// Identical enforcement path as spread_trader — caps, scope, revocation,
/// pause, expiry all enforced by altheia::policy::check_and_consume inside
/// withdraw_with_receipt; the hot-potato receipt must be attested before
/// the PTB settles.
public fun send<T>(
    vault: &mut Vault<T>,
    cap: &AgentCap,
    policy: &mut Policy,
    amount: u64,
    target_package: address,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let (coin, r) = vault::withdraw_with_receipt(
        vault,
        cap,
        policy,
        amount,
        target_package,
        recipient,
        b"TRANSFER",
        clock,
        ctx,
    );
    receipt::attest_simple(r, recipient);
    coin
}

/// CLI/operator entry wrapper: send + deliver the Coin to `recipient`.
entry fun send_entry<T>(
    vault: &mut Vault<T>,
    cap: &AgentCap,
    policy: &mut Policy,
    amount: u64,
    target_package: address,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let coin = send<T>(vault, cap, policy, amount, target_package, recipient, clock, ctx);
    transfer::public_transfer(coin, recipient);
}
