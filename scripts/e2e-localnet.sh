#!/usr/bin/env bash
# Full on-chain e2e against a local Sui network. Publishes the altheia-sui
# substrate, links + publishes this demo against it, then drives:
#   provision -> deposit -> mint policy -> mint agent cap ->
#   ALLOWED trade settles -> over-cap ABORTS -> revoke -> ABORTS.
#
# Prereq: a local node is running with a faucet, e.g.
#   RUST_LOG="off,sui_node=info" sui start --with-faucet --force-regenesis
#
# Uses the entry wrappers (provision_vault / execute_trade_entry), so every
# step is a plain `sui client call` — no PTB gymnastics.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "$HERE/.." && pwd)"
SUI_DIR="$(cd "$DEMO_DIR/../altheia-sui" && pwd)"
TOML="$SUI_DIR/Move.toml"
ME=$(sui client active-address)
CLOCK="0x6"; GAS=200000000; TYPE="0x2::sui::SUI"; J=$(mktemp -d)
py() { python3 -c "$1"; }
bar() { printf "\n\033[1m── %s ──\033[0m\n" "$1"; }
created() { py "import json;d=json.load(open('$1'));print(next(c['objectId'] for c in d['objectChanges'] if c['type']=='created' and '$2' in c.get('objectType','')))"; }

# Restore Move.toml to 0x0 on exit so git stays clean.
restore_toml() { sed -i.bak 's/^published-at = .*/# published-at set dynamically by e2e-localnet.sh/; s/^altheia = "0x[0-9a-f]*"/altheia = "0x0"/' "$TOML" 2>/dev/null; rm -f "$TOML.bak"; }
trap restore_toml EXIT

bar "0. faucet"
sui client faucet --url http://127.0.0.1:9123/gas >/dev/null 2>&1; sleep 3
echo "active: $ME"

bar "1. publish altheia-sui (substrate)"
( cd "$SUI_DIR" && sui client publish --gas-budget $GAS --json ) > $J/pub-sui.json 2>$J/e || { echo FAIL; tail -15 $J/e; exit 1; }
SUI_PKG=$(py "import json;d=json.load(open('$J/pub-sui.json'));print(next(c['packageId'] for c in d['objectChanges'] if c['type']=='published'))")
echo "substrate=$SUI_PKG"

bar "2. wire published-at + publish demo (links the published substrate)"
sed -i.bak "s|^# published-at.*|published-at = \"$SUI_PKG\"|; s|^published-at = .*|published-at = \"$SUI_PKG\"|; s|^altheia = \"0x[0-9a-f]*\"|altheia = \"$SUI_PKG\"|" "$TOML"; rm -f "$TOML.bak"
( cd "$DEMO_DIR" && sui client publish --gas-budget $GAS --json ) > $J/pub-demo.json 2>$J/e || { echo FAIL; tail -20 $J/e; exit 1; }
DEMO_PKG=$(py "import json;d=json.load(open('$J/pub-demo.json'));print(next(c['packageId'] for c in d['objectChanges'] if c['type']=='published'))")
echo "demo=$DEMO_PKG"

bar "3. provision vault (entry — plain call, no ptb)"
sui client call --package "$SUI_PKG" --module vault --function provision_vault \
  --type-args "$TYPE" --gas-budget $GAS --json > $J/prov.json 2>$J/e || { echo FAIL; tail -15 $J/e; exit 1; }
VAULT=$(created $J/prov.json 'vault::Vault'); OWNER=$(created $J/prov.json 'vault::OwnerCap')
echo "vault=$VAULT owner=$OWNER"

bar "4. deposit 200 SUI"
DEPCOIN=$(sui client gas --json | py "import json,sys;d=json.load(sys.stdin);print(d[1]['gasCoinId'])")
sui client call --package "$SUI_PKG" --module vault --function deposit --type-args "$TYPE" \
  --args "$VAULT" "$DEPCOIN" --gas-budget $GAS --json > $J/dep.json 2>$J/e || { echo FAIL; tail -15 $J/e; exit 1; }
