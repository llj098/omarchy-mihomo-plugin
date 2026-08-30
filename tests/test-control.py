#!/usr/bin/env python3
import copy
import importlib.util
import os
import socket
import stat
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

lan_runtime, _ = control.prepare_runtime_config(source, "Node A", 8123, True)
assert lan_runtime["mixed-port"] == 8123
assert lan_runtime["allow-lan"] is True
assert lan_runtime["bind-address"] == "0.0.0.0"
assert control.validate_settings({"port": 7890, "allowLan": False}) == {
    "port": 7890, "allowLan": False
}
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied_socket:
    occupied_socket.bind(("127.0.0.1", 0))
    occupied_port = occupied_socket.getsockname()[1]
    assert control.port_is_available(occupied_port) is False
assert control.port_is_available(occupied_port) is True

for invalid_settings in (
    {"port": 1023, "allowLan": False},
    {"port": 65536, "allowLan": False},
    {"port": "7891", "allowLan": False},
    {"port": True, "allowLan": False},
    {"port": 7891, "allowLan": 1},
):
    try:
        control.validate_settings(invalid_settings)
    except control.ControlError:
        pass
    else:
        raise AssertionError(f"invalid settings were accepted: {invalid_settings!r}")

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

with tempfile.TemporaryDirectory() as temporary:
    state_root = Path(temporary) / "state"
    state_root.mkdir(mode=0o700)
    assert control.load_settings(state_root) == {"port": 7891, "allowLan": False}
    control.atomic_json(state_root / "settings.json", {"port": 8123, "allowLan": True})
    assert control.load_settings(state_root) == {"port": 8123, "allowLan": True}
    assert stat.S_IMODE((state_root / "settings.json").stat().st_mode) == 0o600
    assert not list(state_root.glob("settings.json.*"))

with tempfile.TemporaryDirectory() as temporary:
    state_root = Path(temporary) / "state"
    state_root.mkdir(mode=0o700)
    previous = {
        "MIHOMO_CONTROL_TESTING": os.environ.get("MIHOMO_CONTROL_TESTING"),
        "MIHOMO_CONTROL_STATE": os.environ.get("MIHOMO_CONTROL_STATE"),
    }
    original_unit_properties = control.unit_properties
    original_read_request = control.read_request
    original_start = control.start
    original_port_is_available = control.port_is_available
    original_port_is_open = control.port_is_open
    try:
        os.environ["MIHOMO_CONTROL_TESTING"] = "1"
        os.environ["MIHOMO_CONTROL_STATE"] = str(state_root)
        control.port_is_available = lambda _port, _allow_lan=False: True
        control.read_request = lambda _message: {"port": 9001, "allowLan": True}
        control.unit_properties = lambda: {
            "LoadState": "not-found", "ActiveState": "inactive", "SubState": "dead", "MainPID": "0"
        }
        stopped_result = control.apply_settings()
        assert stopped_result["restarted"] is False
        assert control.load_settings(state_root) == {"port": 9001, "allowLan": True}

        control.atomic_json(state_root / "selection.json", {
            "subscriptionId": "safe-id", "nodeName": "Node A", "port": 9001, "allowLan": True
        })
        restart_requests = []
        control.read_request = lambda _message: {"port": 9002, "allowLan": False}
        control.unit_properties = lambda: {
            "LoadState": "loaded", "ActiveState": "active", "SubState": "running", "MainPID": "42"
        }
        control.start = lambda request: restart_requests.append(request) or {
            "ok": True, "running": True, "subscriptionId": request["subscriptionId"],
            "nodeName": request["nodeName"]
        }
        running_result = control.apply_settings()
        assert restart_requests == [{"subscriptionId": "safe-id", "nodeName": "Node A"}]
        assert running_result["restarted"] is True
        assert running_result["settings"] == {"port": 9002, "allowLan": False}
        assert control.load_settings(state_root) == {"port": 9002, "allowLan": False}

        control.atomic_json(state_root / "selection.json", {
            "subscriptionId": "safe-id", "nodeName": "Node A", "port": 9002, "allowLan": False
        })
        calls_before_conflict = len(restart_requests)
        control.read_request = lambda _message: {"port": 7890, "allowLan": False}
        control.port_is_available = lambda port, _allow_lan=False: port != 7890
        try:
            control.apply_settings()
        except control.ControlError as error:
            assert "Port 7890 is already in use" in str(error)
            assert "still running on port 9002" in str(error)
        else:
            raise AssertionError("occupied apply port was accepted")
        assert len(restart_requests) == calls_before_conflict
        assert control.load_settings(state_root) == {"port": 9002, "allowLan": False}

        control.port_is_available = lambda _port, _allow_lan=False: True
        control.read_request = lambda _message: {"port": 9003, "allowLan": True}
        active = {"value": True}
        control.unit_properties = lambda: {
            "LoadState": "loaded" if active["value"] else "not-found",
            "ActiveState": "active" if active["value"] else "inactive",
            "SubState": "running" if active["value"] else "dead",
            "MainPID": "42" if active["value"] else "0",
        }
        control.port_is_open = lambda port: active["value"] and port == 9002
        rollback_requests = []

        def fail_then_restore(request):
            rollback_requests.append((request, control.load_settings(state_root)))
            if len(rollback_requests) == 1:
                active["value"] = False
                raise control.ControlError("Mihomo did not start on port 9003")
            active["value"] = True
            return {"ok": True, "running": True, "port": 9002}

        control.start = fail_then_restore
        try:
            control.apply_settings()
        except control.ControlError as error:
            assert "Previous settings were restored" in str(error)
            assert "running on port 9002" in str(error)
        else:
            raise AssertionError("failed apply did not report the rollback")
        assert rollback_requests == [
            ({"subscriptionId": "safe-id", "nodeName": "Node A"}, {"port": 9003, "allowLan": True}),
            ({"subscriptionId": "safe-id", "nodeName": "Node A"}, {"port": 9002, "allowLan": False}),
        ]
        assert active["value"] is True
        assert control.load_settings(state_root) == {"port": 9002, "allowLan": False}
    finally:
        control.unit_properties = original_unit_properties
        control.read_request = original_read_request
        control.start = original_start
        control.port_is_available = original_port_is_available
        control.port_is_open = original_port_is_open
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

print("control_tests=ok settings_persistence=1 port_7890=1 occupied_port_guard=1 apply_rollback=1 traversal_rejected=1")
