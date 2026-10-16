#!/usr/bin/env bash
# Build cumulative Sparkle release notes: the new version's notes on top, followed by notes carried forward
# from earlier releases, deduplicated by version and capped at SCONEOS_RELEASE_NOTES_MAX_VERSIONS (default 10).
#
# Sparkle 2 only renders the <description> of the single winning appcast <item>, so a user who skipped versions
# only sees everything in between if each new item's description already contains it.
#
# History inputs (any order, any number):
#   *.xml   Sparkle appcast; each item's description is split on its <h3> version headings, and a headerless
#           description is attributed to the item's sparkle:shortVersionString.
#   *.json  GitHub Releases API array (tag_name/tagName + body); Markdown bodies are formatted with
#           format-release-notes.sh, keeping only top-level bullets. Used only for versions no appcast describes.
# Earlier inputs win when two sources of the same kind describe the same version.
#
# Usage:
#   ./scripts/cumulative-release-notes.sh <version> <new-notes.html> [history.xml|history.json ...]
set -euo pipefail

VERSION="${1:?cumulative-release-notes: version is required (arg 1)}"
NEW_NOTES="${2:?cumulative-release-notes: new notes HTML file is required (arg 2)}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 - "$SCRIPT_DIR/format-release-notes.sh" "$VERSION" "$NEW_NOTES" "$@" <<'PY'
import html
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

format_script, version, new_notes_path, *history_paths = sys.argv[1:]
max_versions = int(os.environ.get("SCONEOS_RELEASE_NOTES_MAX_VERSIONS", "10"))

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
TOP_HEADING_STYLE = "margin: 0 0 6px 0; font-size: 13px;"
PREVIOUS_HEADING_STYLE = "margin: 14px 0 6px 0; font-size: 13px; opacity: 0.75;"
LI_STYLE = "margin-bottom: 6px; line-height: 1.45;"
H3_RE = re.compile(r"<h3\b[^>]*>(.*?)</h3>", re.IGNORECASE | re.DOTALL)
PLACEHOLDER_RE = re.compile(r"^\s*(?:<p\b[^>]*>)?\s*Release\s+v?[\d.]+\s*(?:</p>)?\s*$", re.IGNORECASE)


def normalize_version(text: str) -> str:
    text = html.unescape(re.sub(r"<[^>]+>", "", text)).strip()
    return re.sub(r"^(?:version\s+|v)", "", text, flags=re.IGNORECASE).strip()


def version_key(v: str):
    return tuple(int(n) for n in re.findall(r"\d+", v))


def normalize_body(body: str) -> str:
    body = re.sub(r"<li\s*>", f'<li style="{LI_STYLE}">', body.strip(), flags=re.IGNORECASE)
    return "" if PLACEHOLDER_RE.match(body) else body


def split_description(description: str, fallback_version: str):
    parts = H3_RE.split(description)
    sections = []
    leading = parts[0].strip()
    if leading and fallback_version:
        sections.append((fallback_version, leading))
    for i in range(1, len(parts) - 1, 2):
        sections.append((normalize_version(parts[i]), parts[i + 1]))
    return sections


def appcast_sections(path: str):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as err:
        print(f"cumulative-release-notes: skipping unreadable appcast {path}: {err}", file=sys.stderr)
        return []
    sections = []
    for item in root.iter("item"):
        description = item.findtext("description") or ""
        short_version = item.findtext(f"{SPARKLE_NS}shortVersionString") or item.findtext("title") or ""
        sections.extend(split_description(description, normalize_version(short_version)))
    return sections


def top_level_bullets(markdown: str) -> str:
    # Release bodies are developer-facing; nested detail would bloat every future update dialog.
    kept = []
    in_nested = False
    for line in markdown.splitlines():
        if re.match(r"^\s+[-*]\s", line):
            in_nested = True
            if kept:
                kept[-1] = re.sub(r":\s*$", "", kept[-1])
            continue
        if in_nested and re.match(r"^\s+\S", line):
            continue
        in_nested = False
        kept.append(line)
    return "\n".join(kept)


def release_sections(path: str):
    try:
        with open(path, encoding="utf-8") as fh:
            releases = json.load(fh)
    except (OSError, ValueError) as err:
        print(f"cumulative-release-notes: skipping unreadable releases JSON {path}: {err}", file=sys.stderr)
        return []
    sections = []
    for release in releases:
        if release.get("draft") or release.get("isDraft"):
            continue
        tag = normalize_version(release.get("tag_name") or release.get("tagName") or "")
        body = (release.get("body") or "").strip()
        if not tag or not body or PLACEHOLDER_RE.match(body):
            continue
        formatted = subprocess.run(
            [format_script, tag],
            env={**os.environ, "SCONEOS_RELEASE_NOTES": top_level_bullets(body)},
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        sections.append((tag, formatted))
    return sections


with open(new_notes_path, encoding="utf-8") as fh:
    new_body = fh.read().strip()

notes = {}
for collect, suffix in ((appcast_sections, ".xml"), (release_sections, ".json")):
    for path in history_paths:
        if not path.lower().endswith(suffix):
            continue
        for v, body in collect(path):
            body = normalize_body(body)
            if v and body and v != version and v not in notes:
                notes[v] = body

previous = sorted(notes, key=version_key, reverse=True)[: max(max_versions - 1, 0)]

out = [f'<h3 style="{TOP_HEADING_STYLE}">{html.escape(version)}</h3>', new_body]
for v in previous:
    out.append(f'<h3 style="{PREVIOUS_HEADING_STYLE}">{html.escape(v)}</h3>')
    out.append(notes[v])
print("\n".join(out))
PY
