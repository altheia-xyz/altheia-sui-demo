# altheia-sui-demo

**Two reference agents on one substrate** — proof that [altheia-sui](https://github.com/altheia-xyz/altheia-sui) is a reusable policy primitive, not a one-off app.

- `spread_trader` — a DeepBook v3 spread trader. Fires when mid-price spread exceeds a threshold.
- `transfer_bot` — a bare fund-mover. No strategy at all.

They share **zero** strategy code. They share the same enforcement: both `import altheia_sui` and route every withdrawal through the vault → policy → hot-potato-receipt path. Neither writes a line of policy logic. That is the substrate claim — the way a Solana agent inherits Swig, a Sui agent inherits this.

**Submission target:** Sui Overflow 2026, Agentic Web sub-track 2 — **2026-06-20**.

## Architecture in five objects

```
[ Vault<SUI> ]  ── shared, holds Balance<SUI>; only exit is withdraw_with_receipt
       │
       │ withdraw_with_receipt(cap, policy, amount, target_pool, recipient, clock, ctx)
       ▼
[ Policy ]      ── shared, enforces caps + scope + revoked + paused + expiry
       │           updates spent_today across PTBs (closes splitting hole)
       ▼
[ AgentCap ]    ── key-only, non-transferable, scopes the agent to (vault_id, policy_id)
       │
       │ returns: (Coin<SUI>, WithdrawalReceipt)
       ▼
[ WithdrawalReceipt ]  ── HOT POTATO. NO abilities. PTB MUST consume via
                          receipt::attest_simple() before settle, else abort.
       │
       ▼
[ OwnerCap ]    ── operator's master, mints / revokes AgentCaps, admin-pauses
```

The combination — funds in `Balance<T>` inside a no-`store` `Vault`, withdrawal gated by a hot-potato receipt — is what makes the policy **binding** rather than advisory. The agent never holds a `Coin<T>` without simultaneously holding an unconsumed receipt; the PTB cannot settle unless the receipt is closed via the attestation path. This closes the `Coin<T>.store` escape the 4-lens pressure-test surfaced on 2026-05-23.

## Six demo scenarios

All seven scenarios run via `sui move test`. Each one asserts a specific enforcement path and either settles or aborts with a known abort code.

| # | Scenario | Expected | Abort code |
|---|---|---|---|
| 1 | Spread above threshold, amount under per-tx cap, package allowed | **ALLOWED** — Coin returned, audit event emitted | — |
| 2 | Trade amount exceeds per-tx cap | DENIED | `altheia::policy::ECapExceededPerTx` (4) |
| 3 | Cumulative day spend exceeds per-day cap (5 × 100 = cap, 6th aborts) | DENIED | `altheia::policy::ECapExceededPerDay` (5) |
| 4 | Target pool not in allowed_packages | DENIED | `altheia::policy::EPackageNotAllowed` (6) |
| 5 | Operator paused the policy | DENIED | `altheia::policy::EPolicyPaused` (3) |
| 6 | Operator revoked the policy | DENIED | `altheia::policy::EPolicyRevoked` (1) |
| 7 | Strategy fires below the configured spread threshold | DENIED | `altheia_sui_demo::spread_trader::ESpreadBelowThreshold` (1) |

```bash
sui move test
# Test result: OK. Total tests: 9; passed: 9; failed: 0
```

The 7 spread_trader scenarios above + 2 transfer_bot cases (allowed under cap; over-cap denied by the **same** `ECapExceededPerTx` from the same substrate) = 9. The transfer_bot cases exist only to prove the enforcement is the substrate's, not the agent's.

## Run

```bash
# 1. clone + build (altheia-sui must be a sibling directory)
git clone https://github.com/altheia-xyz/altheia-sui
git clone https://github.com/altheia-xyz/altheia-sui-demo
cd altheia-sui-demo
sui move build && sui move test

# 2. publish to testnet (after Jun 20 public flip)
sui client publish --gas-budget 100_000_000

# 3. operator: provision vault + mint policy + mint agent cap
sui client call --package <PKG_ID> --module vault --function provision \
  --type-args 0x2::sui::SUI --gas-budget 10_000_000
# ...full operator playbook lives in altheia-sui/README.md
```

## Off-chain agent loop (skeleton)

```ts
import { Altheia } from "@altheia-xyz/sdk";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";

const altheia = new Altheia({
  chain: "sui",
  agentObjectId: process.env.AGENT_CAP_ID!,
  apiKey: process.env.ALTHEIA_API_KEY!,
});

while (true) {
  const { spreadBps, amount, pool } = await observeDeepBook();
  if (spreadBps < 5) { await sleep(5000); continue; }

  await altheia.guard(
    { type: "swap", asset: "SUI", amount, target: pool },
    async () => {
      const tx = new Transaction();
      tx.moveCall({
        target: `${PKG}::spread_trader::execute_trade`,
        typeArguments: ["0x2::sui::SUI"],
        arguments: [
          vault, cap, policy,
          tx.pure.u64(spreadBps), tx.pure.u64(amount),
          tx.pure.address(pool), tx.pure.address(RECIPIENT),
          tx.object("0x6"),
        ],
      });
      const res = await suiClient.signAndExecuteTransaction({ signer, transaction: tx });
      return res.digest;
    },
  );
}
```

## What's in this repo vs. altheia-sui

- **altheia-sui** owns the policy plane: `vault`, `policy`, `agent`, `receipt`, `audit`. The enforcement contract is there.
- **altheia-sui-demo** (this repo) owns the strategy: `spread_trader` calls into altheia-sui. Demo-specific, swappable per agent.

Same separation as the off-chain side: the SDK (`@altheia-xyz/sdk`) is the universal client; the agent is bespoke.

## Open source on Jun 20

Both repos flip from PRIVATE to PUBLIC on submission day, coordinated with the reveal post. The npm major version of `@altheia-xyz/sdk` (with `(chain, substrate)` dispatch and Sui case) ships the same day.

---

*altheia.xyz — substrate-agnostic policy plane for on-chain AI agents. Solana (Swig) + Sui (Move policy object). One SDK, one backend, one dashboard.*
