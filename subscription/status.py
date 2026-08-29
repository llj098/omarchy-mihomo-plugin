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
    script_dir = Path(__file__).resolve().parent
    default = script_dir.parent / "data" / "subscriptions"
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


def parse_nodes(config: Path):
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
    return nodes, provider_count


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
    provider_count = 0
    parse_error = False
    try:
        all_nodes, provider_count = parse_nodes(config)
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
        "parseError": parse_error,
        "nodes": visible_nodes,
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
