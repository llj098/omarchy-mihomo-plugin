# Omarchy Mihomo Plugin

The first feature is a native Omarchy bar panel backed by a pure Bash bootstrap for installing the ArchLinuxCN `mihomo` and `clash-geoip` packages without an existing proxy.

The panel deliberately reuses Omarchy's own `Panel`, `BarIconButton`, `KeyboardPanel`, `PanelHero`, `CursorSurface`, `Button`, spacing, font, border, and color tokens. It does not copy or approximate the system theme. When `mihomo` is absent, the panel shows a **Bootstrap** button that opens the reviewed installation flow in Omarchy's floating terminal. An installed system shows the binary, package, and GeoIP state instead.

Subscription handling, Mihomo configuration, proxy controls, and service control are not implemented yet.

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

## Commands

```bash
./bootstrap/bootstrap.sh plan
./bootstrap/bootstrap.sh install
./bootstrap/bootstrap.sh install --download-only
./bootstrap/bootstrap.sh verify
```

`--yes` is only for automation. Non-interactive installation otherwise fails closed.

## Network and trust

Before a proxy exists, the script contacts only the HTTPS mainland-China entries in the bundled snapshot of ArchLinuxCN's official [`mirrorlist-repo`](https://github.com/archlinuxcn/mirrorlist-repo), and explicitly removes inherited proxy variables. No mirror is written to `pacman.conf`.

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
- does not download a subscription;
- does not enable or start a service;
- does not modify Clash Verge;
- is serialized with `flock` and is idempotent for current/newer installed versions.

## Tests

```bash
./tests/test-bootstrap.sh
./tests/test-ui.sh
```

The local tests use a localhost mirror fixture to verify rank-based mirror failover, forced removal of proxy variables, version resolution, arbitrary-mirror rejection, and the confirmation-cancel zero-write path. UI tests cover missing/ready status fixtures, Bootstrap gating and invocation, manifest shape, required Omarchy components, and the absence of hard-coded visual tokens.

For a real China-mirror download/signature test without installation:

```bash
./bootstrap/bootstrap.sh install --download-only --yes
```
