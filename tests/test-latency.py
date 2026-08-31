#!/usr/bin/env python3
import importlib.util
import json
import socket
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("mihomo_latency", ROOT / "subscription/latency.py")
latency = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(latency)

document = {
    "mixed-port": 7890,
    "dns": {"enable": True, "listen": "0.0.0.0:1053"},
    "proxies": [
        {"name": "Node A", "type": "vless", "server": "a.invalid"},
        {"name": "Node B", "type": "hysteria2", "server": "b.invalid"},
        {"name": "Node C", "type": "trojan", "server": "c.invalid"},
    ],
    "proxy-groups": [
        {"name": "PROXY", "type": "select", "proxies": ["Node A", "Node B"]},
        {"name": "FINAL", "type": "select", "proxies": ["PROXY", "DIRECT"]},
    ],
}
assert latency.all_proxy_nodes(document) == [
    {"name": "Node A", "type": "vless"},
    {"name": "Node B", "type": "hysteria2"},
    {"name": "Node C", "type": "trojan"},
]
assert latency.group_nodes(document, "PROXY") == ["Node A", "Node B"]
assert latency.group_nodes(document, "UNGROUPED") == ["Node C"]
try:
    latency.group_nodes(document, "FINAL")
except latency.LatencyError:
    pass
else:
    raise AssertionError("group without concrete nodes was accepted")

no_groups = {"proxies": document["proxies"]}
assert latency.group_nodes(no_groups, "ALL NODES") == ["Node A", "Node B", "Node C"]

with tempfile.TemporaryDirectory() as temporary:
    state_root = Path(temporary)
    runtime = state_root / "runtime"
    runtime.mkdir()
    controller = runtime / "controller.sock"
    (state_root / "selection.json").write_text(
        json.dumps({"subscriptionId": "active-sub"}), encoding="utf-8"
    )
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(controller))
        assert latency.active_controller(state_root, "active-sub") == controller
        try:
            latency.active_controller(state_root, "other-sub")
        except latency.LatencyError as error:
            assert "this subscription" in str(error)
        else:
            raise AssertionError("inactive subscription was allowed to use the main Controller")

original_query_group = latency.query_group
original_query_proxy = latency.query_proxy
try:
    group_calls = []
    latency.query_group = lambda socket_path, group_name, test_url: group_calls.append(
        (socket_path, group_name, test_url)
    ) or {"Node A": 12, "Node B": 34}
    assert latency.query_delays(Path("/tmp/controller.sock"), "PROXY", ["Node A", "Node B"], "https://test") == {
        "Node A": 12, "Node B": 34
    }
    assert group_calls == [(Path("/tmp/controller.sock"), "PROXY", "https://test")]

    latency.query_proxy = lambda _socket, name, _url: {"Node A": 56, "Node C": None}[name]
    assert latency.query_delays(
        Path("/tmp/controller.sock"), "UNGROUPED", ["Node A", "Node C"], "https://test"
    ) == {"Node A": 56, "Node C": None}
finally:
    latency.query_group = original_query_group
    latency.query_proxy = original_query_proxy

prepared = latency.prepare_temporary_document(document, ["Node A", "Node B", "Node C"])
assert prepared["proxy-groups"] == [{
    "name": latency.TEST_GROUP,
    "type": "select",
    "proxies": ["Node A", "Node B", "Node C"],
}]
assert prepared["rules"] == ["MATCH,DIRECT"]
assert prepared["allow-lan"] is False
assert prepared["bind-address"] == "127.0.0.1"
for removed in ("mixed-port", "proxy-providers", "rule-providers", "external-controller", "tun"):
    assert removed not in prepared

with tempfile.TemporaryDirectory() as temporary:
    data_dir = Path(temporary)
    first = data_dir / "first-sub"
    second = data_dir / "second-sub"
    first.mkdir()
    second.mkdir()
    (first / "config.yaml").write_text(
        "proxies:\n"
        "  - {name: Fast, type: vless, server: fast.invalid}\n"
        "  - {name: Slow, type: trojan, server: slow.invalid}\n"
        "  - {name: Mid, type: ss, server: mid.invalid}\n"
        "  - {name: Faster, type: hysteria2, server: faster.invalid}\n",
        encoding="utf-8",
    )
    (second / "config.yaml").write_text("proxies: []\n", encoding="utf-8")
    original_temporary_delays = latency.temporary_delays
    try:
        latency.temporary_delays = lambda _document, _names, _url: {
            "Fast": 20, "Slow": 90, "Mid": None, "Faster": 10
        }
        result = latency.recommend_all(data_dir, "https://test")
    finally:
        latency.temporary_delays = original_temporary_delays
    by_id = {item["subscriptionId"]: item for item in result}
    assert [item["name"] for item in by_id["first-sub"]["top"]] == ["Faster", "Fast", "Slow"]
    assert by_id["first-sub"]["responsiveCount"] == 3
    assert by_id["second-sub"]["top"] == []
    assert "inline proxy" in by_id["second-sub"]["error"]

print("latency_tests=ok group_members=1 active_main_controller=1 native_group_api=1 temporary_recommend_mihomo=1 top3_per_subscription=1")
