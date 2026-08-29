#!/usr/bin/env python3
import importlib.util
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
assert latency.group_nodes(document, "PROXY") == ["Node A", "Node B"]
assert latency.group_nodes(document, "UNGROUPED") == ["Node C"]
try:
    latency.group_nodes(document, "FINAL")
except latency.LatencyError:
    pass
else:
    raise AssertionError("group without concrete nodes was accepted")

runtime = latency.prepare_document(document, ["Node A", "Node B"])
assert "mixed-port" not in runtime
assert runtime["allow-lan"] is False
assert runtime["bind-address"] == "127.0.0.1"
assert "listen" not in runtime["dns"]
assert runtime["rules"] == ["MATCH,DIRECT"]
test_group = [group for group in runtime["proxy-groups"] if group.get("name") == latency.TEST_GROUP]
assert test_group == [{"name": latency.TEST_GROUP, "type": "select", "proxies": ["Node A", "Node B"]}]

no_groups = {"proxies": document["proxies"]}
assert latency.group_nodes(no_groups, "ALL NODES") == ["Node A", "Node B", "Node C"]

print("latency_tests=ok group_members=1 nested_group_rejected=1 isolated_config=1")
