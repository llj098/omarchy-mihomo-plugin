#!/usr/bin/env python3
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

try:
    import yaml
except ImportError:
    print("python-yaml is required to parse Mihomo subscriptions", file=sys.stderr)
    raise SystemExit(1)

MAX_CONFIG_BYTES = 8 * 1024 * 1024
MAX_NODES_PER_SUBSCRIPTION = 500
MAX_YAML_ALIASES = 100
BUILTIN_MEMBERS = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"}


class LimitedSafeLoader(yaml.SafeLoader):
    """SafeLoader with a bound on alias expansion."""

    def __init__(self, stream):
        super().__init__(stream)
        self.alias_count = 0

    def compose_node(self, parent, index):
        if self.check_event(yaml.AliasEvent):
            self.alias_count += 1
            if self.alias_count > MAX_YAML_ALIASES:
                raise yaml.YAMLError("too many YAML aliases")
        return super().compose_node(parent, index)


def data_directory() -> Path:
    default = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "fatlj.mihomo/subscriptions"
    if os.environ.get("MIHOMO_SUBSCRIPTION_TESTING") == "1":
        override = os.environ.get("MIHOMO_SUBSCRIPTION_DATA")
        if override:
            return Path(override)
    return default


def safe_url_label(source: str) -> str:
    try:
        parsed = urlsplit(source)
        authority = parsed.netloc.rsplit("@", 1)[-1]
        return authority or "Remote subscription"
    except ValueError:
        return "Remote subscription"


def parse_subscription(config: Path):
    if config.stat().st_size > MAX_CONFIG_BYTES:
        raise ValueError("configuration exceeds size limit")
    with config.open("r", encoding="utf-8") as stream:
        document = yaml.load(stream, Loader=LimitedSafeLoader)
    if not isinstance(document, dict):
        raise ValueError("configuration root is not a mapping")

    raw_nodes = document.get("proxies", [])
    if raw_nodes is None:
        raw_nodes = []
    if not isinstance(raw_nodes, list):
        raise ValueError("proxies is not a list")

    nodes = []
    for raw in raw_nodes:
        if not isinstance(raw, dict):
            continue
        name = raw.get("name")
        if not isinstance(name, str) or not name:
            continue
        node_type = raw.get("type")
        if not isinstance(node_type, str) or not node_type:
            node_type = "unknown"
        nodes.append({"name": name, "type": node_type})

    providers = document.get("proxy-providers", {})
    provider_count = len(providers) if isinstance(providers, dict) else 0
    raw_groups = document.get("proxy-groups", [])
    if raw_groups is None:
        raw_groups = []
    if not isinstance(raw_groups, list):
        raise ValueError("proxy-groups is not a list")

    visible_nodes = nodes[:MAX_NODES_PER_SUBSCRIPTION]
    node_by_name = {node["name"]: node for node in visible_nodes}
    all_node_names = {node["name"] for node in nodes}
    group_names = {
        group.get("name") for group in raw_groups
        if isinstance(group, dict) and isinstance(group.get("name"), str) and group.get("name")
    }
    directly_grouped = set()
    groups = []
    for raw_group in raw_groups:
        if not isinstance(raw_group, dict):
            continue
        name = raw_group.get("name")
        if not isinstance(name, str) or not name:
            continue
        group_type = raw_group.get("type")
        if not isinstance(group_type, str) or not group_type:
            group_type = "unknown"
        raw_members = raw_group.get("proxies", [])
        if not isinstance(raw_members, list):
            raw_members = []
        members = []
        direct_node_count = 0
        truncated = 0
        for member in raw_members:
            if not isinstance(member, str) or not member:
                continue
            if member in all_node_names:
                directly_grouped.add(member)
                direct_node_count += 1
                node = node_by_name.get(member)
                if node is None:
                    truncated += 1
                else:
                    members.append({"kind": "proxy", **node})
            elif member in group_names:
                members.append({"kind": "group", "name": member, "type": "group ref"})
            elif member.upper() in BUILTIN_MEMBERS:
                members.append({"kind": "builtin", "name": member, "type": "builtin"})
            else:
                members.append({"kind": "unknown", "name": member, "type": "unknown"})
        uses = raw_group.get("use", [])
        if isinstance(uses, list):
            for provider in uses:
                if isinstance(provider, str) and provider:
                    members.append({"kind": "provider", "name": provider, "type": "provider"})
        groups.append({
            "name": name,
            "type": group_type,
            "synthetic": False,
            "memberCount": len(members) + truncated,
            "directNodeCount": direct_node_count,
            "membersTruncated": truncated,
            "members": members,
        })

    if not groups:
        groups.append({
            "name": "ALL NODES",
            "type": "all",
            "synthetic": True,
            "memberCount": len(nodes),
            "directNodeCount": len(nodes),
            "membersTruncated": max(0, len(nodes) - len(visible_nodes)),
            "members": [{"kind": "proxy", **node} for node in visible_nodes],
        })
    else:
        ungrouped = [node for node in visible_nodes if node["name"] not in directly_grouped]
        ungrouped_count = sum(node["name"] not in directly_grouped for node in nodes)
        if ungrouped_count:
            groups.append({
                "name": "UNGROUPED",
                "type": "all",
                "synthetic": True,
                "memberCount": ungrouped_count,
                "directNodeCount": ungrouped_count,
                "membersTruncated": max(0, ungrouped_count - len(ungrouped)),
                "members": [{"kind": "proxy", **node} for node in ungrouped],
            })
    return nodes, groups, provider_count


def subscription_entry(directory: Path):
    config = directory / "config.yaml"
    if not config.is_file() or config.stat().st_size == 0:
        return None

    kind = "local"
    label = "Local subscription"
    source_file = directory / "source.url"
    if source_file.is_file():
        kind = "url"
        try:
            label = safe_url_label(source_file.read_text(encoding="utf-8").rstrip("\n"))
        except (OSError, UnicodeError):
            label = "Remote subscription"

    stat = config.stat()
    all_nodes = []
    groups = []
    provider_count = 0
    parse_error = False
    try:
        all_nodes, groups, provider_count = parse_subscription(config)
    except (OSError, UnicodeError, ValueError, yaml.YAMLError):
        parse_error = True

    visible_nodes = all_nodes[:MAX_NODES_PER_SUBSCRIPTION]
    return {
        "id": directory.name,
        "kind": kind,
        "label": label,
        "path": str(config),
        "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
        "bytes": stat.st_size,
        "modifiedEpoch": int(stat.st_mtime),
        "nodeCount": len(all_nodes),
        "nodesTruncated": max(0, len(all_nodes) - len(visible_nodes)),
        "providerCount": provider_count,
        "groupCount": len(groups),
        "parseError": parse_error,
        "nodes": visible_nodes,
        "groups": groups,
    }


def main():
    root = data_directory()
    subscriptions = []
    if root.is_dir():
        for directory in root.iterdir():
            if not directory.is_dir() or directory.name.startswith("."):
                continue
            entry = subscription_entry(directory)
            if entry is not None:
                subscriptions.append(entry)
    subscriptions.sort(key=lambda entry: entry["modifiedEpoch"], reverse=True)
    result = {
        "count": len(subscriptions),
        "hasSubscriptions": bool(subscriptions),
        "nodeCount": sum(entry["nodeCount"] for entry in subscriptions),
        "providerCount": sum(entry["providerCount"] for entry in subscriptions),
        "subscriptions": subscriptions,
    }
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
