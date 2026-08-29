#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KEY_DIR="$SCRIPT_DIR/keys"
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

# name|base. Only these China mirrors are reachable in production bootstrap.
MIRRORS=(
  "tuna|https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/x86_64"
  "ustc|https://mirrors.ustc.edu.cn/archlinuxcn/x86_64"
)

# Tests may replace the mirrors with localhost fixtures, but production users
# cannot supply arbitrary download hosts.
if [[ ${MIHOMO_BOOTSTRAP_TESTING:-0} == 1 && -n ${MIHOMO_BOOTSTRAP_MIRRORS:-} ]]; then
  IFS=',' read -r -a MIRRORS <<<"$MIHOMO_BOOTSTRAP_MIRRORS"
fi

declare -A VERSION FILENAME SHA256 INSTALLED NEED_INSTALL
declare -a VALID_MIRRORS
SELECTED_NAME=""
SELECTED_BASE=""

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
  bootstrap.sh plan [--mirror auto|tuna|ustc]
  bootstrap.sh install [--yes] [--download-only] [--mirror auto|tuna|ustc]
  bootstrap.sh verify

The bootstrap downloads only from the TUNA and USTC ArchLinuxCN mirrors,
verifies package signatures, and installs mihomo plus clash-geoip. It does not
configure subscriptions, start a service, or modify pacman mirrors.
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

  for cmd in bash curl gpg bsdtar sha256sum pacman vercmp flock awk; do
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

probe_mirror() {
  local spec="$1" result="$2" name base db tree start elapsed package row
  name="${spec%%|*}"
  base="${spec#*|}"
  db="$STAGE/$name.db"
  tree="$STAGE/$name-db"
  start="$(date +%s%N)"
  fetch "$base/archlinuxcn.db" "$db" 30 || return 1
  mkdir -p "$tree"
  bsdtar -xf "$db" -C "$tree" || return 1
  : >"$result"
  for package in "${PACKAGES[@]}"; do
    row="$(resolve_from_tree "$tree" "$package")" || return 1
    printf '%s\t%s\n' "$package" "$row" >>"$result"
  done
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
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

resolve_plan() {
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-bootstrap.XXXXXX")"
  local spec name result pid best="" package version floor line
  local -a pids=() results=()

  log "Checking China mirrors"
  for spec in "${MIRRORS[@]}"; do
    name="${spec%%|*}"
    if [[ $MIRROR_CHOICE != auto && $MIRROR_CHOICE != "$name" ]]; then
      continue
    fi
    result="$STAGE/$name.result"
    results+=("$result")
    (probe_mirror "$spec" "$result") &
    pids+=("$!")
  done
  ((${#pids[@]} > 0)) || die "unknown mirror selection: $MIRROR_CHOICE"
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  for result in "${results[@]}"; do
    if [[ ! -s $result ]]; then
      warn "mirror probe failed: $(basename "$result" .result)"
      continue
    fi
    for package in "${PACKAGES[@]}"; do
      version="$(candidate_field "$result" "$package" 2)"
      floor="${VERSION_FLOOR[$package]}"
      if [[ -z $version || $(vercmp "$version" "$floor") -lt 0 ]]; then
        warn "mirror rejected: $(basename "$result" .result) has stale $package ${version:-missing}"
        continue 2
      fi
    done
    VALID_MIRRORS+=("$(candidate_mirror_field "$result" 3)")
    if candidate_is_better "$result" "$best"; then best="$result"; fi
  done
  [[ -n $best ]] || die "no healthy China mirror has the required signed package versions"

  SELECTED_NAME="$(candidate_mirror_field "$best" 2)"
  SELECTED_BASE="$(candidate_mirror_field "$best" 3)"
  # Put the selected base first, retaining valid fallbacks for identical files.
  local -a ordered=("$SELECTED_BASE")
  for line in "${VALID_MIRRORS[@]}"; do
    [[ $line == "$SELECTED_BASE" ]] || ordered+=("$line")
  done
  VALID_MIRRORS=("${ordered[@]}")

  for package in "${PACKAGES[@]}"; do
    VERSION[$package]="$(candidate_field "$best" "$package" 2)"
    FILENAME[$package]="$(candidate_field "$best" "$package" 3)"
    SHA256[$package]="$(candidate_field "$best" "$package" 4)"
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
      "China mirror: $SELECTED_NAME" \
      "$([[ $DOWNLOAD_ONLY == 1 ]] && echo 'Download-only test: no system packages will be changed.' || echo 'No subscription or service will be configured.')"
  else
    printf '\nMihomo bootstrap\nChina mirror: %s\n\n' "$SELECTED_NAME"
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
        (($#)) || die "--mirror requires auto, tuna, or ustc"
        MIRROR_CHOICE="$1"
        [[ $MIRROR_CHOICE == auto || $MIRROR_CHOICE == tuna || $MIRROR_CHOICE == ustc || ${MIHOMO_BOOTSTRAP_TESTING:-0} == 1 ]] ||
          die "unknown mirror: $MIRROR_CHOICE"
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
        log "Downloading signed packages"
        for package in "${PACKAGES[@]}"; do
          (( DOWNLOAD_ONLY || NEED_INSTALL[$package] )) || continue
          download_one "$package" || die "download failed: ${FILENAME[$package]}"
        done
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
