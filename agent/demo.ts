// A minimal altheia agent: trade DeepBook under an on-chain policy.
// run: AGENT_PRIVKEY=suiprivkey... pnpm demo
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import {
  SuiJsonRpcClient,
  getJsonRpcFullnodeUrl,
  Ed25519Keypair,
  decodeSuiPrivateKey,
  AltheiaSui,
  keypairExecutor,
  agentRefs,
  decodePolicyAbort,
} from "@altheia-xyz/sui";

async function main() {
  const kp = Ed25519Keypair.fromSecretKey(decodeSuiPrivateKey(process.env.AGENT_PRIVKEY!).secretKey);
  const address = kp.getPublicKey().toSuiAddress();
  const client = new SuiJsonRpcClient({ url: getJsonRpcFullnodeUrl("testnet"), network: "testnet" });

  // The SDK derives the agent's vault/policy/cap from its key, then drives the
  // policy-gated swap. This is the whole integration.
  const refs = await agentRefs(client, address);
  const agent = new AltheiaSui(client, refs, keypairExecutor(client, kp));

  const OK = Number(process.env.AMOUNT_OK ?? "0.05");
  const OVER = Number(process.env.AMOUNT_OVER ?? "0.2");

  async function swap(sui: number) {
    try {
      console.log("  ALLOWED — " + (await agent.swap(BigInt(Math.round(sui * 1e9)))).digest);
    } catch (e) {
      const ab = decodePolicyAbort(e);
      console.log(ab ? "  DENIED — " + ab.message : "  failed — " + String((e as Error).message).slice(0, 80));
    }
  }

  const rl = createInterface({ input, output });
  console.log(`agent ${address.slice(0, 12)} · vault ${refs.vault.slice(0, 10)}`);

  await rl.question(`\nSTEP 1 — swap ${OK} SUI (within cap), press ENTER… `);
  await swap(OK);

  await rl.question(`\nSTEP 2 — swap ${OVER} SUI (over cap → denied), press ENTER… `);
  await swap(OVER);

  await rl.question(`\nSTEP 3 — revoke in the dashboard, then press ENTER to retry ${OK} SUI… `);
  await swap(OK);

  rl.close();
}

main().catch((e) => { console.error(e); process.exit(1); });
