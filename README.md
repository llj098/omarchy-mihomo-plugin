# Omarchy Mihomo Plugin

This is a native Omarchy bar panel backed by a pure Bash bootstrap for installing the ArchLinuxCN `mihomo` and `clash-geoip` packages, plus a separate lightweight subscription importer.

The panel deliberately reuses Omarchy's own `Panel`, `BarIconButton`, `KeyboardPanel`, `PanelHero`, `CursorSurface`, `Button`, spacing, font, border, and color tokens. It does not copy or approximate the system theme. When `mihomo` is absent, the panel shows a **Bootstrap** button that opens the reviewed installation flow in Omarchy's floating terminal. An installed system shows the binary, package, and GeoIP state instead.

The panel also provides narrowly scoped runtime settings for the plugin-owned Mihomo service; it does not manage desktop proxy settings.

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

The subscription status helper uses the system `python-yaml` SafeLoader with bounded alias expansion to parse inline `proxies`. Only each node's `name` and `type` enter status JSON; server addresses, ports, UUIDs, passwords, and other credentials are never returned. Every subscription owns an independently collapsible node list inside one height-bounded scrolling region. Headers default collapsed and show the label, node count, and expand/collapse indicator; expansion state is memory-only. Up to 500 nodes per subscription are rendered when expanded, with the full count and truncation notice retained. `proxy-providers` are counted, but provider nodes cannot be listed until their separate provider files exist locally.

Downloads and local copies are limited to 8 MiB. Every candidate must pass `mihomo -t` in an isolated temporary directory before an atomic commit; a failed import leaves the previous subscription unchanged. The importer accepts complete Mihomo/Clash YAML configurations, not encoded node lists requiring an online converter.

## Selected-node runtime

Clicking an inline node generates an isolated runtime configuration and starts a transient user service named `fatlj-mihomo.service`. Runtime settings default to mixed port `7891` and localhost-only binding, leaving any existing service on `7890` untouched. Any port in `1024..65535`, including `7890`, and **Allow LAN** are drafts until **Apply** is clicked. An occupied target port is rejected without interrupting the running Mihomo instance. Settings are atomically saved mode 0600 at `~/.local/state/fatlj.mihomo/settings.json`; Apply restarts the same selected node only when this plugin runtime is active, otherwise it affects the next start. A failed restart restores the previous settings and attempts to restore the previous running endpoint. The panel highlights the active node, shows the runtime endpoint, and provides **Stop Mihomo**.

The main runtime always exposes its Controller through `~/.local/state/fatlj.mihomo/runtime/controller.sock`, inside the mode-0700 state directory; no TCP Controller is opened. While the panel is open, it reads active connections, current transfer rates, totals, and selected-node health from that running process every two seconds. Closing the panel stops all polling. Loading or rebuilding the plugin performs one basic systemd/state-file status read so the bar icon survives Shell restarts; it does not access the Controller or start periodic background work. Opening the panel performs one Controller latency test for the active node so the Latency field has a current sample; it is not repeated while the panel remains closed. If that node does not respond or exceeds 1000 ms, one asynchronous recommendation run starts temporary, listener-free Mihomo instances outside the watched plugin tree. Each imported subscription is tested independently, the three fastest responsive inline nodes are shown in a height-bounded **Recommend** section, and those rows reuse the normal proxy-node component and click-to-start behavior. A responsive active node at or below 1000 ms never starts this work; if the active node becomes healthy after a switch, any in-flight recommendation test is terminated and the section is cleared. The temporary processes never replace or stop the main runtime and are terminated after their tests. Manual group speed tests continue to use the main Controller and remain available only for the active subscription while Mihomo is running.

When applied **Allow LAN** is enabled, the panel always shows **Review UFW rule**. It opens Omarchy's floating terminal and, after verifying UFW exists, clearly warns that `ufw allow PORT/tcp` permits all UFW-accepted sources. Only explicit Gum confirmation runs `sudo ufw status` and `sudo ufw allow PORT/tcp`; the plugin does not inspect UFW silently, enable/disable it, remove old rules, or support other firewall backends. Password input remains entirely inside sudo's terminal prompt.

The original subscription is never modified. The generated configuration:

- retains the subscription's proxy definitions and DNS resolvers;
- creates a one-node `__FATLJ_ACTIVE__` select group and forces `MATCH` through it;
- removes imported HTTP/SOCKS/redir/TProxy/controller/listener/TUN ports and rule providers, then supplies the plugin-owned Unix Controller at process launch;
- removes the DNS listener while retaining internal DNS behavior;
- sets `mixed-port`, `allow-lan`, and `bind-address` from the saved runtime settings (`127.0.0.1` when disabled, `0.0.0.0` when enabled);
- is validated with `mihomo -t` before replacing the active runtime.

Runtime files and the current selection are mode-0600 data under `~/.local/state/fatlj.mihomo`; GeoIP is referenced from the signed system package. The plugin does not change desktop proxy settings, stop Clash Verge, or route applications automatically—clients opt in by using the saved mixed port (`7891` by default).

The helpers can also be used directly:

```bash
printf '%s\n' 'https://provider.example/config' | ./subscription/import.sh
./subscription/status.sh | jq .
./subscription/control.py status
./subscription/control.py stop
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
python3 ./tests/test-control.py
./tests/test-ufw.sh
./tests/test-ui.sh
```

The local tests use localhost fixtures to verify rank-based Bootstrap failover and proxy removal, subscription import safety, runtime settings persistence/config generation/restart behavior, UFW confirmation and command construction with fake commands, and UI wiring. UI tests also cover default-collapsed independent subscription headers, click-to-start wiring, manifest shape, required Omarchy components, and the absence of hard-coded visual tokens.

For a real China-mirror download/signature test without installation:

```bash
./bootstrap/bootstrap.sh install --download-only --yes
```
