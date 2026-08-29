#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/bootstrap/bootstrap.sh"
MIRROR_FILE="$ROOT/bootstrap/archlinuxcn-mainland-mirrors.txt"
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
mirror_count="$(awk -F '|' '$1 !~ /^#/ && NF == 2 { count++ } END { print count + 0 }' "$MIRROR_FILE")"
(( mirror_count >= 20 )) || fail "official mainland mirror snapshot is unexpectedly small"
awk -F '|' '$1 !~ /^#/ && NF == 2 && $2 !~ /^https:\/\// { bad=1 } END { exit bad }' "$MIRROR_FILE" ||
  fail "mirror snapshot contains a non-HTTPS URL"
[[ $(awk -F '|' '$1 !~ /^#/ && NF == 2 { print $1 }' "$MIRROR_FILE" | sort | uniq -d | wc -l) == 0 ]] ||
  fail "mirror snapshot contains duplicate names"

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

# Manjaro ships a different command under the rankmirrors name. The production
# target is Omarchy's pacman-contrib implementation; this fixture reproduces its
# single-URL output contract while the live target test exercises the real one.
fakebin="$TMP/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/rankmirrors" <<'EOF'
#!/bin/bash
url="${!#}"
curl -fsS --max-time 1 "$url/archlinuxcn.db" -o /dev/null || exit 1
printf '%s : 0.010\n' "$url"
EOF
chmod +x "$fakebin/rankmirrors"

common_env=(
  PATH="$fakebin:$PATH"
  MIHOMO_BOOTSTRAP_TESTING=1
  MIHOMO_BOOTSTRAP_MIRRORS="dead|http://127.0.0.1:1,local|$base"
  MIHOMO_BOOTSTRAP_CACHE="$TMP/cache"
  MIHOMO_BOOTSTRAP_STATE="$TMP/state"
  MIHOMO_BOOTSTRAP_RANK_TIMEOUT=0.3
  http_proxy=http://127.0.0.1:9
  https_proxy=http://127.0.0.1:9
)

if ! env "${common_env[@]}" "$BOOTSTRAP" plan >"$TMP/plan.out" 2>"$TMP/plan.err"; then
  cat "$TMP/plan.out" "$TMP/plan.err" >&2
  fail "mock mirror plan failed"
fi
assert_contains "$TMP/plan.out" "Primary mirror: local"
assert_contains "$TMP/plan.out" "Validated mirrors: local"
assert_contains "$TMP/plan.out" "mihomo"
assert_contains "$TMP/plan.out" "1.19.30-1"
assert_contains "$TMP/plan.out" "rankmirrors: 1/2 reachable"

# Production mode must not accept arbitrary mirror names.
if "$BOOTSTRAP" plan --mirror evil >"$TMP/evil.out" 2>"$TMP/evil.err"; then
  fail "production accepted an arbitrary mirror name"
fi
assert_contains "$TMP/evil.err" "unknown mirror: evil"

cat >"$fakebin/gum" <<'EOF'
#!/bin/bash
[[ ${1:-} == style ]] && exit 0
[[ ${1:-} == confirm ]] && exit 1
exit 1
EOF
chmod +x "$fakebin/gum"
: >"$log_file"
set +e
script -qec "env PATH=$(printf %q "$fakebin:$PATH") MIHOMO_BOOTSTRAP_TESTING=1 MIHOMO_BOOTSTRAP_MIRRORS=$(printf %q "local|$base") MIHOMO_BOOTSTRAP_RANK_TIMEOUT=0.3 MIHOMO_BOOTSTRAP_CACHE=$(printf %q "$TMP/cancel-cache") MIHOMO_BOOTSTRAP_STATE=$(printf %q "$TMP/cancel-state") $(printf %q "$BOOTSTRAP") install" /dev/null >"$TMP/cancel.out" 2>"$TMP/cancel.err"
status=$?
set -e
[[ $status == 130 ]] || fail "cancel returned $status instead of 130"
assert_contains "$TMP/cancel.out" "Installation cancelled"
if grep -Eq 'pkg\.tar\.zst' "$log_file"; then
  fail "cancel path downloaded package artifacts"
fi
[[ ! -e $TMP/cancel-state/last-success.tsv ]] || fail "cancel path wrote success state"

echo "bootstrap_tests=ok plan_failover=1 proxy_unset=1 confirmation_cancel=1"
