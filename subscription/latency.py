#!/usr/bin/env python3
import http.client
import json
import os
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
TEST_GROUP = "__FATLJ_TEST__"
TIMEOUT_MS = 5000
MAX_CONFIG_BYTES = 8 * 1024 * 1024


class LatencyError(Exception):
    pass


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path, timeout=10):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def plugin_paths():
    script_dir = Path(__file__).resolve().parent
    data_dir = script_dir.parent / "data" / "subscriptions"
    if os.environ.get("MIHOMO_LATENCY_TESTING") == "1" and os.environ.get("MIHOMO_SUBSCRIPTION_DATA"):
        data_dir = Path(os.environ["MIHOMO_SUBSCRIPTION_DATA"])
    runtime_root = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    return data_dir, runtime_root


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


def prepare_document(document, node_names):
    runtime = dict(document)
    for key in (
        "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
        "external-controller", "external-controller-unix", "external-controller-tls",
        "external-ui", "external-ui-url", "secret", "listeners", "tun", "rule-providers",
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
    groups = runtime.get("proxy-groups", [])
    if not isinstance(groups, list):
        groups = []
    groups = [group for group in groups if not (isinstance(group, dict) and group.get("name") == TEST_GROUP)]
    groups.append({"name": TEST_GROUP, "type": "select", "proxies": node_names})
    runtime["proxy-groups"] = groups
    runtime["rules"] = ["MATCH,DIRECT"]
    return runtime


def query_group(socket_path, test_url):
    query = urlencode({"url": test_url, "timeout": TIMEOUT_MS})
    connection = UnixHTTPConnection(str(socket_path), timeout=TIMEOUT_MS / 1000 + 5)
    try:
        connection.request("GET", f"/group/{quote(TEST_GROUP, safe='')}/delay?{query}")
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

    data_dir, runtime_root = plugin_paths()
    process = None
    try:
        config = safe_subscription(data_dir, subscription_id)
        document = load_document(config)
        names = group_nodes(document, group_name)
        runtime = prepare_document(document, names)
        with tempfile.TemporaryDirectory(prefix="fatlj-mihomo-latency-", dir=runtime_root) as temporary:
            directory = Path(temporary)
            runtime_config = directory / "config.yaml"
            runtime_config.write_text(yaml.safe_dump(runtime, allow_unicode=True, sort_keys=False), encoding="utf-8")
            os.chmod(runtime_config, 0o600)
            for geoip in (Path("/etc/mihomo/Country.mmdb"), Path("/etc/clash/Country.mmdb")):
                if geoip.is_file() and geoip.stat().st_size > 0:
                    (directory / "Country.mmdb").symlink_to(geoip)
                    break
            socket_path = directory / "controller.sock"
            process = subprocess.Popen(
                ["/usr/bin/mihomo", "-d", str(directory), "-f", str(runtime_config),
                 "-ext-ctl-unix", str(socket_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for _ in range(100):
                if socket_path.is_socket():
                    break
                if process.poll() is not None:
                    raise LatencyError("Temporary Mihomo exited before its controller was ready")
                time.sleep(0.05)
            if not socket_path.is_socket():
                raise LatencyError("Temporary Mihomo controller did not become ready")
            delays = query_group(socket_path, test_url)
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
    except (LatencyError, OSError, subprocess.SubprocessError, yaml.YAMLError) as error:
        print(str(error), file=sys.stderr)
        return 1
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    raise SystemExit(main())
