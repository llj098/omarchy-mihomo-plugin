#!/usr/bin/env python3
import copy
import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("mihomo_control", ROOT / "subscription/control.py")
control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(control)

source = {
    "mixed-port": 7890,
    "port": 8080,
    "socks-port": 1080,
    "allow-lan": True,
    "bind-address": "0.0.0.0",
    "external-controller": "127.0.0.1:9090",
    "secret": "controller-secret",
    "tun": {"enable": True},
    "listeners": [{"name": "unsafe-listener"}],
    "dns": {"enable": True, "listen": "0.0.0.0:1053", "nameserver": ["1.1.1.1"]},
    "proxies": [
        {"name": "Node A", "type": "vless", "server": "secret-a.invalid", "uuid": "secret-a"},
        {"name": "节点 B", "type": "hysteria2", "server": "secret-b.invalid", "password": "secret-b"},
    ],
    "proxy-groups": [{"name": "PROXY", "type": "select", "proxies": ["Node A", "节点 B"]}],
    "rule-providers": {"remote": {"type": "http", "url": "https://secret.invalid/rules"}},
    "rules": ["MATCH,PROXY"],
}
original = copy.deepcopy(source)
runtime, node_type = control.prepare_runtime_config(source, "节点 B", 7891)

assert source == original
assert node_type == "hysteria2"
assert runtime["mixed-port"] == 7891
assert runtime["allow-lan"] is False
assert runtime["bind-address"] == "127.0.0.1"
assert runtime["mode"] == "rule"
assert runtime["log-level"] == "warning"
assert runtime["rules"] == ["MATCH,__FATLJ_ACTIVE__"]
assert runtime["proxy-groups"][-1] == {
    "name": "__FATLJ_ACTIVE__",
    "type": "select",
    "proxies": ["节点 B"],
}
assert runtime["dns"] == {"enable": True, "nameserver": ["1.1.1.1"]}
for removed in (
    "port",
    "socks-port",
    "external-controller",
    "secret",
    "tun",
    "listeners",
    "rule-providers",
):
    assert removed not in runtime
assert runtime["proxies"] == original["proxies"]
assert runtime["profile"]["store-selected"] is False

try:
    control.prepare_runtime_config(source, "Missing", 7891)
except control.ControlError:
    pass
else:
    raise AssertionError("missing node was accepted")

duplicate = copy.deepcopy(source)
duplicate["proxies"].append(copy.deepcopy(duplicate["proxies"][0]))
try:
    control.prepare_runtime_config(duplicate, "Node A", 7891)
except control.ControlError:
    pass
else:
    raise AssertionError("duplicate node name was accepted")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    entry = root / "safe-id"
    entry.mkdir()
    (entry / "config.yaml").write_text("proxies: []\n", encoding="utf-8")
    assert control.subscription_config(root, "safe-id") == entry / "config.yaml"
    for unsafe in ("", ".", "..", "../escape", "a/b"):
        try:
            control.subscription_config(root, unsafe)
        except control.ControlError:
            pass
        else:
            raise AssertionError(f"unsafe subscription id was accepted: {unsafe!r}")

print("control_tests=ok force_selected_node=1 listener_sanitization=1 traversal_rejected=1")
