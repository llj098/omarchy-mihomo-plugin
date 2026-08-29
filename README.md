# Omarchy Mihomo Plugin

Only the first, standalone feature exists so far: a pure Bash bootstrap for installing the ArchLinuxCN `mihomo` and `clash-geoip` packages on Omarchy without an existing proxy.

No QML panel, subscription handling, Mihomo configuration, or service control is implemented.

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

Before a proxy exists, the script contacts only these documented Chinese university mirrors and explicitly removes inherited proxy variables:

```text
https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/x86_64
https://mirrors.ustc.edu.cn/archlinuxcn/x86_64
```

Both repository databases are fetched in parallel. The script chooses the newest candidate set, then the faster mirror when versions match. The unsigned repository database is used only to discover package filenames and metadata. Every downloaded package must pass:

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
```

The local test uses a localhost mirror fixture to verify mirror failover, forced removal of proxy variables, version resolution, arbitrary-mirror rejection, and the confirmation-cancel zero-write path.

For a real China-mirror download/signature test without installation:

```bash
./bootstrap/bootstrap.sh install --download-only --yes
```
