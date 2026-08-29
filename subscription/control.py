#!/usr/bin/env python3
import fcntl
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    print("python-yaml is required to prepare Mihomo runtime configurations", file=sys.stderr)
    raise SystemExit(1)

UNIT = "fatlj-mihomo.service"
DEFAULT_PORT = 7891
MAX_CONFIG_BYTES = 8 * 1024 * 1024
MAX_YAML_ALIASES = 100


class ControlError(Exception):
    pass


class LimitedSafeLoader(yaml.SafeLoader):
    def __init__(self, stream):
        super().__init__(stream)
        self.alias_count = 0

    def compose_node(self, parent, index):
        if self.check_event(yaml.AliasEvent):
            self.alias_count += 1
            if self.alias_count > MAX_YAML_ALIASES:
                raise yaml.YAMLError("too many YAML aliases")
        return super().compose_node(parent, index)


def paths():
    script_dir = Path(__file__).resolve().parent
    plugin_dir = script_dir.parent
    data_dir = plugin_dir / "data" / "subscriptions"
    state_root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "fatlj.mihomo"
    if os.environ.get("MIHOMO_CONTROL_TESTING") == "1":
        data_dir = Path(os.environ.get("MIHOMO_SUBSCRIPTION_DATA", data_dir))
        state_root = Path(os.environ.get("MIHOMO_CONTROL_STATE", state_root))
    return data_dir, state_root


def run(command, check=True):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise ControlError(result.stderr.strip() or result.stdout.strip() or "command failed")
    return result


def systemctl(*arguments, check=True):
    return run(["systemctl", "--user", *arguments], check=check)


def unit_properties():
    result = systemctl(
        "show",
        UNIT,
        "--property=LoadState,ActiveState,SubState,MainPID",
        check=False,
    )
    properties = {"LoadState": "not-found", "ActiveState": "inactive", "SubState": "dead", "MainPID": "0"}
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                properties[key] = value
    return properties


def stop_service():
    systemctl("stop", UNIT, check=False)
    for _ in range(60):
        properties = unit_properties()
        if properties["ActiveState"] not in {"active", "activating", "deactivating"}:
            break
        time.sleep(0.05)
    systemctl("reset-failed", UNIT, check=False)
    for _ in range(60):
        if unit_properties()["LoadState"] == "not-found":
            return
        time.sleep(0.05)
    if unit_properties()["LoadState"] != "not-found":
        raise ControlError("The previous Mihomo runtime unit did not unload")


def port_is_open(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.1)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def subscription_config(data_dir: Path, subscription_id: str) -> Path:
    if not subscription_id or "/" in subscription_id or subscription_id in {".", ".."}:
        raise ControlError("Invalid subscription identity")
    root = data_dir.resolve()
    entry = (root / subscription_id).resolve()
    if entry.parent != root:
        raise ControlError("Invalid subscription path")
    config = entry / "config.yaml"
    if not config.is_file() or config.stat().st_size == 0:
        raise ControlError("Subscription configuration is missing")
    if config.stat().st_size > MAX_CONFIG_BYTES:
        raise ControlError("Subscription configuration exceeds the size limit")
    return config


