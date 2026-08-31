#!/usr/bin/env python3
import concurrent.futures
import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote, urlencode, urlsplit

import yaml

DEFAULT_TEST_URL = "https://www.gstatic.com/generate_204"
TEST_GROUP = "__FATLJ_RECOMMEND__"
TIMEOUT_MS = 5000
MAX_CONFIG_BYTES = 8 * 1024 * 1024
MAX_PARALLEL_TESTS = 32
SYNTHETIC_GROUPS = {"ALL NODES", "UNGROUPED"}


class LatencyError(Exception):
    pass


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path, timeout=10):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = str(socket_path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def plugin_paths():
    script_dir = Path(__file__).resolve().parent
    data_dir = script_dir.parent / "data" / "subscriptions"
    state_root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "fatlj.mihomo"
    if os.environ.get("MIHOMO_LATENCY_TESTING") == "1":
        if os.environ.get("MIHOMO_SUBSCRIPTION_DATA"):
            data_dir = Path(os.environ["MIHOMO_SUBSCRIPTION_DATA"])
        if os.environ.get("MIHOMO_LATENCY_STATE"):
            state_root = Path(os.environ["MIHOMO_LATENCY_STATE"])
    return data_dir, state_root


def safe_subscription(data_dir, subscription_id):
    if not isinstance(subscription_id, str) or not subscription_id or "/" in subscription_id:
        raise LatencyError("Invalid subscription identity")
    root = data_dir.resolve()
    entry = (root / subscription_id).resolve()
    if entry.parent != root:
        raise LatencyError("Invalid subscription path")
    config = entry / "config.yaml"
    if not config.is_file() or not 0 < config.stat().st_size <= MAX_CONFIG_BYTES:
        raise LatencyError("Subscription configuration is missing or too large")
    return config


def load_document(config):
    try:
        document = yaml.safe_load(config.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        raise LatencyError("Could not parse subscription configuration") from error
    if not isinstance(document, dict):
        raise LatencyError("Subscription configuration root is not a mapping")
    return document


def all_proxy_nodes(document):
    proxies = document.get("proxies", [])
    if not isinstance(proxies, list):
        raise LatencyError("Subscription has no inline proxy nodes")
    nodes = []
    seen = set()
    for proxy in proxies:
        if not isinstance(proxy, dict):
            continue
        name = proxy.get("name")
        if not isinstance(name, str) or not name or name in seen:
            continue
        node_type = proxy.get("type")
        nodes.append({"name": name, "type": node_type if isinstance(node_type, str) else "unknown"})
        seen.add(name)
    if not nodes:
        raise LatencyError("Subscription has no inline proxy nodes")
    return nodes


def group_nodes(document, group_name):
    proxies = document.get("proxies", [])
    if not isinstance(proxies, list):
        raise LatencyError("Subscription has no inline proxy nodes")
    node_names = [
        proxy.get("name") for proxy in proxies
        if isinstance(proxy, dict) and isinstance(proxy.get("name"), str) and proxy.get("name")
    ]
    node_set = set(node_names)
    groups = document.get("proxy-groups", [])
    if not isinstance(groups, list):
        groups = []
    direct_grouped = set()
    selected = None
    for group in groups:
        if not isinstance(group, dict):
            continue
        members = group.get("proxies", [])
        if not isinstance(members, list):
            members = []
        direct = [member for member in members if isinstance(member, str) and member in node_set]
        direct_grouped.update(direct)
        if group.get("name") == group_name:
            selected = direct
    if selected is None:
        if group_name == "ALL NODES" and not groups:
            selected = node_names
        elif group_name == "UNGROUPED":
            selected = [name for name in node_names if name not in direct_grouped]
        else:
            raise LatencyError("Proxy group was not found")
    if not selected:
        raise LatencyError("Proxy group has no concrete nodes to test")
    return selected


def prepare_temporary_document(document, node_names):
    runtime = dict(document)
    for key in (
        "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
        "external-controller", "external-controller-unix", "external-controller-tls",
        "external-ui", "external-ui-url", "secret", "listeners", "tun",
        "rule-providers", "proxy-providers",
    ):
        runtime.pop(key, None)
    runtime["allow-lan"] = False
    runtime["bind-address"] = "127.0.0.1"
    runtime["mode"] = "rule"
    runtime["log-level"] = "warning"
    dns = runtime.get("dns")
    if isinstance(dns, dict):
        dns = dict(dns)
        dns.pop("listen", None)
        runtime["dns"] = dns
    runtime["proxy-groups"] = [{"name": TEST_GROUP, "type": "select", "proxies": node_names}]
    runtime["rules"] = ["MATCH,DIRECT"]
    profile = runtime.get("profile")
    runtime["profile"] = dict(profile) if isinstance(profile, dict) else {}
    runtime["profile"]["store-selected"] = False
    return runtime


def mihomo_binary():
    override = os.environ.get("MIHOMO_LATENCY_MIHOMO")
    found = override if override else shutil.which("mihomo")
    binary = Path(found) if found else Path("/nonexistent")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise LatencyError("Mihomo is not installed")
    return binary


def temporary_root():
    override = os.environ.get("MIHOMO_LATENCY_RUNTIME")
    if override:
        return Path(override)
    return Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))


