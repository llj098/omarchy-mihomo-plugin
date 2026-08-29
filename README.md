# Omarchy Mihomo Plugin

This is a native Omarchy bar panel backed by a pure Bash bootstrap for installing the ArchLinuxCN `mihomo` and `clash-geoip` packages, plus a separate lightweight subscription importer.

The panel deliberately reuses Omarchy's own `Panel`, `BarIconButton`, `KeyboardPanel`, `PanelHero`, `CursorSurface`, `Button`, spacing, font, border, and color tokens. It does not copy or approximate the system theme. When `mihomo` is absent, the panel shows a **Bootstrap** button that opens the reviewed installation flow in Omarchy's floating terminal. An installed system shows the binary, package, and GeoIP state instead.

Proxy controls and service control are intentionally not implemented yet.

## Plugin UI

Install the repository as `~/.config/omarchy/plugins/fatlj.mihomo`, rescan plugins, and place it next to the network widget:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable fatlj.mihomo --before omarchy.network
```

The status helper is read-only:

```bash
./bootstrap/status.sh | jq .
```

It checks the executable, pacman package, and `Country.mmdb`. The bar panel refreshes on open, every 30 seconds while open, and every two seconds while a bootstrap popup is running.

## Interactive Omarchy flow

Open the native floating Omarchy terminal and require an explicit Gum confirmation:

```bash
./bootstrap/bootstrap.sh launch
```

The popup shows the selected China mirror, installed versions, candidate versions, and the exact install/keep actions. Cancelling exits with status 130 before package downloads or sudo.

A safe UI/download test uses the same popup but never changes system packages:

```bash
./bootstrap/bootstrap.sh launch --download-only
```

## Subscription import

The installation and subscription sections are separated with Omarchy's native `PanelSeparator`. Click **Add subscription**, enter one value, and press Enter or **Import**:

- `http://` or `https://` is downloaded with curl;
- every other value is treated as an absolute local path or a path beginning with `~/`.

The importer does not add, remove, or bypass proxy settings. Curl honors the user's existing environment and curl configuration; without a configured proxy it connects directly. Sources are passed from QML over stdin rather than argv.

Subscriptions are stored physically under the plugin directory as requested:

```text
data/subscriptions/url-<sha256-of-exact-url>/
  config.yaml
  source.url
data/subscriptions/local-<timestamp>-<random>/
  config.yaml
```

Omarchy recursively watches plugin directories and its validator rejects symlinks, so downloads, local copies, logs, locking, and Mihomo validation are staged under `~/.cache/fatlj-mihomo-subscription`. Only one final atomic rename enters the watched `data/` tree. This reduces an import from dozens of reload-triggering events to one unavoidable commit event while keeping the actual subscription in the plugin directory.

The complete URL is saved in `source.url` with mode 0600 but is never returned by the status helper. Importing the exact URL again atomically updates its existing entry. Local files deliberately have no source metadata or deduplication and create a new entry each time. Entries and the data directory use modes 0600 and 0700 respectively.

Downloads and local copies are limited to 8 MiB. Every candidate must pass `mihomo -t` in an isolated temporary directory before an atomic commit; a failed import leaves the previous subscription unchanged. The importer accepts complete Mihomo/Clash YAML configurations, not encoded node lists requiring an online converter.

The helpers can also be used directly:

```bash
printf '%s\n' 'https://provider.example/config' | ./subscription/import.sh
./subscription/status.sh | jq .
```

## Commands

```bash
./bootstrap/bootstrap.sh plan
./bootstrap/bootstrap.sh install
./bootstrap/bootstrap.sh install --download-only
./bootstrap/bootstrap.sh verify
```

`--yes` is only for automation. Non-interactive installation otherwise fails closed.

## Network and trust

Before a proxy exists, the **Bootstrap script** contacts only the HTTPS mainland-China entries in the bundled snapshot of ArchLinuxCN's official [`mirrorlist-repo`](https://github.com/archlinuxcn/mirrorlist-repo), and explicitly removes inherited proxy variables. No mirror is written to `pacman.conf`. This policy is Bootstrap-specific; the separate subscription importer preserves user network settings.

All listed mirrors are measured concurrently with the system `pacman-contrib` `rankmirrors` command. Each measurement has a 10-second timeout, so unreachable mirrors do not make the complete ranking serially slow. The ten fastest responses are metadata-validated; up to three mirrors with identical package versions, filenames, and SHA-256 values become the primary plus fallbacks.

The required package and signature pairs are downloaded concurrently. Installation remains ordered: keyring first, then GeoIP and Mihomo. The unsigned repository database is used only to discover package filenames and metadata. Every downloaded package must pass:

- the SHA-256 recorded in the repository metadata;
- a detached OpenPGP signature from the pinned full signer fingerprint;
- internal `.PKGINFO` name, version, and architecture checks;
- the configured minimum version floor.

The packaged keys are fingerprint-checked before use. `pacman` installation uses `LocalFileSigLevel = Required`. The script does not permanently add ArchLinuxCN to `pacman.conf` or modify the system mirror list.

Downloads are staged under `~/.cache/fatlj-mihomo-bootstrap`. Only the final keyring/package transaction uses sudo.

## Scope and safety

The bootstrap:

- supports Omarchy/Arch x86_64;
- installs `archlinuxcn-keyring`, `clash-geoip`, and `mihomo` when required;
- verifies Mihomo with a temporary `GEOIP,CN,DIRECT` configuration;
- imports validated local or HTTP(S) subscription configurations without activating them;
- does not enable or start a service;
- does not modify Clash Verge;
- is serialized with `flock` and is idempotent for current/newer installed versions.

## Tests

```bash
./tests/test-bootstrap.sh
./tests/test-subscription.sh
./tests/test-ui.sh
```

The local tests use localhost fixtures to verify rank-based Bootstrap failover and proxy removal, subscription proxy inheritance, exact-URL deduplication, unrestricted local-file duplication, permissions, validation failure atomicity, and UI separation. UI tests also cover missing/ready installation states, manifest shape, required Omarchy components, and the absence of hard-coded visual tokens.

For a real China-mirror download/signature test without installation:

```bash
./bootstrap/bootstrap.sh install --download-only --yes
```