def load_config(config: Path):
    try:
        with config.open("r", encoding="utf-8") as stream:
            document = yaml.load(stream, Loader=LimitedSafeLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        raise ControlError("Could not parse the subscription configuration") from error
    if not isinstance(document, dict):
        raise ControlError("Subscription configuration root is not a mapping")
    return document


def prepare_runtime_config(document, node_name: str, port: int):
    proxies = document.get("proxies")
    if not isinstance(proxies, list):
        raise ControlError("Subscription has no inline proxy nodes")
    matches = [proxy for proxy in proxies if isinstance(proxy, dict) and proxy.get("name") == node_name]
    if len(matches) != 1:
        raise ControlError("Selected node was not found uniquely in the subscription")
    node_type = matches[0].get("type") if isinstance(matches[0].get("type"), str) else "unknown"

    runtime = dict(document)
    for key in (
        "port",
        "socks-port",
        "redir-port",
        "tproxy-port",
        "external-controller",
        "external-controller-tls",
        "external-ui",
        "external-ui-url",
        "secret",
        "listeners",
        "tun",
        "rule-providers",
    ):
        runtime.pop(key, None)
    runtime["mixed-port"] = port
    runtime["allow-lan"] = False
    runtime["bind-address"] = "127.0.0.1"
    runtime["mode"] = "rule"
    runtime["log-level"] = "warning"

    dns = runtime.get("dns")
    if isinstance(dns, dict):
        dns = dict(dns)
        dns.pop("listen", None)
        runtime["dns"] = dns

    active_group = "__FATLJ_ACTIVE__"
    groups = runtime.get("proxy-groups")
    if not isinstance(groups, list):
        groups = []
    groups = [group for group in groups if not (isinstance(group, dict) and group.get("name") == active_group)]
    groups.append({"name": active_group, "type": "select", "proxies": [node_name]})
    runtime["proxy-groups"] = groups
    runtime["rules"] = [f"MATCH,{active_group}"]

    profile = runtime.get("profile")
    if not isinstance(profile, dict):
        profile = {}
    else:
        profile = dict(profile)
    profile["store-selected"] = False
    runtime["profile"] = profile
    return runtime, node_type


def mihomo_binary():
    if os.environ.get("MIHOMO_CONTROL_TESTING") == "1" and os.environ.get("MIHOMO_CONTROL_MIHOMO"):
        binary = Path(os.environ["MIHOMO_CONTROL_MIHOMO"])
    else:
        found = shutil.which("mihomo")
        binary = Path(found) if found else Path("/nonexistent")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ControlError("Mihomo is not installed")
    return binary


def atomic_json(path: Path, payload):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def start_service(binary: Path, runtime_dir: Path):
    result = run(
        [
            "systemd-run",
            "--user",
            f"--unit={UNIT.removesuffix('.service')}",
            "--collect",
            "--description=Fatlj Mihomo selected-node runtime",
            "--property=Restart=on-failure",
            "--property=RestartSec=2s",
            "--property=UMask=0077",
            "--property=NoNewPrivileges=yes",
            "--property=PrivateTmp=yes",
            "--",
            str(binary),
            "-d",
            str(runtime_dir),
            "-f",
            str(runtime_dir / "config.yaml"),
        ],
        check=False,
    )
    if result.returncode != 0:
        raise ControlError(result.stderr.strip() or "Could not start the Mihomo user service")


def wait_for_start(port: int):
    last = unit_properties()
    for _ in range(100):
        last = unit_properties()
        if last["ActiveState"] == "active" and int(last.get("MainPID", "0") or 0) > 0 and port_is_open(port):
            return last
        if last["ActiveState"] == "failed":
            break
        time.sleep(0.05)
    raise ControlError(f"Mihomo did not start on 127.0.0.1:{port} ({last['ActiveState']}/{last['SubState']})")


def start():
    try:
        request = json.loads(sys.stdin.readline())
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ControlError("Invalid node selection request") from error
    if not isinstance(request, dict):
        raise ControlError("Invalid node selection request")
    subscription_id = request.get("subscriptionId")
    node_name = request.get("nodeName")
    if not isinstance(subscription_id, str) or not isinstance(node_name, str) or not node_name:
        raise ControlError("Subscription and node are required")

    data_dir, state_root = paths()
    config = subscription_config(data_dir, subscription_id)
    document = load_config(config)
    port = DEFAULT_PORT
    if os.environ.get("MIHOMO_CONTROL_TESTING") == "1" and os.environ.get("MIHOMO_CONTROL_PORT"):
        port = int(os.environ["MIHOMO_CONTROL_PORT"])
    runtime, node_type = prepare_runtime_config(document, node_name, port)
    binary = mihomo_binary()

    state_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state_root, 0o700)
    runtime_dir = state_root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(runtime_dir, 0o700)

    with tempfile.TemporaryDirectory(prefix="prepare-", dir=state_root) as temporary_name:
        prepare_dir = Path(temporary_name)
        prepared_config = prepare_dir / "config.yaml"
        prepared_config.write_text(
            yaml.safe_dump(runtime, allow_unicode=True, sort_keys=False), encoding="utf-8"
        )
        os.chmod(prepared_config, 0o600)
        for geoip in (Path("/etc/mihomo/Country.mmdb"), Path("/etc/clash/Country.mmdb")):
            if geoip.is_file() and geoip.stat().st_size > 0:
                (prepare_dir / "Country.mmdb").symlink_to(geoip)
                break
        validation = run([str(binary), "-t", "-d", str(prepare_dir), "-f", str(prepared_config)], check=False)
        if validation.returncode != 0:
            raise ControlError("Mihomo rejected the selected-node runtime configuration")

        stop_service()
        if port_is_open(port):
            raise ControlError(f"127.0.0.1:{port} is already in use")
        os.replace(prepared_config, runtime_dir / "config.yaml")

    os.chmod(runtime_dir / "config.yaml", 0o600)
    country = runtime_dir / "Country.mmdb"
    if country.is_symlink() or country.exists():
        country.unlink()
    for geoip in (Path("/etc/mihomo/Country.mmdb"), Path("/etc/clash/Country.mmdb")):
        if geoip.is_file() and geoip.stat().st_size > 0:
            country.symlink_to(geoip)
            break

    start_service(binary, runtime_dir)
    try:
        properties = wait_for_start(port)
    except ControlError:
        stop_service()
        raise
    selection = {
        "subscriptionId": subscription_id,
        "nodeName": node_name,
        "nodeType": node_type,
        "port": port,
        "startedAt": datetime.now(timezone.utc).isoformat(),
    }
    atomic_json(state_root / "selection.json", selection)
    return {
        "ok": True,
        "running": True,
        **selection,
        "pid": int(properties["MainPID"]),
    }


def status():
    _, state_root = paths()
    selection_file = state_root / "selection.json"
    selection = {}
    if selection_file.is_file():
        try:
            value = json.loads(selection_file.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                selection = value
        except (OSError, UnicodeError, json.JSONDecodeError):
            selection = {}
    properties = unit_properties()
    running = properties["ActiveState"] == "active" and int(properties.get("MainPID", "0") or 0) > 0
    return {
        "running": running,
        "activeState": properties["ActiveState"],
        "subState": properties["SubState"],
        "pid": int(properties.get("MainPID", "0") or 0),
        "subscriptionId": str(selection.get("subscriptionId", "")),
        "nodeName": str(selection.get("nodeName", "")),
        "nodeType": str(selection.get("nodeType", "")),
        "port": int(selection.get("port", DEFAULT_PORT)),
        "startedAt": str(selection.get("startedAt", "")),
    }


def stop():
    stop_service()
    result = status()
    result["ok"] = True
    return result


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    try:
        if command == "status":
            result = status()
        elif command in {"start", "stop"}:
            _, state_root = paths()
            state_root.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(state_root, 0o700)
            with (state_root / "control.lock").open("a", encoding="utf-8") as lock:
                os.chmod(lock.name, 0o600)
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                result = start() if command == "start" else stop()
        else:
            raise ControlError("Usage: control.py start|status|stop")
    except ControlError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"Mihomo runtime control failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
