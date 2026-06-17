/// altheia_sui_demo::transfer_bot
///
/// A second reference agent that imports altheia_sui and is bounded by the
/// same policy as spread_trader. Its only job is to move funds to a
/// recipient; it has no strategy logic and shares no code with
/// spread_trader except the altheia withdraw-with-receipt path. The policy
/// enforcement therefore comes from the substrate, not the agent.
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
