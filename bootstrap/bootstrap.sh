#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KEY_DIR="$SCRIPT_DIR/keys"
MIRROR_FILE="$SCRIPT_DIR/archlinuxcn-mainland-mirrors.txt"
CACHE_DIR="${MIHOMO_BOOTSTRAP_CACHE:-$HOME/.cache/fatlj-mihomo-bootstrap}"
STATE_DIR="${MIHOMO_BOOTSTRAP_STATE:-$HOME/.local/state/fatlj-mihomo-bootstrap}"
LOCK_FILE="$CACHE_DIR/bootstrap.lock"
STAGE=""
ASSUME_YES=0
DOWNLOAD_ONLY=0
MIRROR_CHOICE="auto"

readonly KEYRING_FPR="B5971F2C5C10A9A08C60030F786C63F330D7CB92"
readonly MIHOMO_FPR="83F817213361BF5F02E7E124F9F9FA97A403F63E"
readonly GEOIP_FPR="4BC60A2229D26D9C6443F2444AA2154BF1B0FD96"

# These are version floors, not forced versions. Newer correctly signed packages
# are accepted; older mirror contents are rejected.
declare -Ar VERSION_FLOOR=(
  [archlinuxcn-keyring]="20260505-1"
  [clash-geoip]="202606182327-1"
  [mihomo]="1.19.30-1"
)
declare -Ar EXPECTED_SIGNER=(
  [archlinuxcn-keyring]="$KEYRING_FPR"
  [clash-geoip]="$GEOIP_FPR"
  [mihomo]="$MIHOMO_FPR"
)
readonly PACKAGES=(archlinuxcn-keyring clash-geoip mihomo)

# rankmirrors downloads each repository database to measure real opening speed.
# Run every mainland mirror concurrently, so the 10-second per-mirror timeout is
# also approximately the upper bound for the complete ranking pass.
RANK_TIMEOUT=10
RANK_VALIDATE_TOP=10
MIRRORS=()
if [[ ${MIHOMO_BOOTSTRAP_TESTING:-0} == 1 && -n ${MIHOMO_BOOTSTRAP_MIRRORS:-} ]]; then
  IFS=',' read -r -a MIRRORS <<<"$MIHOMO_BOOTSTRAP_MIRRORS"
  RANK_TIMEOUT="${MIHOMO_BOOTSTRAP_RANK_TIMEOUT:-1}"