echo "deposited"

bar "5. mint policy (per_tx=100 per_day=500 allowed=[demo])"
sui client call --package "$SUI_PKG" --module vault --function mint_policy --type-args "$TYPE" \
  --args "$VAULT" "$OWNER" "[97,103,101,110,116,49]" 100 500 "[$DEMO_PKG]" 9999999999999 "$CLOCK" \
  --gas-budget $GAS --json > $J/pol.json 2>$J/e || { echo FAIL; tail -20 $J/e; exit 1; }
POLICY=$(created $J/pol.json 'policy::Policy'); echo "policy=$POLICY"

bar "6. mint agent cap -> self"
sui client call --package "$SUI_PKG" --module vault --function mint_agent_cap --type-args "$TYPE" \
  --args "$VAULT" "$OWNER" "$POLICY" "[97,103,101,110,116,49]" "$ME" \
  --gas-budget $GAS --json > $J/cap.json 2>$J/e || { echo FAIL; tail -20 $J/e; exit 1; }
CAP=$(created $J/cap.json 'agent::AgentCap'); echo "cap=$CAP"

bar "7. ALLOWED trade (spread=10 amount=50)  -> expect SUCCESS + events"
sui client call --package "$DEMO_PKG" --module spread_trader --function execute_trade_entry --type-args "$TYPE" \
  --args "$VAULT" "$CAP" "$POLICY" 10 50 "$DEMO_PKG" "$ME" "$CLOCK" \
  --gas-budget $GAS --json > $J/t1.json 2>$J/e
if [ $? -eq 0 ]; then
  EVS=$(py "import json;d=json.load(open('$J/t1.json'));print(','.join(e['type'].split('::')[-1] for e in d.get('events',[])))")
  echo "✓ settled — events: $EVS"
else echo "✗ UNEXPECTED FAIL"; tail -10 $J/e; fi

bar "8. OVER-CAP trade (amount=101 > 100)  -> expect ABORT code 4"
sui client call --package "$DEMO_PKG" --module spread_trader --function execute_trade_entry --type-args "$TYPE" \
  --args "$VAULT" "$CAP" "$POLICY" 10 101 "$DEMO_PKG" "$ME" "$CLOCK" \
  --gas-budget $GAS > $J/t2.out 2>&1
if grep -q "with code 4" $J/t2.out; then echo "✓ aborted: $(grep -o 'function.*code 4' $J/t2.out | head -1)"; else echo "✗ did NOT abort code 4"; tail -5 $J/t2.out; fi

bar "9. REVOKE policy"
sui client call --package "$SUI_PKG" --module vault --function admin_revoke_policy --type-args "$TYPE" \
  --args "$VAULT" "$OWNER" "$POLICY" "$CLOCK" --gas-budget $GAS >/dev/null 2>&1 && echo "✓ revoked"

bar "10. trade after revoke (amount=50)  -> expect ABORT code 1 (kill switch)"
sui client call --package "$DEMO_PKG" --module spread_trader --function execute_trade_entry --type-args "$TYPE" \
  --args "$VAULT" "$CAP" "$POLICY" 10 50 "$DEMO_PKG" "$ME" "$CLOCK" \
  --gas-budget $GAS > $J/t3.out 2>&1
if grep -q "with code 1" $J/t3.out; then echo "✓ aborted: $(grep -o 'function.*code 1' $J/t3.out | head -1) — kill switch works"; else echo "✗ kill switch did NOT fire"; tail -5 $J/t3.out; fi

bar "RESULT"
echo "substrate=$SUI_PKG"
echo "demo=$DEMO_PKG"
echo "vault=$VAULT policy=$POLICY cap=$CAP"
echo "(Move.toml restored to 0x0 on exit)"
