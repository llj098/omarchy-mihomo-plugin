#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UFW_HELPER="$ROOT/subscription/ufw.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-ufw-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$UFW_HELPER"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$UFW_HELPER"; fi
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ufw" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/gum" <<'EOF'
#!/usr/bin/env bash
printf 'gum' >>"$UFW_TEST_LOG"
printf ' <%s>' "$@" >>"$UFW_TEST_LOG"
printf '\n' >>"$UFW_TEST_LOG"
[[ ${1:-} == style ]] && exit 0
[[ ${GUM_CONFIRM:-cancel} == confirm ]] && exit 0
exit 1
EOF
cat >"$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo' >>"$UFW_TEST_LOG"
printf ' <%s>' "$@" >>"$UFW_TEST_LOG"
printf '\n' >>"$UFW_TEST_LOG"
EOF
cat >"$TMP/bin/omarchy-launch-floating-terminal-with-presentation" <<'EOF'
#!/usr/bin/env bash
printf 'launcher' >>"$UFW_TEST_LOG"
printf ' <%s>' "$@" >>"$UFW_TEST_LOG"
printf '\n' >>"$UFW_TEST_LOG"
EOF
chmod +x "$TMP/bin/"*

common_env=(PATH="$TMP/bin:$PATH" UFW_TEST_LOG="$TMP/commands.log")

mkdir -p "$TMP/no-ufw-bin"
ln -s /bin/bash "$TMP/no-ufw-bin/bash"
cp "$TMP/bin/gum" "$TMP/bin/sudo" "$TMP/no-ufw-bin/"
: >"$TMP/commands.log"
if env PATH="$TMP/no-ufw-bin" UFW_TEST_LOG="$TMP/commands.log" \
    /bin/bash "$UFW_HELPER" review 8123 >"$TMP/missing.out" 2>"$TMP/missing.err"; then
  fail "review accepted a missing ufw command"
fi
grep -Fq 'ufw is not installed' "$TMP/missing.err" || fail "missing ufw error is unclear"
[[ ! -s $TMP/commands.log ]] || fail "missing ufw path invoked Gum or sudo"

for invalid in 1023 65536 12x 7891.0; do
  : >"$TMP/commands.log"
  if env "${common_env[@]}" "$UFW_HELPER" review "$invalid" >"$TMP/out" 2>"$TMP/err"; then
    fail "invalid port was accepted: $invalid"
  fi
  [[ ! -s $TMP/commands.log ]] || fail "invalid port invoked a command: $invalid"
done

: >"$TMP/commands.log"
set +e
env "${common_env[@]}" GUM_CONFIRM=cancel "$UFW_HELPER" review 8123 >"$TMP/cancel.out" 2>"$TMP/cancel.err"
status=$?
set -e
[[ $status == 130 ]] || fail "cancel returned $status instead of 130"
grep -Fq 'ufw allow 8123/tcp allows all UFW-accepted sources' "$TMP/commands.log" ||
  fail "Gum warning does not state the exposure"
if grep -q '^sudo' "$TMP/commands.log"; then
  fail "cancel path invoked sudo"
fi

: >"$TMP/commands.log"
env "${common_env[@]}" GUM_CONFIRM=confirm "$UFW_HELPER" review 8123 >"$TMP/confirm.out"
grep -Fxq 'sudo <ufw> <status>' "$TMP/commands.log" || fail "sudo ufw status was not constructed"
grep -Fxq 'sudo <ufw> <allow> <8123/tcp>' "$TMP/commands.log" || fail "sudo ufw allow was not constructed"
[[ $(grep -c '^sudo' "$TMP/commands.log") == 2 ]] || fail "unexpected sudo command count"

: >"$TMP/commands.log"
env "${common_env[@]}" "$UFW_HELPER" launch 8123
grep -Fq 'launcher <' "$TMP/commands.log" || fail "Omarchy floating terminal launcher was not used"
grep -Fq 'review 8123' "$TMP/commands.log" || fail "launcher command did not carry the validated port"

if grep -Eqi 'firewalld|nftables|iptables|ufw (enable|disable|delete)' "$UFW_HELPER"; then
  fail "helper contains out-of-scope firewall handling"
fi

echo "ufw_tests=ok ufw_required=1 strict_port=1 cancel_before_sudo=1 confirmed_commands=2 floating_terminal=1"
