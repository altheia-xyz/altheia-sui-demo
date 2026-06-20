/**
 * One-shot read-only probe (dev-inspect, no gas): is the SUI/DBUSDC testnet
 * pool whitelisted, what's mid_price, and what does get_quote_quantity_out
 * return for a small base-in? Settles whether the swap revert is a DEEP-fee
 * issue (non-whitelisted + coin::zero<DEEP>) vs thin book.
 *
 * Run: tsx probe.ts
 */
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

const DBPKG = "0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c";
const POOL = "0x1c19362ca52b8ffd7a33cee805a67d40f31e6ba303753fd3a4cfdfacea7163a5";
const SUI = "0x2::sui::SUI";
const DBUSDC = "0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7::DBUSDC::DBUSDC";
const CLOCK = "0x6";
const SENDER = "0x57400cf44ad97dac479671bb58b96d444e87972f09a6e17fa9650a2c60fbc054";

const c = new SuiClient({ url: getFullnodeUrl("testnet") });

function u64(bytes: number[]): bigint {
  let v = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) v = (v << 8n) + BigInt(bytes[i]);
  return v;
}

async function call(fn: string, args: (tx: Transaction) => any[], types = [SUI, DBUSDC]) {
  const tx = new Transaction();
  tx.moveCall({ target: `${DBPKG}::pool::${fn}`, typeArguments: types, arguments: args(tx) });
  const res = await c.devInspectTransactionBlock({ sender: SENDER, transactionBlock: tx });
  if (res.error) throw new Error(`${fn}: ${res.error}`);
  return res.results?.[0]?.returnValues ?? [];
}

async function main() {
  // whitelisted(pool) -> bool
  const wl = await call("whitelisted", (tx) => [tx.object(POOL)]);
  const isWl = wl[0]?.[0]?.[0] === 1;
  console.log(`whitelisted: ${isWl}  (raw ${JSON.stringify(wl[0]?.[0])})`);

  // mid_price(pool, clock) -> u64
  const mp = await call("mid_price", (tx) => [tx.object(POOL), tx.object(CLOCK)]);
  console.log(`mid_price: ${u64(mp[0]?.[0] ?? [])}`);

  // get_quote_quantity_out(pool, base_qty, clock) -> (base_out, quote_out, deep_req)
  for (const amt of [50_000_000n, 5_000_000n]) {
    const q = await call("get_quote_quantity_out", (tx) => [
      tx.object(POOL), tx.pure.u64(amt), tx.object(CLOCK),
    ]);
    const base_out = u64(q[0]?.[0] ?? []);
    const quote_out = u64(q[1]?.[0] ?? []);
    const deep_req = u64(q[2]?.[0] ?? []);
    console.log(`get_quote for ${amt} SUI base-units: base_out=${base_out} quote_out=${quote_out} deep_req=${deep_req}`);
  }
}

main().catch((e) => { console.error("PROBE ERROR:", e.message); process.exit(1); });
