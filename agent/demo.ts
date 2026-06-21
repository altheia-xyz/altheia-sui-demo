// A minimal altheia agent: trade DeepBook under an on-chain policy.
//
// Terminal-only denials:
//   AGENT_PRIVKEY=suiprivkey... pnpm demo
// Denials ALSO logged to the Chronicle (needs operator token + the agent's name):
//   AGENT_PRIVKEY=suiprivkey... ALTHEIA_TOKEN=<operator jwt> AGENT_ID=<agent name> pnpm demo
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
  buildSwap,
  guardedSubmit,
  decodePolicyAbort,
} from "@altheia-xyz/sui";

async function main() {
  const kp = Ed25519Keypair.fromSecretKey(decodeSuiPrivateKey(process.env.AGENT_PRIVKEY!).secretKey);
  const address = kp.getPublicKey().toSuiAddress();
  const client = new SuiJsonRpcClient({ url: getJsonRpcFullnodeUrl("testnet"), network: "testnet" });

  const refs = await agentRefs(client, address);
  const exec = keypairExecutor(client, kp);
  const agent = new AltheiaSui(client, refs, exec);

  const TOKEN = process.env.ALTHEIA_TOKEN;
  const API = process.env.ALTHEIA_API ?? "https://api.altheia.xyz";
  const AGENT = process.env.AGENT_ID ?? refs.cap; // backend resolves by agent name (or cap id)
  const OK = Number(process.env.AMOUNT_OK ?? "0.25");
  const OVER = Number(process.env.AMOUNT_OVER ?? "0.4");

  // With a token: dry-run first; a policy denial is POSTed to the Chronicle and
  // not submitted (no gas), an allowed swap is submitted and the chain event
  // indexes it. Without a token: submit directly, denials print to terminal only.
  async function swap(sui: number) {
    const amt = BigInt(Math.round(sui * 1e9));
    if (TOKEN) {
      const r = await guardedSubmit(client, exec, address, buildSwap(refs, amt), {
        baseUrl: API, token: TOKEN, agent_id: AGENT, action_type: "deepbook_swap", amount: sui, asset: "SUI",
      });
      console.log(r.ok ? "  ALLOWED — " + r.digest : "  DENIED — " + (r.reason_code ?? "policy") + " (logged to Chronicle)");
    } else {
      try {
        console.log("  ALLOWED — " + (await agent.swap(amt)).digest);
      } catch (e) {
        const ab = decodePolicyAbort(e);
        console.log(ab ? "  DENIED — " + ab.message : "  failed — " + String((e as Error).message).slice(0, 80));
      }
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
