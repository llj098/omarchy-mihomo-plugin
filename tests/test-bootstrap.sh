#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/bootstrap/bootstrap.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-bootstrap-test.XXXXXX")"
SERVER_PID=""

cleanup() {
  [[ -z $SERVER_PID ]] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }

bash -n "$BOOTSTRAP"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$BOOTSTRAP"; fi

repo="$TMP/repo"
mkdir -p "$repo/db"
make_desc() {
  local package="$1" version="$2" filename="$3" sha="$4" dir
  dir="$repo/db/$package-$version"
  mkdir -p "$dir"
  cat >"$dir/desc" <<EOF
%NAME%
$package

%VERSION%
$version

%FILENAME%
$filename

%SHA256SUM%
$sha
EOF
}
make_desc archlinuxcn-keyring 20260505-1 archlinuxcn-keyring-20260505-1-any.pkg.tar.zst "$(printf a%.0s {1..64})"
make_desc clash-geoip 202606182327-1 clash-geoip-202606182327-1-any.pkg.tar.zst "$(printf b%.0s {1..64})"
make_desc mihomo 1.19.30-1 mihomo-1.19.30-1-x86_64.pkg.tar.zst "$(printf c%.0s {1..64})"
bsdtar -czf "$repo/archlinuxcn.db" -C "$repo/db" .

port_file="$TMP/port"
log_file="$TMP/http.log"
# shellcheck source=/dev/null
source ~/.venv/bin/activate
python - "$repo" "$port_file" "$log_file" <<'PY' &
import http.server, pathlib, socketserver, sys
root, port_file, log_file = map(pathlib.Path, sys.argv[1:])
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(root), **kwargs)
    def log_message(self, fmt, *args):
        with log_file.open("a") as f: f.write((fmt % args) + "\n")
class Server(socketserver.TCPServer): allow_reuse_address = True
with Server(("127.0.0.1", 0), Handler) as server:
    port_file.write_text(str(server.server_address[1]))
    server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..100}; do [[ -s $port_file ]] && break; sleep 0.02; done
[[ -s $port_file ]] || fail "mock mirror did not start"
port="$(cat "$port_file")"
base="http://127.0.0.1:$port"

common_env=(
  MIHOMO_BOOTSTRAP_TESTING=1
  MIHOMO_BOOTSTRAP_MIRRORS="dead|http://127.0.0.1:1,local|$base"
  MIHOMO_BOOTSTRAP_CACHE="$TMP/cache"
  MIHOMO_BOOTSTRAP_STATE="$TMP/state"
  http_proxy=http://127.0.0.1:9
  https_proxy=http://127.0.0.1:9
)

env "${common_env[@]}" "$BOOTSTRAP" plan >"$TMP/plan.out" 2>"$TMP/plan.err"
assert_contains "$TMP/plan.out" "China mirror: local"
assert_contains "$TMP/plan.out" "mihomo"
assert_contains "$TMP/plan.out" "1.19.30-1"
assert_contains "$TMP/plan.err" "mirror probe failed: dead"

# Production mode must not accept arbitrary mirror names.
if "$BOOTSTRAP" plan --mirror evil >"$TMP/evil.out" 2>"$TMP/evil.err"; then
  fail "production accepted an arbitrary mirror name"
fi
assert_contains "$TMP/evil.err" "unknown mirror: evil"

fakebin="$TMP/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/gum" <<'EOF'
#!/bin/bash
[[ ${1:-} == style ]] && exit 0
[[ ${1:-} == confirm ]] && exit 1
exit 1
EOF
chmod +x "$fakebin/gum"
: >"$log_file"
set +e
script -qec "env PATH=$(printf %q "$fakebin:$PATH") MIHOMO_BOOTSTRAP_TESTING=1 MIHOMO_BOOTSTRAP_MIRRORS=$(printf %q "local|$base") MIHOMO_BOOTSTRAP_CACHE=$(printf %q "$TMP/cancel-cache") MIHOMO_BOOTSTRAP_STATE=$(printf %q "$TMP/cancel-state") $(printf %q "$BOOTSTRAP") install" /dev/null >"$TMP/cancel.out" 2>"$TMP/cancel.err"
status=$?
set -e
[[ $status == 130 ]] || fail "cancel returned $status instead of 130"
assert_contains "$TMP/cancel.out" "Installation cancelled"
if grep -Eq 'pkg\.tar\.zst' "$log_file"; then
  fail "cancel path downloaded package artifacts"
fi
[[ ! -e $TMP/cancel-state/last-success.tsv ]] || fail "cancel path wrote success state"

echo "bootstrap_tests=ok plan_failover=1 proxy_unset=1 confirmation_cancel=1"
