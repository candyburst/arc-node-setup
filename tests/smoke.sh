#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'smoke test failed: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1" pattern="$2"
  grep -Eq -- "$pattern" "$file" || fail "${file} does not contain pattern: ${pattern}"
}

assert_output_contains() {
  local output="$1" pattern="$2"
  grep -Eq -- "$pattern" <<<"$output" || fail "output does not contain pattern: ${pattern}"
}

help_output="$(bash setup.sh help)"
assert_output_contains "$help_output" 'Arc Node Setup & Manager'
assert_output_contains "$help_output" 'Testnet v0\.7\.1'
assert_output_contains "$help_output" '\./setup\.sh update v0\.7\.1'
assert_output_contains "$help_output" '--version VER[[:space:]]+Arc version to install[[:space:]]+\(default: v0\.7\.1\)'
assert_output_contains "$help_output" 'https://docs\.arc\.io'
assert_file_contains README.md 'bash -s -- setup --yes'
assert_file_contains README.md 'bash -s -- setup -y'

assert_file_contains setup.sh '^ARC_VERSION_DEFAULT="v0\.7\.1"$'
assert_file_contains setup.sh '^CONSENSUS_KEY_BASENAME="priv_validator_key\.json"$'
assert_file_contains setup.sh '^EL_RPC_PORT=8545$'
assert_file_contains setup.sh '^EL_P2P_PORT=30303$'
assert_file_contains setup.sh '^CL_RPC_PORT=31000$'
assert_file_contains setup.sh '^CL_P2P_PORT=27000$'
assert_file_contains setup.sh '^MIN_DISK_GB=200$'
assert_file_contains setup.sh 'systemctl show "\$svc" --property=LoadState --value'
assert_file_contains setup.sh '--private-key \$\{ARC_CONSENSUS_DIR\}/config/\$\{CONSENSUS_KEY_BASENAME\}'
assert_file_contains setup.sh '--full[[:space:]]*\\\\'
assert_file_contains setup.sh '--p2p\.addr /ip4/0\.0\.0\.0/tcp/\$\{CL_P2P_PORT\}'
assert_file_contains setup.sh '--follow\.endpoint https://rpc\.drpc\.testnet\.arc\.network,wss=rpc\.drpc\.testnet\.arc\.network'
assert_file_contains setup.sh '--follow\.endpoint https://rpc\.blockdaemon\.testnet\.arc\.network,wss=rpc\.blockdaemon\.testnet\.arc\.network/websocket'
assert_file_contains setup.sh '--execution-persistence-backpressure[[:space:]]*\\\\'
assert_file_contains setup.sh '--execution-persistence-backpressure-threshold=50'
assert_file_contains setup.sh '^Restart=always$'
assert_file_contains setup.sh 'sudo ufw allow "\$\{EL_P2P_PORT\}/tcp"'
assert_file_contains setup.sh 'sudo ufw allow "\$\{EL_P2P_PORT\}/udp"'
assert_file_contains setup.sh 'sudo ufw allow "\$\{CL_P2P_PORT\}/tcp"'
assert_file_contains setup.sh 'printf "  %-36s\$\{CYAN\}%s\$\{NC\}\\n" "Execution peers" "\$peers"'
assert_file_contains README.md 'fresh node cannot bootstrap from genesis'

if grep -Eq 'node_key\.json|node_key_<timestamp>' setup.sh README.md; then
  fail 'stale node_key.json documentation or script reference found'
fi

if grep -Eq -- '--follow\.endpoint [^\\]*,wss?://' setup.sh; then
  fail 'follow endpoints use the old comma-plus-WebSocket-URL format'
fi

if grep -Eq 'sudo -n bash -c|auto-accepting sudo drop-in|Allow setup\.sh to write|written during setup' setup.sh README.md; then
  fail 'sudo bootstrap still claims it can self-write a sudoers drop-in'
fi

if grep -Eq 'will sync from genesis|syncs from genesis|sync from genesis \(very slow\)' setup.sh README.md; then
  fail 'snapshot skip guidance still claims a fresh genesis sync is supported'
fi

if grep -Eq 'LAN/WAN' setup.sh README.md; then
  fail 'RPC exposure guidance still says LAN/WAN'
fi

if grep -Eq '31001' setup.sh README.md CHANGELOG.md; then
  fail 'stale consensus P2P port 31001 remains'
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home"

cat > "$tmp_dir/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
  svc="${2:-}"
  prop="${3#--property=}"
  case "${svc}:${prop}" in
    arc-execution:LoadState) echo "loaded" ;;
    arc-execution:ActiveState) echo "active" ;;
    arc-consensus:LoadState) echo "loaded" ;;
    arc-consensus:ActiveState) echo "inactive" ;;
    *:LoadState) echo "not-found" ;;
    *:ActiveState) echo "inactive" ;;
  esac
  exit 0
fi
exit 1
STUB

cat > "$tmp_dir/bin/cast" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "block-number" ]]; then
  echo "12345"
elif [[ "${1:-}" == "rpc" && "${2:-}" == "net_peerCount" ]]; then
  echo '"0x2a"'
else
  exit 1
fi
STUB

chmod +x "$tmp_dir/bin/systemctl" "$tmp_dir/bin/cast"
status_output="$(PATH="$tmp_dir/bin:$PATH" HOME="$tmp_dir/home" bash setup.sh status)"
assert_output_contains "$status_output" 'arc-execution[[:space:]]+.*RUNNING'
assert_output_contains "$status_output" 'arc-consensus[[:space:]]+.*INACTIVE'
assert_output_contains "$status_output" 'Local block height[[:space:]]+12345'
assert_output_contains "$status_output" 'Execution peers[[:space:]]+42'

readme_fences="$(grep -c '^```' README.md)"
if (( readme_fences % 2 != 0 )); then
  fail "README has an odd number of fenced code markers (${readme_fences})"
fi

if awk '
  /^```bash$/ { in_bash=1; next }
  /^```$/ { in_bash=0; next }
  in_bash && /^Or equivalently:/ { found=1 }
  END { exit found ? 0 : 1 }
' README.md; then
  fail 'README Quick Start prose is inside a bash code fence'
fi

printf 'smoke tests passed\n'
