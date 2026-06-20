/// altheia_sui_demo::deepbook_adapter
///
/// Venue adapter for DeepBook v3. Reads the pool mid_price on-chain and the
/// actual received coin, computes the fair-rate floor, and closes the core
/// hot-potato receipt via `altheia::receipt::consume_with_check`.
///
/// Core (`altheia::receipt`) is venue-agnostic. A future perps/lending
/// adapter is a sibling module with the same shape: compute (actual, min)
/// from its own on-chain state, then call `consume_with_check`.
module altheia_sui_demo::deepbook_adapter;

use sui::coin::{Self, Coin};
use sui::clock::Clock;
use deepbook::pool::{Self, Pool};
use altheia::receipt::{Self, WithdrawalReceipt};

const BPS_DENOM: u64 = 10_000;

/// Pure: minimum acceptable output (quote base-units) for `amount_in` base
/// base-units swapped at DeepBook `mid_price`, allowing `max_slippage_bps`.
///   expected = amount_in * mid_price / base_scalar
///   floor    = expected * (10_000 - max_slippage_bps) / 10_000
/// mid_price convention (testnet-verified 2026-06-17): quote base-units per
/// 1 whole base coin; base_scalar = base coin's smallest-unit scalar.
public fun compute_min_out(
    amount_in: u64,
    mid_price: u64,
    base_scalar: u64,
    max_slippage_bps: u64,
): u64 {
    let expected = (amount_in as u128) * (mid_price as u128) / (base_scalar as u128);
    let floor = expected * ((BPS_DENOM - max_slippage_bps) as u128) / (BPS_DENOM as u128);
    floor as u64
}

/// Close the receipt by checking the swap output against DeepBook's price.
/// Reads `mid_price` from `pool` and `coin::value(coin_out)`; the agent
/// cannot forge either. `max_slippage_bps` + `base_scalar` are operator-set
/// (sourced from the Policy by the caller).
///
/// Aborts: ERecipientMismatch / EUnderMinValue (from core consume_with_check).
public fun attest_value_conservation<Base, Quote>(
    r: WithdrawalReceipt,
    coin_out: &Coin<Quote>,
    pool: &Pool<Base, Quote>,
    clock: &Clock,
    max_slippage_bps: u64,
    base_scalar: u64,
    recipient_actual: address,
) {
    let price = pool::mid_price(pool, clock);
    let min_out = compute_min_out(receipt::amount_in(&r), price, base_scalar, max_slippage_bps);
    let actual = coin::value(coin_out);
    receipt::consume_with_check(r, actual, min_out, recipient_actual);
}