def active_controller(state_root: Path, subscription_id: str):
    selection_file = state_root / "selection.json"
    try:
        selection = json.loads(selection_file.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LatencyError("Start Mihomo before running a speed test") from error
    if not isinstance(selection, dict) or selection.get("subscriptionId") != subscription_id:
        raise LatencyError("Start a node from this subscription before running its speed test")
    socket_path = state_root / "runtime" / "controller.sock"
    if not socket_path.is_socket():
        raise LatencyError("The running Mihomo Controller is unavailable")
    return socket_path


def query_json(socket_path: Path, endpoint: str):
    connection = UnixHTTPConnection(socket_path, timeout=TIMEOUT_MS / 1000 + 5)
    try:
        connection.request("GET", endpoint)
        response = connection.getresponse()
        payload = response.read()
    finally:
        connection.close()
    if response.status != 200:
        raise LatencyError(f"Mihomo latency API returned HTTP {response.status}")
    try:
        result = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise LatencyError("Mihomo latency response was invalid") from error
    if not isinstance(result, dict):
        raise LatencyError("Mihomo latency response was not a mapping")
    return result


def query_group(socket_path: Path, group_name: str, test_url: str):
    query = urlencode({"url": test_url, "timeout": TIMEOUT_MS})
    return query_json(socket_path, f"/group/{quote(group_name, safe='')}/delay?{query}")


def query_proxy(socket_path: Path, node_name: str, test_url: str):
    query = urlencode({"url": test_url, "timeout": TIMEOUT_MS})
    try:
        result = query_json(socket_path, f"/proxies/{quote(node_name, safe='')}/delay?{query}")
    except (LatencyError, OSError, http.client.HTTPException):
        return None
    delay = result.get("delay")
    return delay if isinstance(delay, int) and delay > 0 else None


def query_proxies(socket_path: Path, node_names, test_url: str):
    workers = min(MAX_PARALLEL_TESTS, len(node_names))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        delays = executor.map(lambda name: query_proxy(socket_path, name, test_url), node_names)
        return dict(zip(node_names, delays))


def query_delays(socket_path: Path, group_name: str, node_names, test_url: str):
    if group_name not in SYNTHETIC_GROUPS:
        return query_group(socket_path, group_name, test_url)
    return query_proxies(socket_path, node_names, test_url)


def temporary_delays(document, node_names, test_url: str):
    runtime = prepare_temporary_document(document, node_names)
    process = None
    with tempfile.TemporaryDirectory(prefix="fatlj-mihomo-recommend-", dir=temporary_root()) as temporary:
        directory = Path(temporary)
        runtime_config = directory / "config.yaml"
        runtime_config.write_text(
            yaml.safe_dump(runtime, allow_unicode=True, sort_keys=False), encoding="utf-8"
        )
        os.chmod(runtime_config, 0o600)
        for geoip in (Path("/etc/mihomo/Country.mmdb"), Path("/etc/clash/Country.mmdb")):
            if geoip.is_file() and geoip.stat().st_size > 0:
                (directory / "Country.mmdb").symlink_to(geoip)
                break
        socket_path = directory / "controller.sock"
        try:
            process = subprocess.Popen(
                [str(mihomo_binary()), "-d", str(directory), "-f", str(runtime_config),
                 "-ext-ctl-unix", str(socket_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for _ in range(100):
                if socket_path.is_socket():
                    break
                if process.poll() is not None:
                    raise LatencyError("Temporary Mihomo exited before its Controller was ready")
                time.sleep(0.05)
            if not socket_path.is_socket():
                raise LatencyError("Temporary Mihomo Controller did not become ready")
            return query_proxies(socket_path, node_names, test_url)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def recommend_all(data_dir: Path, test_url: str):
    recommendations = []
    if not data_dir.is_dir():
        return recommendations
    entries = [entry for entry in data_dir.iterdir() if entry.is_dir() and not entry.name.startswith(".")]
    entries.sort(key=lambda entry: entry.stat().st_mtime, reverse=True)
    for entry in entries:
        item = {"subscriptionId": entry.name, "nodesTested": 0, "responsiveCount": 0, "top": []}
        try:
            config = safe_subscription(data_dir, entry.name)
            document = load_document(config)
            nodes = all_proxy_nodes(document)
            item["nodesTested"] = len(nodes)
            delays = temporary_delays(document, [node["name"] for node in nodes], test_url)
            responsive = []
            for node in nodes:
                delay = delays.get(node["name"])
                if isinstance(delay, int) and delay > 0:
                    responsive.append({**node, "status": "ok", "delayMs": delay})
            responsive.sort(key=lambda result: (result["delayMs"], result["name"]))
            item["responsiveCount"] = len(responsive)
            item["top"] = responsive[:3]
            if not responsive:
                item["error"] = "No responsive nodes"
        except (LatencyError, OSError, subprocess.SubprocessError, yaml.YAMLError) as error:
            item["error"] = str(error)
        recommendations.append(item)
    return recommendations


def main():
    try:
        request = json.loads(sys.stdin.readline())
        if not isinstance(request, dict):
            raise ValueError
    except (json.JSONDecodeError, UnicodeError, ValueError):
        print("Invalid latency request", file=sys.stderr)
        return 1
    mode = request.get("mode", "group")
    subscription_id = request.get("subscriptionId")
    group_name = request.get("groupName")
    test_url = request.get("url", DEFAULT_TEST_URL)
    if not isinstance(test_url, str) or urlsplit(test_url).scheme not in {"http", "https"}:
        print("Latency URL must use HTTP or HTTPS", file=sys.stderr)
        return 1

    data_dir, state_root = plugin_paths()
    try:
        if mode == "recommend":
            json.dump({"mode": "recommend", "url": test_url,
                       "subscriptions": recommend_all(data_dir, test_url)}, sys.stdout,
                      ensure_ascii=False, separators=(",", ":"))
            sys.stdout.write("\n")
            return 0
        if mode != "group" or not isinstance(group_name, str) or not group_name:
            raise LatencyError("Proxy group is required")
        config = safe_subscription(data_dir, subscription_id)
        document = load_document(config)
        names = group_nodes(document, group_name)
        socket_path = active_controller(state_root, subscription_id)
        delays = query_delays(socket_path, group_name, names, test_url)
        results = []
        for name in names:
            delay = delays.get(name)
            if isinstance(delay, int) and delay > 0:
                results.append({"name": name, "status": "ok", "delayMs": delay})
            else:
                results.append({"name": name, "status": "timeout", "delayMs": None})
        json.dump({"subscriptionId": subscription_id, "groupName": group_name,
                   "url": test_url, "results": results}, sys.stdout,
                  ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
    except (LatencyError, OSError, http.client.HTTPException, yaml.YAMLError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    raise SystemExit(main())
