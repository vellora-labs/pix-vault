#!/usr/bin/env bash
# Bateria de fork do VelloraPixVault nas 8 redes-alvo.
# OP e Base passam por anvil (bug do foundry com OP Stack pós-Isthmus:
# "Missing operator fee scalar for isthmus L1 Block"); --chain-id 1 desliga o op-revm.
set -u
cd "$(dirname "$0")"
export FOUNDRY_PROFILE=fork
LOG=${LOG_DIR:-/tmp/pix-vault-fork}
mkdir -p "$LOG"

run() { # nome rpc
  echo "===== $1"
  forge test --match-contract "Fork_$1\$" --fork-url "$2" -vv 2>&1 | tee "$LOG/$1.log" \
    | grep -E "^\[(PASS|FAIL)|Suite result:|^  \["
}

run bsc       "${BSC_RPC_URL:-https://bsc-rpc.publicnode.com}"
run bsc_uni   "${BSC_RPC_URL:-https://bsc-rpc.publicnode.com}"
run eth       "${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
run pol       "${POL_RPC_URL:-https://polygon-bor-rpc.publicnode.com}"
run arb       "${ARB_RPC_URL:-https://arbitrum-one-rpc.publicnode.com}"
run avax      "${AVAX_RPC_URL:-https://api.avax.network/ext/bc/C/rpc}"
run robinhood "${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"

# --- OP Stack via anvil ---
anvil --fork-url "${OP_RPC_URL:-https://optimism-rpc.publicnode.com}" --port 8551 --chain-id 1 --silent >/dev/null 2>&1 &
anvil --fork-url "${BASE_RPC_URL:-https://base-rpc.publicnode.com}" --port 8552 --chain-id 1 --silent >/dev/null 2>&1 &
for _ in $(seq 1 30); do
  cast block-number --rpc-url http://127.0.0.1:8551 >/dev/null 2>&1 &&
  cast block-number --rpc-url http://127.0.0.1:8552 >/dev/null 2>&1 && break
  sleep 2
done
run op   http://127.0.0.1:8551
run base http://127.0.0.1:8552
pkill -f "anvil --fork-url" 2>/dev/null
echo "logs em $LOG"
