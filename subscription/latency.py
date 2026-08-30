#!/usr/bin/env python3
import concurrent.futures
import http.client
import json
import os
import socket
import sys
from pathlib import Path
from urllib.parse import quote, urlencode, urlsplit

import yaml

DEFAULT_TEST_URL = "https://www.gstatic.com/generate_204"
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


def query_delays(socket_path: Path, group_name: str, node_names, test_url: str):
    if group_name not in SYNTHETIC_GROUPS:
        return query_group(socket_path, group_name, test_url)
    workers = min(MAX_PARALLEL_TESTS, len(node_names))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        delays = executor.map(lambda name: query_proxy(socket_path, name, test_url), node_names)
        return dict(zip(node_names, delays))


def main():
    try:
        request = json.loads(sys.stdin.readline())
        if not isinstance(request, dict):
            raise ValueError
    except (json.JSONDecodeError, UnicodeError, ValueError):
        print("Invalid latency request", file=sys.stderr)
        return 1
    subscription_id = request.get("subscriptionId")
    group_name = request.get("groupName")
    test_url = request.get("url", DEFAULT_TEST_URL)
    if not isinstance(group_name, str) or not group_name:
        print("Proxy group is required", file=sys.stderr)
        return 1
    if not isinstance(test_url, str) or urlsplit(test_url).scheme not in {"http", "https"}:
        print("Latency URL must use HTTP or HTTPS", file=sys.stderr)
        return 1

    data_dir, state_root = plugin_paths()
    try:
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
    raise SystemExit(main())
