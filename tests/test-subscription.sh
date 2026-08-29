#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMPORT="$ROOT/subscription/import.sh"
STATUS="$ROOT/subscription/status.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-subscription-test.XXXXXX")"
SERVER_PID=""
trap '[[ -z $SERVER_PID ]] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }

bash -n "$IMPORT"
bash -n "$STATUS"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$IMPORT" "$STATUS"; fi

fakebin="$TMP/bin"
mkdir -p "$fakebin"
cat >"$fakebin/mihomo" <<'EOF'
#!/bin/bash
set -euo pipefail
config=""
while (($#)); do
  if [[ $1 == -f ]]; then shift; config="$1"; fi
  shift
done
[[ -n $config && -s $config ]]
! grep -q 'INVALID' "$config"
EOF
chmod +x "$fakebin/mihomo"

data="$TMP/data/subscriptions"
common_env=(
  MIHOMO_SUBSCRIPTION_TESTING=1
  MIHOMO_SUBSCRIPTION_DATA="$data"
  MIHOMO_SUBSCRIPTION_CACHE="$TMP/cache"
  MIHOMO_SUBSCRIPTION_MIHOMO="$fakebin/mihomo"
)

run_import() {
  local source="$1"
  printf '%s\n' "$source" | env "${common_env[@]}" "$IMPORT"
}

mkdir -p "$TMP/local files"
local_file="$TMP/local files/first config.yaml"
cat >"$local_file" <<'EOF'
mode: rule
marker: local-one
proxies:
  - name: Local Node
    type: ss
    server: local-node-secret.invalid
    password: local-password-secret
EOF
first="$(run_import "$local_file")"
jq -e '.ok and .action == "added" and .kind == "local"' <<<"$first" >/dev/null
first_path="$(jq -r .path <<<"$first")"
[[ $(<"$first_path") == *local-one* ]] || fail "local file content was not copied"
assert_eq "$(stat -Lc %a "$first_path")" 600

second="$(run_import "$local_file")"
jq -e '.action == "added" and .kind == "local"' <<<"$second" >/dev/null
[[ $(jq -r .id <<<"$first") != $(jq -r .id <<<"$second") ]] || fail "local imports were unexpectedly deduplicated"

body="$TMP/proxy-body.yaml"
port_file="$TMP/proxy-port"
proxy_log="$TMP/proxy.log"
cat >"$body" <<'EOF'
mode: rule
marker: remote-one
proxies:
  - name: Remote Node One
    type: vmess
    server: remote-node-secret.invalid
    uuid: remote-uuid-secret
EOF
# shellcheck disable=SC1090
source ~/.venv/bin/activate
python - "$body" "$port_file" "$proxy_log" <<'PY' &
import http.server
import pathlib
import socketserver
import sys

body_path = pathlib.Path(sys.argv[1])
port_path = pathlib.Path(sys.argv[2])
log_path = pathlib.Path(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = body_path.read_bytes()
        with log_path.open("a", encoding="utf-8") as stream:
            stream.write(self.path + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/yaml")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    port_path.write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..100}; do [[ -s $port_file ]] && break; sleep 0.02; done
[[ -s $port_file ]] || fail "test proxy did not start"
port="$(<"$port_file")"

url='http://subscription.invalid/config?token=top-secret'
remote_one="$(printf '%s\n' "$url" | env "${common_env[@]}" \
  http_proxy="http://127.0.0.1:$port" no_proxy= NO_PROXY= "$IMPORT")"
jq -e '.action == "added" and .kind == "url" and .label == "subscription.invalid"' <<<"$remote_one" >/dev/null
url_hash="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
url_dir="$data/url-$url_hash"
assert_eq "$(<"$url_dir/source.url")" "$url"
assert_eq "$(stat -Lc %a "$url_dir")" 700
assert_eq "$(stat -Lc %a "$url_dir/source.url")" 600
assert_eq "$(stat -Lc %a "$url_dir/config.yaml")" 600
grep -Fq "$url" "$proxy_log" || fail "curl did not honor the configured HTTP proxy"

direct_data="$TMP/direct-data/subscriptions"
printf 'mode: rule\nmarker: direct-without-proxy\nproxies: []\n' >"$body"
printf '%s\n' "http://127.0.0.1:$port/direct" | env \
  -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  MIHOMO_SUBSCRIPTION_TESTING=1 \
  MIHOMO_SUBSCRIPTION_DATA="$direct_data" \
  MIHOMO_SUBSCRIPTION_CACHE="$TMP/direct-cache" \
  MIHOMO_SUBSCRIPTION_MIHOMO="$fakebin/mihomo" \
  "$IMPORT" >/dev/null
grep -Rq 'direct-without-proxy' "$direct_data" || fail "direct URL import failed without a proxy"

cat >"$body" <<'EOF'
mode: rule
marker: remote-two
proxies:
  - name: Remote Node Two
    type: trojan
    server: remote-two-secret.invalid
    password: remote-two-password-secret
EOF
remote_two="$(printf '%s\n' "$url" | env "${common_env[@]}" \
  http_proxy="http://127.0.0.1:$port" no_proxy= NO_PROXY= "$IMPORT")"
jq -e '.action == "updated" and .id == $id' --arg id "url-$url_hash" <<<"$remote_two" >/dev/null
grep -Fq 'remote-two' "$url_dir/config.yaml" || fail "duplicate URL did not update its existing entry"
[[ $(find "$data" -maxdepth 1 -type d -name 'url-*' | wc -l) == 1 ]] || fail "duplicate URL created another entry"

before_hash="$(sha256sum "$url_dir/config.yaml" | awk '{print $1}')"
printf 'INVALID\n' >"$body"
if printf '%s\n' "$url" | env "${common_env[@]}" \
    http_proxy="http://127.0.0.1:$port" no_proxy= NO_PROXY= "$IMPORT" >"$TMP/invalid.out" 2>"$TMP/invalid.err"; then
  fail "invalid remote configuration was accepted"
fi
after_hash="$(sha256sum "$url_dir/config.yaml" | awk '{print $1}')"
assert_eq "$after_hash" "$before_hash"

cat >"$body" <<'EOF'
mode: rule
marker: remote-three
proxies:
  - name: Remote Node Three
    type: hysteria2
    server: remote-three-secret.invalid
    password: remote-three-password-secret
EOF
other_url='http://subscription.invalid/other?token=different'
printf '%s\n' "$other_url" | env "${common_env[@]}" \
  http_proxy="http://127.0.0.1:$port" no_proxy= NO_PROXY= "$IMPORT" >/dev/null
[[ $(find "$data" -maxdepth 1 -type d -name 'url-*' | wc -l) == 2 ]] || fail "distinct URL was not stored separately"

status_json="$(env MIHOMO_SUBSCRIPTION_TESTING=1 MIHOMO_SUBSCRIPTION_DATA="$data" "$STATUS")"
jq -e '
  .count == 4
  and .hasSubscriptions
  and .nodeCount == 4
  and ([.subscriptions[].kind] | map(select(. == "url")) | length) == 2
  and ([.subscriptions[].nodes[].name] | index("Local Node") != null)
  and ([.subscriptions[].nodes[].name] | index("Remote Node Two") != null)
  and ([.subscriptions[].nodes[].type] | index("trojan") != null)
' <<<"$status_json" >/dev/null
if grep -Eq 'top-secret|node-secret|password-secret|uuid-secret' <<<"$status_json"; then
  fail "status output leaked subscription credentials"
fi

if command -v inotifywait >/dev/null 2>&1; then
  watched_data="$TMP/watched-plugin/data/subscriptions"
  watched_cache="$TMP/watched-cache"
  watched_events="$TMP/watched-events"
  mkdir -p "$watched_data" "$watched_cache"
  inotifywait -m -r -q -e close_write,create,delete,move --format '%w%f' \
    "$TMP/watched-plugin" >"$watched_events" &
  watcher_pid=$!
  printf '%s\n' "$local_file" | env \
    MIHOMO_SUBSCRIPTION_TESTING=1 \
    MIHOMO_SUBSCRIPTION_DATA="$watched_data" \
    MIHOMO_SUBSCRIPTION_CACHE="$watched_cache" \
    MIHOMO_SUBSCRIPTION_MIHOMO="$fakebin/mihomo" \
    "$IMPORT" >/dev/null
  for _ in {1..50}; do [[ -s $watched_events ]] && break; sleep 0.01; done
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  event_count="$(wc -l <"$watched_events")"
  (( event_count == 1 )) || fail "import exposed $event_count writes inside the watched plugin tree"
fi

large="$TMP/too-large.yaml"
printf 'mode: rule\n012345678901234567890123456789\n' >"$large"
if printf '%s\n' "$large" | env "${common_env[@]}" MIHOMO_SUBSCRIPTION_MAX_BYTES=20 \
    "$IMPORT" >"$TMP/large.out" 2>"$TMP/large.err"; then
  fail "oversized local configuration was accepted"
fi
assert_eq "$(env MIHOMO_SUBSCRIPTION_TESTING=1 MIHOMO_SUBSCRIPTION_DATA="$data" "$STATUS" | jq -r .count)" 4

echo "subscription_tests=ok local_duplicates=2 url_dedup=1 proxy_inherited=1 direct_without_proxy=1 watched_commit_events=1 atomic_failure=1"