else
  [[ -s $MIRROR_FILE ]] || { echo "missing mirror list: $MIRROR_FILE" >&2; exit 1; }
  while IFS='|' read -r name base; do
    [[ -n $name && $name != \#* && -n $base ]] || continue
    base="${base//\$arch/x86_64}"
    MIRRORS+=("$name|$base")
  done <"$MIRROR_FILE"
fi

declare -A VERSION FILENAME SHA256 INSTALLED NEED_INSTALL
declare -a VALID_MIRRORS VALID_MIRROR_NAMES
SELECTED_NAME=""

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  [[ -z $STAGE || ! -d $STAGE ]] || rm -rf -- "$STAGE"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  bootstrap.sh launch [install options]   Open an Omarchy-style terminal popup
  bootstrap.sh plan [--mirror auto|name]
  bootstrap.sh install [--yes] [--download-only] [--mirror auto|name]
  bootstrap.sh verify

The bootstrap ranks the bundled official mainland ArchLinuxCN mirror list,
keeps three validated download sources, verifies package signatures, and
installs mihomo plus clash-geoip. It does not configure subscriptions, start a
service, or modify pacman mirrors.
EOF
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

preflight() {
  [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported"
  [[ -r /etc/os-release ]] || die "cannot identify the operating system"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == omarchy || ${ID_LIKE:-} == *arch* || ${ID:-} == arch ]] ||
    die "this bootstrap supports Omarchy/Arch only (found ${ID:-unknown})"

  for cmd in bash curl gpg bsdtar sha256sum pacman vercmp flock awk rankmirrors; do
    need_command "$cmd"
  done
  mkdir -p "$CACHE_DIR/packages" "$STATE_DIR"
  chmod 0700 "$CACHE_DIR" "$STATE_DIR" 2>/dev/null || true
}

fetch() {
  local url="$1" output="$2" timeout="${3:-120}"
  local proto="=https"
  [[ ${MIHOMO_BOOTSTRAP_TESTING:-0} == 1 ]] && proto="=http,https"

  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
      -u all_proxy -u ALL_PROXY \
    curl --noproxy '*' --fail --silent --show-error \
      --proto "$proto" --proto-redir "$proto" \
      --connect-timeout 4 --max-time "$timeout" \
      --retry 3 --retry-delay 1 --retry-connrefused \
      "$url" -o "$output"
}

field_from_desc() {
  local field="$1"
  awk -v marker="%${field}%" '
    $0 == marker { if (getline > 0) print; exit }
  '
}

resolve_from_tree() {
  local tree="$1" package="$2" desc_file desc name version filename sha
  # A prefix glob narrows the candidates before reading metadata. The NAME
  # field rejects similarly prefixed packages such as mihomo-debug.
  for desc_file in "$tree"/"$package"-*/desc; do
    [[ -f $desc_file ]] || continue
    desc="$(<"$desc_file")"
    name="$(field_from_desc NAME <<<"$desc")"
    [[ $name == "$package" ]] || continue
    version="$(field_from_desc VERSION <<<"$desc")"
    filename="$(field_from_desc FILENAME <<<"$desc")"
    sha="$(field_from_desc SHA256SUM <<<"$desc")"
    [[ -n $version && -n $filename && $sha =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s\t%s\t%s\n' "$version" "$filename" "${sha,,}"
    return 0
  done
  return 1
}

rank_mirror() {
  local spec="$1" result="$2" name base output seconds milliseconds
  name="${spec%%|*}"
  base="${spec#*|}"
  output="$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
      -u all_proxy -u ALL_PROXY LC_ALL=C \
      rankmirrors -r archlinuxcn -m "$RANK_TIMEOUT" -u "$base" 2>/dev/null)" || return 1
  seconds="${output##* : }"
  [[ $seconds =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  milliseconds="$(awk -v value="$seconds" 'BEGIN { printf "%.0f", value * 1000 }')"
  printf '%s\t%s\t%s\n' "$milliseconds" "$name" "$base" >"$result"
}

probe_mirror() {
  local spec="$1" result="$2" elapsed="$3" name base db tree package row
  name="${spec%%|*}"
  base="${spec#*|}"
  db="$STAGE/$name.db"
  tree="$STAGE/$name-db"
  fetch "$base/archlinuxcn.db" "$db" 30 || return 1
  mkdir -p "$tree"
  bsdtar -xf "$db" -C "$tree" 2>/dev/null || return 1
  : >"$result"
  for package in "${PACKAGES[@]}"; do
    row="$(resolve_from_tree "$tree" "$package")" || return 1
    printf '%s\t%s\n' "$package" "$row" >>"$result"
  done
  printf '@mirror\t%s\t%s\t%s\n' "$name" "$base" "$elapsed" >>"$result"
}

candidate_field() {
  local file="$1" package="$2" column="$3"
  awk -F '\t' -v p="$package" -v c="$column" '$1 == p { print $c; exit }' "$file"
}

candidate_mirror_field() {
  local file="$1" column="$2"
  awk -F '\t' -v c="$column" '$1 == "@mirror" { print $c; exit }' "$file"
}

candidate_is_better() {
  local candidate="$1" best="$2" cv bv cmp
  [[ -z $best ]] && return 0
  cv="$(candidate_field "$candidate" mihomo 2)"
  bv="$(candidate_field "$best" mihomo 2)"
  cmp="$(vercmp "$cv" "$bv")"
  (( cmp > 0 )) && return 0
  (( cmp < 0 )) && return 1
  cv="$(candidate_field "$candidate" clash-geoip 2)"
  bv="$(candidate_field "$best" clash-geoip 2)"
  cmp="$(vercmp "$cv" "$bv")"
  (( cmp > 0 )) && return 0
  (( cmp < 0 )) && return 1
  (( $(candidate_mirror_field "$candidate" 4) < $(candidate_mirror_field "$best" 4) ))
}

candidate_matches() {
  local candidate="$1" reference="$2" package field
  for package in "${PACKAGES[@]}"; do
    for field in 2 3 4; do
      [[ $(candidate_field "$candidate" "$package" "$field") == \
         $(candidate_field "$reference" "$package" "$field") ]] || return 1
    done
  done
}

mirror_known() {
  local wanted="$1" spec
  [[ $wanted == auto ]] && return 0
  for spec in "${MIRRORS[@]}"; do
    [[ ${spec%%|*} == "$wanted" ]] && return 0
  done
  return 1
}

resolve_plan() {
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-bootstrap.XXXXXX")"
  local spec name result pid best="" package version floor ranked rank_count
  local milliseconds base selected_result="" compatible
  local -a pids=() rank_files=() results=() valid_results=()

  log "Ranking mainland ArchLinuxCN mirrors (${RANK_TIMEOUT}s timeout)"
  for spec in "${MIRRORS[@]}"; do
    name="${spec%%|*}"
    [[ $MIRROR_CHOICE == auto || $MIRROR_CHOICE == "$name" ]] || continue
    result="$STAGE/$name.rank"
    rank_files+=("$result")
    (rank_mirror "$spec" "$result") &
    pids+=("$!")
  done
  ((${#pids[@]} > 0)) || die "unknown mirror selection: $MIRROR_CHOICE"
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  ranked="$STAGE/ranked.tsv"
  for result in "${rank_files[@]}"; do [[ -s $result ]] && cat "$result"; done | sort -n -k1,1 >"$ranked"
  rank_count="$(wc -l <"$ranked")"
  (( rank_count > 0 )) || die "rankmirrors found no reachable mainland mirror"
  info "rankmirrors: $rank_count/${#rank_files[@]} reachable"

  pids=()
  while IFS=$'\t' read -r milliseconds name base; do
    ((${#results[@]} < RANK_VALIDATE_TOP)) || break
    result="$STAGE/$name.result"
    results+=("$result")
    (probe_mirror "$name|$base" "$result" "$milliseconds") &
    pids+=("$!")
  done <"$ranked"
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  for result in "${results[@]}"; do
    [[ -s $result ]] || continue
    for package in "${PACKAGES[@]}"; do
      version="$(candidate_field "$result" "$package" 2)"
      floor="${VERSION_FLOOR[$package]}"
      if [[ -z $version || $(vercmp "$version" "$floor") -lt 0 ]]; then
        warn "mirror rejected: $(basename "$result" .result) has stale $package ${version:-missing}"
        continue 2
      fi
    done
    valid_results+=("$result")
    if candidate_is_better "$result" "$best"; then best="$result"; fi
  done
  [[ -n $best ]] || die "no ranked mirror has the required package versions"

  compatible="$STAGE/compatible.tsv"
  for result in "${valid_results[@]}"; do
    if candidate_matches "$result" "$best"; then
      printf '%s\t%s\n' "$(candidate_mirror_field "$result" 4)" "$result"
    fi
  done | sort -n -k1,1 | head -n 3 >"$compatible"

  while IFS=$'\t' read -r milliseconds result; do
    VALID_MIRROR_NAMES+=("$(candidate_mirror_field "$result" 2)")
    VALID_MIRRORS+=("$(candidate_mirror_field "$result" 3)")
    if [[ -z $selected_result ]]; then selected_result="$result"; fi
  done <"$compatible"
  [[ -n $selected_result ]] || die "no consistent mirror set survived validation"

  SELECTED_NAME="$(candidate_mirror_field "$selected_result" 2)"
  for package in "${PACKAGES[@]}"; do
    VERSION[$package]="$(candidate_field "$selected_result" "$package" 2)"
    FILENAME[$package]="$(candidate_field "$selected_result" "$package" 3)"
    SHA256[$package]="$(candidate_field "$selected_result" "$package" 4)"
    INSTALLED[$package]="$(pacman -Q "$package" 2>/dev/null | awk '{print $2}' || true)"
    if [[ -z ${INSTALLED[$package]} || $(vercmp "${INSTALLED[$package]}" "${VERSION[$package]}") -lt 0 ]]; then
      NEED_INSTALL[$package]=1
    else
      NEED_INSTALL[$package]=0
    fi
  done
}

show_plan() {
  local package current action
  if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then
    gum style --border normal --padding "1 2" \
      "Mihomo bootstrap" \
      "" \
      "Primary mirror: $SELECTED_NAME" \
      "Validated mirrors: ${VALID_MIRROR_NAMES[*]}" \
      "$([[ $DOWNLOAD_ONLY == 1 ]] && echo 'Download-only test: no system packages will be changed.' || echo 'No subscription or service will be configured.')"
  else
    printf '\nMihomo bootstrap\nPrimary mirror: %s\nValidated mirrors: %s\n\n' \
      "$SELECTED_NAME" "${VALID_MIRROR_NAMES[*]}"
  fi
  printf '%-24s %-20s %-20s %s\n' PACKAGE INSTALLED CANDIDATE ACTION
  for package in "${PACKAGES[@]}"; do
    current="${INSTALLED[$package]:--}"
    if (( DOWNLOAD_ONLY )); then action=download; elif (( NEED_INSTALL[$package] )); then action=install; else action=keep; fi
    printf '%-24s %-20s %-20s %s\n' "$package" "$current" "${VERSION[$package]}" "$action"
  done
}

confirm_install() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 && -t 1 ]] || die "interactive confirmation is required; use --yes only for automation"
  local prompt affirmative
  if (( DOWNLOAD_ONLY )); then
    prompt="Download and verify these packages without installing?"
    affirmative="Verify"
  else
    prompt="Download, verify, and install these packages?"
    affirmative="Install"
  fi
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false --affirmative "$affirmative" --negative "Cancel" "$prompt"
  else
    local answer
    read -r -p "$prompt [y/N] " answer
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
  fi
}

download_one() {
  local package="$1" filename expected destination partial signature signature_partial base
  filename="${FILENAME[$package]}"
  expected="${SHA256[$package]}"
  destination="$CACHE_DIR/packages/$filename"
  partial="$destination.part"
  signature="$destination.sig"
  signature_partial="$signature.part"

  if [[ -s $destination ]] && printf '%s  %s\n' "$expected" "$destination" | sha256sum -c - >/dev/null 2>&1; then
    info "cached: $filename"
  else
    rm -f -- "$destination" "$partial"
    for base in "${VALID_MIRRORS[@]}"; do
      if fetch "$base/$filename" "$partial" 180 &&
         printf '%s  %s\n' "$expected" "$partial" | sha256sum -c - >/dev/null 2>&1; then
        mv -f -- "$partial" "$destination"
        break
      fi
      rm -f -- "$partial"
    done
    [[ -s $destination ]] || return 1
  fi

  rm -f -- "$signature_partial"
  for base in "${VALID_MIRRORS[@]}"; do
    if fetch "$base/$filename.sig" "$signature_partial" 30; then
      mv -f -- "$signature_partial" "$signature"
      break
    fi
  done
  [[ -s $signature ]] || return 1
}

verify_bundled_key() {
  local file="$1" expected="$2" actual
  [[ -s $file ]] || die "bundled key is missing: $file"
  actual="$(gpg --show-keys --with-colons "$file" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ $actual == "$expected" ]] || die "bundled key fingerprint mismatch: $(basename "$file")"
}

verify_artifacts() {
  verify_bundled_key "$KEY_DIR/archlinuxcn-keyring-signer.asc" "$KEYRING_FPR"
  verify_bundled_key "$KEY_DIR/archlinuxcn-lilac.asc" "$MIHOMO_FPR"
  verify_bundled_key "$KEY_DIR/clash-geoip.asc" "$GEOIP_FPR"

  local gnupg="$STAGE/gnupg" package file status valid
  mkdir -m 0700 "$gnupg"
  GNUPGHOME="$gnupg" gpg --batch --quiet --import "$KEY_DIR"/*.asc
  for package in "${PACKAGES[@]}"; do
    (( DOWNLOAD_ONLY || NEED_INSTALL[$package] )) || continue
    file="$CACHE_DIR/packages/${FILENAME[$package]}"
    status="$(GNUPGHOME="$gnupg" gpg --batch --status-fd=1 --verify "$file.sig" "$file" 2>/dev/null)" ||
      die "PGP verification failed: ${FILENAME[$package]}"
    valid="$(awk '$2 == "VALIDSIG" { print $3; exit }' <<<"$status")"
    [[ $valid == "${EXPECTED_SIGNER[$package]}" ]] ||
      die "unexpected package signer for ${FILENAME[$package]}: ${valid:-none}"

    printf '%s  %s\n' "${SHA256[$package]}" "$file" | sha256sum -c - >/dev/null
    local pkgname pkgver pkgarch
    pkgname="$(bsdtar -xOf "$file" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    pkgver="$(bsdtar -xOf "$file" .PKGINFO | awk -F ' = ' '$1 == "pkgver" {print $2; exit}')"
    pkgarch="$(bsdtar -xOf "$file" .PKGINFO | awk -F ' = ' '$1 == "arch" {print $2; exit}')"
    [[ $pkgname == "$package" && $pkgver == "${VERSION[$package]}" ]] ||
      die "package metadata mismatch: ${FILENAME[$package]}"
    [[ $pkgarch == any || $pkgarch == x86_64 ]] ||
      die "package architecture mismatch: ${FILENAME[$package]} ($pkgarch)"
    info "verified: $package $pkgver ($valid)"
  done
}

root_run() {
  if (( EUID == 0 )); then "$@"; else
    need_command sudo
    sudo "$@"
  fi
}

write_pacman_config() {
  local output="$1"
  cat >"$output" <<'EOF'
[options]
Architecture = auto
CheckSpace
DBPath = /var/lib/pacman/
CacheDir = /var/cache/pacman/pkg/
LogFile = /var/log/pacman.log
GPGDir = /etc/pacman.d/gnupg/
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Required
EOF
}

install_artifacts() {
  local pacman_config="$STAGE/pacman.conf" keyring_file
  write_pacman_config "$pacman_config"

  if (( NEED_INSTALL[archlinuxcn-keyring] )); then
    log "Installing the ArchLinuxCN keyring"
    root_run pacman-key --init
    root_run pacman-key --add "$KEY_DIR/archlinuxcn-keyring-signer.asc"
    root_run pacman-key --lsign-key "$KEYRING_FPR" >/dev/null
    keyring_file="$CACHE_DIR/packages/${FILENAME[archlinuxcn-keyring]}"
    root_run pacman --config "$pacman_config" -U --needed --noconfirm "$keyring_file"
    root_run pacman-key --populate archlinuxcn
  elif [[ -r /usr/share/pacman/keyrings/archlinuxcn.gpg ]]; then
    # Idempotent and offline; repairs a keyring package that was installed but
    # never populated into pacman's live keyring.
    root_run pacman-key --populate archlinuxcn
  fi

  local -a files=()
  (( NEED_INSTALL[clash-geoip] )) && files+=("$CACHE_DIR/packages/${FILENAME[clash-geoip]}")
  (( NEED_INSTALL[mihomo] )) && files+=("$CACHE_DIR/packages/${FILENAME[mihomo]}")
  if ((${#files[@]})); then
    log "Installing Mihomo and GeoIP"
    root_run pacman --config "$pacman_config" -U --needed --noconfirm "${files[@]}"
  else
    info "Mihomo and GeoIP are already current; no package transaction needed."
  fi
}

verify_installation() {
  local version tmp mmdb_mihomo=/etc/mihomo/Country.mmdb mmdb_clash=/etc/clash/Country.mmdb
  command -v mihomo >/dev/null 2>&1 || die "mihomo is not installed"
  pacman -Q mihomo clash-geoip >/dev/null || die "mihomo/clash-geoip package ownership is missing"
  [[ -s $mmdb_mihomo && -s $mmdb_clash ]] || die "Country.mmdb is missing"
  [[ $(stat -Lc %s "$mmdb_mihomo") -ge 1000000 ]] || die "Country.mmdb is unexpectedly small"
  [[ $(sha256sum "$mmdb_mihomo" | awk '{print $1}') == $(sha256sum "$mmdb_clash" | awk '{print $1}') ]] ||
    die "Mihomo and Clash GeoIP files differ"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-verify.XXXXXX")"
  cp --reflink=auto "$mmdb_mihomo" "$tmp/Country.mmdb"
  cat >"$tmp/config.yaml" <<'EOF'
mode: rule
log-level: silent
proxies: []
proxy-groups: []
rules:
  - GEOIP,CN,DIRECT
  - MATCH,DIRECT
EOF
  mihomo -t -d "$tmp" -f "$tmp/config.yaml" >/dev/null
  rm -rf -- "$tmp"
  version="$(mihomo -v | head -n1)"
  info "$version"
  info "GeoIP: $mmdb_mihomo ($(stat -Lc %s "$mmdb_mihomo") bytes)"
  info "No Mihomo service was started or enabled."
}

launch_popup() {
  command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1 ||
    die "Omarchy popup launcher is unavailable"
  local self command
  self="$(realpath -- "$0")"
  printf -v command '%q ' "$self" install "$@"
  exec omarchy-launch-floating-terminal-with-presentation "$command"
}

parse_options() {
  while (($#)); do
    case "$1" in
      --yes|-y) ASSUME_YES=1 ;;
      --download-only) DOWNLOAD_ONLY=1 ;;
      --mirror)
        shift
        (($#)) || die "--mirror requires auto or a bundled mirror name"
        MIRROR_CHOICE="$1"
        mirror_known "$MIRROR_CHOICE" || die "unknown mirror: $MIRROR_CHOICE"
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

main() {
  local command="${1:-launch}"
  (($# == 0)) || shift
  case "$command" in
    launch)
      launch_popup "$@"
      ;;
    verify)
      (($# == 0)) || die "verify takes no options"
      preflight
      log "Verifying the existing installation"
      verify_installation
      ;;
    plan|install)
      parse_options "$@"
      preflight
      exec 9>"$LOCK_FILE"
      flock -n 9 || die "another Mihomo bootstrap is already running"
      resolve_plan
      show_plan
      [[ $command == plan ]] && exit 0
      if ! confirm_install; then
        echo "Installation cancelled"
        exit 130
      fi
      local package fetch_count=0
      for package in "${PACKAGES[@]}"; do
        (( DOWNLOAD_ONLY || NEED_INSTALL[$package] )) && ((++fetch_count))
      done
      if (( fetch_count )); then
        log "Downloading signed packages in parallel"
        local -a download_pids=() download_packages=()
        local download_failed="" index
        for package in "${PACKAGES[@]}"; do
          (( DOWNLOAD_ONLY || NEED_INSTALL[$package] )) || continue
          (download_one "$package") &
          download_pids+=("$!")
          download_packages+=("$package")
        done
        for index in "${!download_pids[@]}"; do
          if ! wait "${download_pids[$index]}"; then
            download_failed+=" ${download_packages[$index]}"
          fi
        done
        [[ -z $download_failed ]] || die "parallel download failed:$download_failed"
        log "Verifying signatures and package metadata"
        verify_artifacts
      else
        info "All required packages are already current; no download needed."
      fi
      if (( DOWNLOAD_ONLY )); then
        info "Download-only verification completed; the system was not changed."
        exit 0
      fi
      if (( fetch_count )); then
        install_artifacts
      else
        info "No package transaction or sudo was needed."
      fi
      log "Verifying the installation"
      verify_installation
      mkdir -p "$STATE_DIR"
      printf '%s\t%s\t%s\n' "$(date --iso-8601=seconds)" "$SELECTED_NAME" "${VERSION[mihomo]}" >"$STATE_DIR/last-success.tsv"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
