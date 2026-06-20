/**
 * Autonomous agent for altheia (Sui). Composes Sui PTBs directly against the
 * deployed altheia core + deepbook adapter + DeepBook — the developer deploys
 * NO Move code. The agent signs with its own scoped key (AgentCap holder); the
 * on-chain Policy enforces caps, scope, value-conservation, the capability
 * allowlist, and revocation. This process only decides WHEN to act.
 *
 * Modes (argv[2]): "swap" (default, observe->decide->swap loop) | "limit" |
 * "cancel". Run: AGENT_PRIVKEY=suiprivkey1... CONFIG=./config.json pnpm agent [mode]
 */
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { readFileSync } from "node:fs";

type Config = {
  rpc?: string;
  corePkg: string;          // altheia core package id
  adapterPkg: string;       // altheia deepbook adapter package id
  dbPkg: string;            // DeepBook package id
  registry: string;         // shared AdapterRegistry id
  vault: string;            // shared Vault<Quote> id (holds the spend asset)
  policy: string;           // shared Policy id
  cap: string;              // AgentCap object id (owned by the agent address)
  pool: string;             // DeepBook pool id
  tradingAccount?: string;  // shared TradingAccount id (limit/cancel)
  balanceManager?: string;  // BalanceManager id (limit/cancel)
  baseType: string;         // e.g. DEEP
  quoteType: string;        // e.g. 0x2::sui::SUI (the vault asset)
  deepType: string;         // DeepBook DEEP token type (fee coin)
  recipient: string;        // where swap outputs go
  amount: number;           // quote base-units per swap fire
  spreadBps: number;        // fire when |Δ| from reference >= this
  intervalMs: number;
  // limit-order params (mode "limit")
  limitPrice?: number;
  limitQty?: number;
  limitIsBid?: boolean;
};

const CLOCK = "0x6";
// DeepBook order_type 0 = NO_RESTRICTION, self_matching 0 = SELF_MATCHING_ALLOWED.
const ORDER_TYPE = 0;
const SELF_MATCHING = 0;

function loadConfig(): Config {
  return JSON.parse(readFileSync(process.env.CONFIG ?? "./config.json", "utf8")) as Config;
}
function loadKeypair(): Ed25519Keypair {
  const pk = process.env.AGENT_PRIVKEY;
  if (!pk) throw new Error("set AGENT_PRIVKEY (suiprivkey1... bech32)");
  return Ed25519Keypair.fromSecretKey(decodeSuiPrivateKey(pk).secretKey);
}
const log = (m: string) => console.log(`[${new Date().toISOString()}] ${m}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const tag = (s: string) => Array.from(new TextEncoder().encode(s));

/** Read DeepBook mid_price (dev-inspect, no gas). */
async function readMidPrice(c: SuiClient, cfg: Config, sender: string): Promise<bigint> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${cfg.dbPkg}::pool::mid_price`,
    typeArguments: [cfg.baseType, cfg.quoteType],
    arguments: [tx.object(cfg.pool), tx.object(CLOCK)],
  });
  const res = await c.devInspectTransactionBlock({ sender, transactionBlock: tx });
  const ret = res.results?.[0]?.returnValues?.[0]?.[0];
  if (!ret) throw new Error("mid_price returned nothing");
  let v = 0n;
  for (let i = ret.length - 1; i >= 0; i--) v = (v << 8n) + BigInt(ret[i]);
  return v;
}

/** PTB: withdraw SUI under policy -> DeepBook quote->base swap -> adapter attest -> sweep. */
async function fireSwap(c: SuiClient, cfg: Config, kp: Ed25519Keypair): Promise<string> {
  const tx = new Transaction();
  // One gated adapter call: reads mid_price BEFORE the swap, withdraws under
  // policy, swaps on DeepBook, attests value-conservation, sweeps to recipient.
  tx.moveCall({
    target: `${cfg.adapterPkg}::deepbook_adapter::execute_swap_quote_for_base`,
    typeArguments: [cfg.baseType, cfg.quoteType],
    arguments: [
      tx.object(cfg.vault), tx.object(cfg.cap), tx.object(cfg.policy),
      tx.object(cfg.pool), tx.object(cfg.registry),
      tx.pure.u64(cfg.amount), tx.pure.address(cfg.recipient), tx.object(CLOCK),
    ],
  });
  const res = await c.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
  if (res.effects?.status.status !== "success") throw new Error(res.effects?.status.error ?? "tx failed");
  return res.digest;
}

