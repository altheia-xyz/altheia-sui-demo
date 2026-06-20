/**
 * Probe DEEP_SUI (base=DEEP, quote=SUI): can we BUY DEEP with the SUI we
 * already hold (swap_exact_quote_for_base), and is it whitelisted (so
 * coin::zero<DEEP> fee path works)? get_base_quantity_out(pool, quote_qty, clock)
 * -> (base_out, quote_out, deep_req).
 */
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

const DBPKG = "0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c";
const DEEP_SUI = "0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f";
const DEEP = "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP";
const SUI = "0x2::sui::SUI";
const CLOCK = "0x6";
const SENDER = "0x57400cf44ad97dac479671bb58b96d444e87972f09a6e17fa9650a2c60fbc054";
const c = new SuiClient({ url: getFullnodeUrl("testnet") });

const u64 = (b: number[]) => { let v = 0n; for (let i = b.length - 1; i >= 0; i--) v = (v << 8n) + BigInt(b[i]); return v; };

async function call(fn: string, args: (tx: Transaction) => any[]) {
  const tx = new Transaction();
  tx.moveCall({ target: `${DBPKG}::pool::${fn}`, typeArguments: [DEEP, SUI], arguments: args(tx) });
  const res = await c.devInspectTransactionBlock({ sender: SENDER, transactionBlock: tx });
  if (res.error) throw new Error(`${fn}: ${res.error}`);
  return res.results?.[0]?.returnValues ?? [];
}

async function main() {
  const wl = await call("whitelisted", (tx) => [tx.object(DEEP_SUI)]);
  console.log(`DEEP_SUI whitelisted: ${wl[0]?.[0]?.[0] === 1}`);
  const mp = await call("mid_price", (tx) => [tx.object(DEEP_SUI), tx.object(CLOCK)]);
  console.log(`DEEP_SUI mid_price: ${u64(mp[0]?.[0] ?? [])}`);
  // spend SUI (quote) -> DEEP (base)
  for (const amt of [50_000_000n, 500_000_000n]) {
    const q = await call("get_base_quantity_out", (tx) => [tx.object(DEEP_SUI), tx.pure.u64(amt), tx.object(CLOCK)]);
    console.log(`get_base_out for ${amt} SUI-in: base_out(DEEP)=${u64(q[0]?.[0] ?? [])} quote_out(SUI)=${u64(q[1]?.[0] ?? [])} deep_req=${u64(q[2]?.[0] ?? [])}`);
  }
}
main().catch((e) => { console.error("PROBE ERROR:", e.message); process.exit(1); });
