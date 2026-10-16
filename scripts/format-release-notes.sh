#!/usr/bin/env bash
# Format Markdown release notes into clean, scannable HTML suitable for Sparkle's WebKit view.
#
# Converts Markdown release notes (`# Release notes`, `# Highlights`, `# What changed?`, `# Summary`, or `# Overview`)
# into styled HTML (`<ul><li style="margin-bottom: 6px; line-height: 1.45;">...</li></ul>`,
# `<code>...</code>`, `<strong>...</strong>`) for embedding inside `<description><![CDATA[...]]></description>`.
#
# Usage:
#   SCONEOS_RELEASE_NOTES="..." ./scripts/format-release-notes.sh <version>
set -euo pipefail

VERSION="${1:?format-release-notes: version is required (arg 1)}"

python3 - "$VERSION" <<'PY'
import html
import os
import re
import sys

version = sys.argv[1]
raw = os.environ.get("SCONEOS_RELEASE_NOTES", "").strip()

# Strip HTML comments (e.g. CURSOR_AGENT_PR_BODY markers)
raw = re.sub(r"<!--[\s\S]*?-->", "", raw).strip()

# If full PR body was passed, prefer # Release notes -> # Highlights -> # What changed? -> # Summary -> # Overview
def extract_section(text: str, heading: str) -> str:
    lines = text.splitlines()
    in_section = False
    collected = []
    heading_re = re.compile(rf"^#+\s*{re.escape(heading)}\s*$", re.IGNORECASE)
    any_heading_re = re.compile(r"^#+\s+\S")
    hr_re = re.compile(r"^-+\s*$")
    for line in lines:
        if heading_re.match(line.strip()):
            in_section = True
            continue
        if in_section:
            if any_heading_re.match(line.strip()) or hr_re.match(line.strip()):
                break
            collected.append(line)
    # Filter out bare '-' placeholder lines
    cleaned = [l for l in collected if not re.match(r"^\s*[-*]\s*$", l)]
    return "\n".join(cleaned).strip()

for section_name in ("Release notes", "Highlights", "What changed?", "Summary", "Overview"):
    extracted = extract_section(raw, section_name)
    if extracted:
        raw = extracted
        break

# If already HTML with <ul> or <p>, keep it as-is
if re.search(r"<(ul|ol|li|p)\b", raw, re.IGNORECASE):
    print(raw)
    sys.exit(0)

PATH_EXT_RE = re.compile(
    r"^("
    r"[/\.]\S+|"
    r"(?:Sources|Tests|SconeosApp|SconeUI|SconeStore|SconeDomain|SonosProtocolBoundary|SpotifyBridge|scripts|server|\.github)/\S*|"
    r"\S+\.(?:swift|ts|tsx|js|mjs|css|json|yml|yaml|sh|md|plist|entitlements|pbxproj|xcframework|png|jpg|jpeg|svg|ico|xml)|"
    r"swift\s+test|npm\s+test"
    r")$"
)

def is_noise_paren(inner: str) -> bool:
    # Split on ',', 'and', 'or', '&' and check if all parts are backticked/bare repo file paths
    cleaned = inner.strip()
    if not cleaned:
        return True
    parts = re.split(r"\s*(?:,|\band\b|\bor\b|&)\s*", cleaned)
    for part in parts:
        token = part.strip().strip("`").strip()
        if not token or not PATH_EXT_RE.match(token):
            return False
    return True

def strip_file_path_parens(text: str) -> str:
    def repl(match: re.Match) -> str:
        inner = match.group(1)
        if is_noise_paren(inner):
            return ""
        return match.group(0)
    out = re.sub(r"\s*\(([^()]+)\)", repl, text)
    # Collapse double spaces before punctuation
    out = re.sub(r"\s+([,.;:])", r"\1", out)
    out = re.sub(r"  +", " ", out)
    return out.strip()

def render_inline(text: str) -> str:
    text = strip_file_path_parens(text)
    escaped = html.escape(text, quote=False)
    # Convert markdown links [label](https://...)
    escaped = re.sub(
        r"\[([^\]]+)\]\((https?://[^\s)]+)\)",
        r'<a href="\2">\1</a>',
        escaped,
    )
    # Convert **bold**
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    # Convert `code`
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    return escaped

lines = raw.splitlines()
bullets = []
paragraphs = []
current_bullet = None

for line in lines:
    stripped = line.strip()
    if not stripped:
        if current_bullet is not None:
            bullets.append(current_bullet)
            current_bullet = None
        continue
    # Skip standalone markdown images or raw image/video tags
    if re.match(r"^!\[[^\]]*\]\([^)]+\)$", stripped) or re.match(r"^<(?:img|video)\b", stripped, re.IGNORECASE):
        continue
    # Skip markdown headings
    if re.match(r"^#+\s+", stripped):
        continue
    bullet_match = re.match(r"^[-*]\s+(.+)$", stripped)
    if bullet_match:
        if current_bullet is not None:
            bullets.append(current_bullet)
        current_bullet = bullet_match.group(1).strip()
    elif current_bullet is not None:
        current_bullet = f"{current_bullet} {stripped}"
    else:
        paragraphs.append(stripped)

if current_bullet is not None:
    bullets.append(current_bullet)

out_parts = []
if paragraphs:
    for p in paragraphs:
        out_parts.append(f'<p style="margin: 0 0 8px 0; line-height: 1.45;">{render_inline(p)}</p>')
if bullets:
    out_parts.append("<ul>")
    for b in bullets:
        out_parts.append(f'  <li style="margin-bottom: 6px; line-height: 1.45;">{render_inline(b)}</li>')
    out_parts.append("</ul>")

if not out_parts:
    out_parts.append(f'<p style="margin: 0; line-height: 1.45;">Release v{html.escape(version)}</p>')

print("\n".join(out_parts))
PY
