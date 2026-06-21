# altheia-sui-demo

A minimal AI agent that trades on DeepBook under an on-chain altheia policy.

The point is the integration surface: an agent author writes about five lines
against [`@altheia-xyz/sui`](https://www.npmjs.com/package/@altheia-xyz/sui). The
SDK derives the agent's vault and policy from its key and builds the
policy-gated swap. The chain enforces the caps. The agent carries no policy
logic of its own.

Contracts: https://github.com/altheia-xyz/altheia-sui

## Prerequisites

- Node 20+ and pnpm
- An agent provisioned by an operator (mint one in the altheia dashboard).
  Provisioning shows the agent's private key once. Save it.

## Setup

```bash
cd agent
pnpm install
printf 'AGENT_PRIVKEY=suiprivkey1...\n' > .env   # the key from provisioning
```

## Run

```bash
pnpm demo
```

Three steps, press ENTER between each:

1. swap 0.05 SUI, within the per-transaction cap → allowed, settled on DeepBook
2. swap 0.2 SUI, over the cap → denied on-chain (the swap reverts)
3. revoke the agent in the dashboard, then retry → halts

Amounts are overridable with `AMOUNT_OK` and `AMOUNT_OVER`, in SUI.

## The integration

The whole agent is `agent/demo.ts`:

```ts
const refs  = await agentRefs(client, address);                  // vault/policy/cap, from the key
const agent = new AltheiaSui(client, refs, keypairExecutor(client, kp));
await agent.swap(50_000_000n);                                   // gated; reverts if over cap
```

`decodePolicyAbort(err)` turns an on-chain denial into a reason:
`over_per_tx_cap`, `over_per_day_cap`, `policy_revoked`, `agent_paused`,
`policy_expired`.

## Layout

- `agent/demo.ts` — the runnable demo
- the Move modules (vault, policy, agent, DeepBook adapter) live in
  [altheia-sui](https://github.com/altheia-xyz/altheia-sui)

---

altheia — a non-custodial control plane for on-chain AI agents. Sui-native; also on Solana.