/** PTB: agent places a resting limit order via the TradingAccount (price-band gated). */
async function placeLimit(c: SuiClient, cfg: Config, kp: Ed25519Keypair): Promise<string> {
  if (!cfg.tradingAccount || !cfg.balanceManager) throw new Error("limit mode needs tradingAccount + balanceManager");
  const tx = new Transaction();
  const expire = BigInt(Date.now() + 3600_000); // host clock for expiry arg only
  tx.moveCall({
    target: `${cfg.adapterPkg}::trading_account::place_limit_order`,
    typeArguments: [cfg.baseType, cfg.quoteType],
    arguments: [
      tx.object(cfg.tradingAccount), tx.object(cfg.cap), tx.object(cfg.policy),
      tx.object(cfg.pool), tx.object(cfg.balanceManager),
      tx.pure.u64(Date.now()), tx.pure.u8(ORDER_TYPE), tx.pure.u8(SELF_MATCHING),
      tx.pure.u64(cfg.limitPrice ?? 0), tx.pure.u64(cfg.limitQty ?? 0),
      tx.pure.bool(cfg.limitIsBid ?? true), tx.pure.bool(false), tx.pure.u64(expire),
      tx.object(CLOCK),
    ],
  });
  const res = await c.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
  if (res.effects?.status.status !== "success") throw new Error(res.effects?.status.error ?? "tx failed");
  return res.digest;
}

/** PTB: agent cancels all its resting orders via the TradingAccount. */
async function cancelAll(c: SuiClient, cfg: Config, kp: Ed25519Keypair): Promise<string> {
  if (!cfg.tradingAccount || !cfg.balanceManager) throw new Error("cancel mode needs tradingAccount + balanceManager");
  const tx = new Transaction();
  tx.moveCall({
    target: `${cfg.adapterPkg}::trading_account::cancel_all`,
    typeArguments: [cfg.baseType, cfg.quoteType],
    arguments: [
      tx.object(cfg.tradingAccount), tx.object(cfg.cap), tx.object(cfg.policy),
      tx.object(cfg.pool), tx.object(cfg.balanceManager), tx.object(CLOCK),
    ],
  });
  const res = await c.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
  if (res.effects?.status.status !== "success") throw new Error(res.effects?.status.error ?? "tx failed");
  return res.digest;
}

/** Halting abort: owner revoked the policy or admin de-approved the adapter. */
function isHalt(err: string): boolean {
  return /EPolicyRevoked|ENotApprovedAdapter|ENotAllowedAction|::registry::|::policy::/.test(err);
}

async function swapLoop(c: SuiClient, cfg: Config, kp: Ed25519Keypair, me: string) {
  log(`agent up: ${me} | pool ${cfg.pool.slice(0, 10)} | fire>=${cfg.spreadBps}bps | amount ${cfg.amount}`);
  let reference: bigint | null = null;
  for (;;) {
    try {
      const price = await readMidPrice(c, cfg, me);
      if (reference === null) { reference = price; log(`observed mid_price=${price} (reference set)`); }
      else {
        const deltaBps = Number((price > reference ? price - reference : reference - price) * 10000n / reference);
        if (deltaBps >= cfg.spreadBps) {
          log(`Δ=${deltaBps}bps >= ${cfg.spreadBps} — firing swap`);
          try { const d = await fireSwap(c, cfg, kp); log(`  ✓ settled ${d}`); reference = price; }
          catch (e) {
            const msg = String((e as Error).message);
            if (isHalt(msg)) { log(`  ✗ HALT — guard/owner stopped the agent: ${msg}`); return; }
            log(`  ✗ rejected by guard: ${msg}`);
          }
        } else log(`Δ=${deltaBps}bps < ${cfg.spreadBps} — holding`);
      }
    } catch (e) { log(`observe error: ${(e as Error).message}`); }
    await sleep(cfg.intervalMs);
  }
}

async function main() {
  const cfg = loadConfig();
  const kp = loadKeypair();
  const c = new SuiClient({ url: cfg.rpc ?? getFullnodeUrl("testnet") });
  const me = kp.getPublicKey().toSuiAddress();
  const mode = process.argv[2] ?? "swap";
  if (mode === "swap-once") { log(`one-shot swap (amount ${cfg.amount})...`); log(`  ✓ settled ${await fireSwap(c, cfg, kp)}`); return; }
  if (mode === "limit") { log(`placing limit order...`); log(`  ✓ ${await placeLimit(c, cfg, kp)}`); return; }
  if (mode === "cancel") { log(`cancelling all orders...`); log(`  ✓ ${await cancelAll(c, cfg, kp)}`); return; }
  await swapLoop(c, cfg, kp, me);
}

main().catch((e) => { console.error(e); process.exit(1); });
