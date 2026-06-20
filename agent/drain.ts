/**
 * Owner kill + drain for altheia (Sui). ONE owner-signed PTB:
 *   1. revoke the policy (agent frozen)
 *   2. cancel all resting orders (owner TradeProof) — funds unlock into the BM
 *   3. withdraw_all from the BalanceManager (owner-only) per asset
 *   4. admin_withdraw_all from the Vault
 *   5. sweep every coin to the owner wallet
 *
 * Signed by the OWNER (OwnerCap + BalanceManager owner). Neither the agent nor
 * altheia can run this. Run: OWNER_PRIVKEY=suiprivkey1... CONFIG=./config.json tsx drain.ts
 */
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { readFileSync } from "node:fs";

type Config = {
  rpc?: string;
  corePkg: string;
  dbPkg: string;
  vault: string;
  ownerCap: string;          // OwnerCap object id (owned by the owner address)
  policy: string;
  pool: string;
  balanceManager?: string;   // present if the agent used order-book trading
  baseType: string;          // BM asset to drain (e.g. DEEP)
  quoteType: string;         // vault + BM asset (e.g. SUI)
  deepType: string;          // DEEP fee token (also drained from BM)
};

const CLOCK = "0x6";

function loadConfig(): Config {
  return JSON.parse(readFileSync(process.env.CONFIG ?? "./config.json", "utf8")) as Config;
}
function loadOwner(): Ed25519Keypair {
  const pk = process.env.OWNER_PRIVKEY;
  if (!pk) throw new Error("set OWNER_PRIVKEY (the wallet holding OwnerCap + BalanceManager)");
  return Ed25519Keypair.fromSecretKey(decodeSuiPrivateKey(pk).secretKey);
}

async function main() {
  const cfg = loadConfig();
  const kp = loadOwner();
  const c = new SuiClient({ url: cfg.rpc ?? getFullnodeUrl("testnet") });
  const owner = kp.getPublicKey().toSuiAddress();
  const tx = new Transaction();

  // 1. revoke — agent frozen
  tx.moveCall({
    target: `${cfg.corePkg}::vault::admin_revoke_policy`,
    typeArguments: [cfg.quoteType],
    arguments: [tx.object(cfg.vault), tx.object(cfg.ownerCap), tx.object(cfg.policy), tx.object(CLOCK)],
  });

  // 2-3. order-book leg: cancel all (owner proof) + drain the BalanceManager
  if (cfg.balanceManager) {
    const proof = tx.moveCall({
      target: `${cfg.dbPkg}::balance_manager::generate_proof_as_owner`,
      arguments: [tx.object(cfg.balanceManager)],
    });
    tx.moveCall({
      target: `${cfg.dbPkg}::pool::cancel_all_orders`,
      typeArguments: [cfg.baseType, cfg.quoteType],
      arguments: [tx.object(cfg.pool), tx.object(cfg.balanceManager), proof, tx.object(CLOCK)],
    });
    for (const t of [cfg.baseType, cfg.quoteType, cfg.deepType]) {
      const coin = tx.moveCall({
        target: `${cfg.dbPkg}::balance_manager::withdraw_all`,
        typeArguments: [t],
        arguments: [tx.object(cfg.balanceManager)],
      });
      tx.transferObjects([coin], tx.pure.address(owner));
    }
  }

  // 4-5. drain the Vault to the owner
  const vaultCoin = tx.moveCall({
    target: `${cfg.corePkg}::vault::admin_withdraw_all`,
    typeArguments: [cfg.quoteType],
    arguments: [tx.object(cfg.vault), tx.object(cfg.ownerCap)],
  });
  tx.transferObjects([vaultCoin], tx.pure.address(owner));

  const res = await c.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
  if (res.effects?.status.status !== "success") throw new Error(res.effects?.status.error ?? "drain failed");
  console.log(`kill+drain settled in one tx: ${res.digest}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
