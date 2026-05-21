# altheia-sui-demo

Demo agent for the `(sui, move-policy-object)` substrate under altheia's chain-agnostic + substrate-agnostic policy plane.

The agent is a **spread trader on DeepBook v3** — fires when the mid-price spread exceeds a configured bps threshold. Every action passes through altheia's Move policy enforcement before signing.

**Status:** active build, demo target Sui Overflow 2026 — **2026-06-20**. This repo flips from private to public on submission day.

## What it does

Off-chain agent loop:
1. Poll DeepBook v3 mid-price for two configured pools
2. Compute spread (bps)
3. If spread > threshold → build tx → sign with session key → submit

On-chain:
- `altheia_sui_demo::spread_trader::execute_spread_trade(...)` is the entry function
- Routes through `altheia::agent::AgentCap::consume(...)` from [altheia-sui](https://github.com/altheia-xyz/altheia-sui) for per-tx-cap + per-day-cap + program-scope + revocation enforcement
- Audit event emitted on every allowed or denied action

## Six demo scenarios (target Jun 16)

| # | Scenario | Expected result |
|---|---|---|
| 1 | Spread exceeds threshold + trade under per-tx-cap | Allowed, DeepBook order placed, audit event emitted |
| 2 | Trade amount over per-tx-cap | Denied, abort code from `altheia::policy::ECapExceeded`, denial audit event |
| 3 | Cumulative day-spend over per-day-cap | Denied, day-cap exceeded |
| 4 | Pool not in allowed_packages | Denied, package not allowed |
| 5 | Operator pauses the agent capability | Denied, paused |
| 6 | Operator revokes the agent capability | Denied, revoked; next attempt also denied |

## Build

```bash
sui move build
```

(Once altheia_sui local dep is wired post-week-1.)

## Roadmap

| Date | Milestone |
|---|---|
| Jun 5-6 | `spread_trader.move` body implemented + integrated against altheia-sui modules |
| Jun 7-8 | Off-chain agent loop (language TBD — likely TypeScript or Rust) signing testnet txs |
| Jun 9-10 | First end-to-end testnet run, observable allowed-then-denied transition |
| Jun 11 | 2+ hour unattended autonomous run logged |
| Jun 12-13 | Six scenarios scripted as one-command reproductions |
| Jun 14-15 | 90-second demo video |
| Jun 20 | Submission; repo flips public |

See [SHIP_PLAN_2026_05_22.md](https://github.com/altheia-xyz/altheia-plan/blob/main/01_PHASES/sui/SHIP_PLAN_2026_05_22.md) for the full week-by-week.

## Substrate-adapter contract

This demo exercises the `(sui, move-policy-object)` adapter end-to-end. Full contract spec: [altheia-plan / 02_SRS / substrate-adapter / CONTRACT.md](https://github.com/altheia-xyz/altheia-plan/blob/main/02_SRS/substrate-adapter/CONTRACT.md).

## License

Apache 2.0 (LICENSE pending — added before public-flip on Jun 20).
