#!/usr/bin/env python3
"""Aggregate the per-plugin author manifests into a single registry index.

This repo is a *decentralized* registry: each plugin is registered once (a small
`registry/<id>.json` pointing at the author's self-hosted `manifest.json`), and this
script periodically fetches every manifest and merges them into `plugins/index.json`,
which Fizzy's in-app store reads. It builds nothing and never touches author binaries.

Robustness: a malformed `registry/<id>.json` is a hard error (those land via reviewed
PRs and must be fixed). A manifest that is unreachable or malformed is *skipped* with a
warning, and the plugin's previous entry in `index.json` is retained (last-known-good),
so one author's outage never drops everyone else from the index.

Stdlib only (urllib + json); runs the same locally and in CI. `file://` manifest URLs
work for local testing.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys
import urllib.request
from pathlib import Path

SCHEMA = 1
FETCH_TIMEOUT_S = 20
USER_AGENT = "fizzyedit-plugins-aggregator/1"

# Keys copied from the registry entry into the index plugin object (author-facing metadata).
REGISTRY_META_KEYS = ("id", "name", "description", "author", "homepage", "tags")
# Required keys in a registry/<id>.json entry.
REGISTRY_REQUIRED = ("id", "name", "manifest_url")
# Required keys in each release of an author manifest.
RELEASE_REQUIRED = ("version", "abi_fingerprint", "downloads")


class RegistryError(Exception):
    """A reviewed registry file is malformed — fail the run so the PR author fixes it."""


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def fetch_json(url: str) -> object:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT_S) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_registry_entries(registry_dir: Path) -> list[dict]:
    entries = []
    for path in sorted(registry_dir.glob("*.json")):
        try:
            entry = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            raise RegistryError(f"{path.name}: invalid JSON ({e})") from e
        if not isinstance(entry, dict):
            raise RegistryError(f"{path.name}: must be a JSON object")
        for key in REGISTRY_REQUIRED:
            if not entry.get(key):
                raise RegistryError(f"{path.name}: missing required key '{key}'")
        if entry["id"] != path.stem:
            raise RegistryError(
                f"{path.name}: id '{entry['id']}' must match the filename stem '{path.stem}'"
            )
        entries.append(entry)
    return entries


def validate_manifest(entry_id: str, manifest: object) -> list[dict]:
    """Return the cleaned releases list, or raise ValueError if the manifest is unusable."""
    if not isinstance(manifest, dict):
        raise ValueError("manifest is not a JSON object")
    if manifest.get("id") != entry_id:
        raise ValueError(f"manifest id '{manifest.get('id')}' != registered id '{entry_id}'")
    releases = manifest.get("releases")
    if not isinstance(releases, list):
        raise ValueError("manifest has no 'releases' array")

    cleaned = []
    for rel in releases:
        if not isinstance(rel, dict):
            raise ValueError("a release is not an object")
        for key in RELEASE_REQUIRED:
            if key not in rel:
                raise ValueError(f"release {rel.get('version', '?')} missing '{key}'")
        downloads = rel["downloads"]
        if not isinstance(downloads, dict) or not downloads:
            raise ValueError(f"release {rel['version']} has no downloads")
        for os_arch, dl in downloads.items():
            if not isinstance(dl, dict) or not dl.get("url") or not dl.get("sha256"):
                raise ValueError(f"release {rel['version']} download '{os_arch}' needs url + sha256")
        cleaned.append(rel)
    return cleaned


def plugin_entry(entry: dict, releases: list[dict]) -> dict:
    out = {k: entry[k] for k in REGISTRY_META_KEYS if k in entry}
    out["releases"] = releases
    return out


def build_index(registry_dir: Path, previous: dict) -> dict:
    prev_by_id = {p["id"]: p for p in previous.get("plugins", []) if isinstance(p, dict) and "id" in p}
    plugins = []
    for entry in load_registry_entries(registry_dir):
        eid = entry["id"]
        try:
            manifest = fetch_json(entry["manifest_url"])
            releases = validate_manifest(eid, manifest)
            plugins.append(plugin_entry(entry, releases))
            log(f"  ok    {eid}: {len(releases)} release(s)")
        except Exception as e:  # noqa: BLE001 — any fetch/parse problem is non-fatal per plugin
            if eid in prev_by_id:
                # Keep last-known-good releases, refresh the author-facing metadata.
                plugins.append(plugin_entry(entry, prev_by_id[eid].get("releases", [])))
                log(f"  warn  {eid}: {e} — kept last-known-good")
            else:
                log(f"  skip  {eid}: {e} — no prior entry to fall back on")
    plugins.sort(key=lambda p: p["id"])
    return {
        "schema": SCHEMA,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "plugins": plugins,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent),
                    help="repo root (default: parent of scripts/)")
    ap.add_argument("--check", action="store_true",
                    help="validate registry files (and fetch manifests) without writing index.json")
    args = ap.parse_args()

    root = Path(args.root)
    registry_dir = root / "registry"
    out_path = root / "plugins" / "index.json"

    if not registry_dir.is_dir():
        log(f"no registry/ directory at {registry_dir}")
        return 1

    previous = {}
    if out_path.exists():
        try:
            previous = json.loads(out_path.read_text())
        except json.JSONDecodeError:
            log(f"warning: existing {out_path} is not valid JSON; ignoring for fallback")

    log("aggregating registry…")
    try:
        index = build_index(registry_dir, previous)
    except RegistryError as e:
        log(f"error: {e}")
        return 1

    if args.check:
        log(f"check ok: {len(index['plugins'])} plugin(s) would be published")
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(index, indent=2) + "\n")
    log(f"wrote {out_path} ({len(index['plugins'])} plugin(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
