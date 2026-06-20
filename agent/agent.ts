/**
 * Autonomous agent for altheia sub-track 2.
 *
 * Loop: observe DeepBook mid_price -> decide on a spread threshold ->
 * sign with the AgentCap holder's key -> submit execute_trade_guarded ->
 * log. Halts when the owner revokes the policy (or admin de-approves the
 * adapter): the on-chain abort is caught and the agent stops.
 *
 * The agent enforces nothing itself — the chain does. Its ceiling, scope,
 * value-conservation, and kill-switches all live in the Move policy/registry.
 * This process only decides WHEN to act; it cannot exceed its bounds.
 *
 * Run: AGENT_PRIVKEY=suiprivkey1... CONFIG=./config.json pnpm agent
 */
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { readFileSync } from "node:fs";

type Config = {
  rpc?: string;
  demoPkg: string;       // altheia-sui-demo package id
  registry: string;      // shared AdapterRegistry id
  adapterPkg: string;    // package id approved in the registry (the demo pkg)
  vault: string;         // shared Vault<Base> id
  policy: string;        // shared Policy id
  cap: string;           // AgentCap object id (owned by the agent address)
  pool: string;          // DeepBook pool id
  baseType: string;      // e.g. 0x2::sui::SUI
  quoteType: string;     // e.g. 0x...::DBUSDC::DBUSDC
  dbPkg: string;         // DeepBook package id (for the mid_price read)
  recipient: string;     // where swap output goes
  amount: number;        // base units per fire
  spreadBps: number;     // fire when |Δ| from reference >= this
  intervalMs: number;
};

const CLOCK = "0x6";

function loadConfig(): Config {
  const path = process.env.CONFIG ?? "./config.json";
  return JSON.parse(readFileSync(path, "utf8")) as Config;
}

function loadKeypair(): Ed25519Keypair {
  const pk = process.env.AGENT_PRIVKEY;
  if (!pk) throw new Error("set AGENT_PRIVKEY (suiprivkey1... bech32)");
  const { secretKey } = decodeSuiPrivateKey(pk);
  return Ed25519Keypair.fromSecretKey(secretKey);
}

const log = (m: string) => console.log(`[${new Date().toISOString()}] ${m}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Read DeepBook mid_price on-chain (dev-inspect, no gas). */
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
  // BCS u64, little-endian
  let v = 0n;
  for (let i = ret.length - 1; i >= 0; i--) v = (v << 8n) + BigInt(ret[i]);
  return v;
}

/** Build + sign + submit the guarded trade. Returns digest or throws with the Move abort. */
async function fireTrade(c: SuiClient, cfg: Config, kp: Ed25519Keypair): Promise<string> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${cfg.demoPkg}::spread_trader::execute_trade_guarded`,
    typeArguments: [cfg.baseType, cfg.quoteType],
    arguments: [
      tx.object(cfg.vault),
      tx.object(cfg.cap),
      tx.object(cfg.policy),
      tx.object(cfg.pool),
      tx.object(cfg.registry),
      tx.pure.address(cfg.adapterPkg),
      tx.pure.u64(cfg.spreadBps),
      tx.pure.u64(cfg.amount),
      tx.pure.address(cfg.recipient),
      tx.object(CLOCK),
    ],
  });
  const res = await c.signAndExecuteTransaction({
    signer: kp,
    transaction: tx,
    options: { showEffects: true },
  });
  if (res.effects?.status.status !== "success") {
    throw new Error(res.effects?.status.error ?? "tx failed");
  }
  return res.digest;
}

/** A halting abort: owner revoked the policy or admin de-approved the adapter. */
function isHalt(err: string): boolean {
  return /EPolicyRevoked|EAdapterNotApproved|, 1\)|::registry::|::policy::/.test(err);
}

async function main() {
  const cfg = loadConfig();
  const kp = loadKeypair();
  const c = new SuiClient({ url: cfg.rpc ?? getFullnodeUrl("testnet") });
  const me = kp.getPublicKey().toSuiAddress();
  log(`agent up: ${me} | pool ${cfg.pool.slice(0, 10)} | fire>=${cfg.spreadBps}bps | amount ${cfg.amount}`);

  let reference: bigint | null = null;
  for (;;) {
    try {
      const price = await readMidPrice(c, cfg, me);
      if (reference === null) {
        reference = price;
        log(`observed mid_price=${price} (reference set)`);
      } else {
        const deltaBps = Number((price > reference ? price - reference : reference - price) * 10000n / reference);
        if (deltaBps >= cfg.spreadBps) {
          log(`observed Δ=${deltaBps}bps >= ${cfg.spreadBps} — firing trade`);
          try {
            const digest = await fireTrade(c, cfg, kp);
            log(`  ✓ settled ${digest}`);
            reference = price;
          } catch (e) {
            const msg = String((e as Error).message);
            if (isHalt(msg)) {
              log(`  ✗ HALT — guard/owner stopped the agent: ${msg}`);
              log("agent halting.");
              return;
            }
            // e.g. EUnderMinValue on a thin pool: enforcement fired, keep observing
            log(`  ✗ trade rejected by guard: ${msg}`);
          }
        } else {
          log(`observed Δ=${deltaBps}bps < ${cfg.spreadBps} — holding`);
        }
      }
    } catch (e) {
      log(`observe error: ${(e as Error).message}`);
    }
    await sleep(cfg.intervalMs);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
