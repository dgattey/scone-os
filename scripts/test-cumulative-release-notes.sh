#!/usr/bin/env bash
# Dry run of cumulative-release-notes.sh against a fixture of 12 existing versions (1.0.1–1.0.12) releasing 1.0.13.
# Prints the generated <description> HTML and asserts: 10 versions shown, newest first, deduplicated, appcast notes
# preferred over GitHub Release bodies, headerless appcast descriptions wrapped, placeholder releases skipped,
# nested release-body bullets dropped.
#
# Usage:
#   ./scripts/test-cumulative-release-notes.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$(mktemp -d /tmp/sconeos-cumulative-notes.XXXXXX)"
trap 'rm -rf "$FIXTURES"' EXIT

LI='<li style="margin-bottom: 6px; line-height: 1.45;">'

# Previous cumulative appcast (1.0.12) with headings for 1.0.12, 1.0.11, 1.0.10.
cat >"$FIXTURES/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <title>1.0.12</title>
      <sparkle:shortVersionString>1.0.12</sparkle:shortVersionString>
      <description><![CDATA[<h3 style="margin: 0 0 6px 0; font-size: 13px;">1.0.12</h3>
<ul>
  ${LI}Queue view remembers its scroll position.</li>
</ul>
<h3 style="margin: 14px 0 6px 0; font-size: 13px; opacity: 0.75;">1.0.11</h3>
<ul>
  ${LI}Faster speaker discovery on launch.</li>
</ul>
<h3 style="margin: 14px 0 6px 0; font-size: 13px; opacity: 0.75;">1.0.10</h3>
<ul>
  ${LI}Volume slider no longer jumps while dragging.</li>
</ul>]]></description>
    </item>
  </channel>
</rss>
XML

# GitHub Release appcast assets: the same 1.0.12 feed (duplicate) plus headerless pre-cumulative 1.0.9 and 1.0.8.
cp "$FIXTURES/appcast.xml" "$FIXTURES/appcast-v1.0.12.xml"
for entry in "1.0.9|Spotify playback transfers to idle Sonos groups." "1.0.8|Album art loads in high resolution."; do
  v="${entry%%|*}"
  cat >"$FIXTURES/appcast-v${v}.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <title>${v}</title>
      <sparkle:shortVersionString>${v}</sparkle:shortVersionString>
      <description><![CDATA[<ul>
  ${LI}${entry#*|}</li>
</ul>
]]></description>
    </item>
  </channel>
</rss>
XML
done

# GitHub Releases JSON for all 12 versions (Markdown bodies); 1.0.6 is a placeholder with no real notes.
python3 - "$FIXTURES/releases.json" <<'PY'
import json, sys
releases = []
for patch in range(12, 0, -1):
    v = f"1.0.{patch}"
    body = f"- **Dev note {v}:** Refactored view internals (`Sources/SconeUI/View{patch}.swift`)."
    if patch == 6:
        body = f"Release v{v}"
    elif patch == 5:
        body = f"- **Dev note {v}**:\n  - Nested implementation detail.\n    continued on a second line."
    releases.append({"tag_name": f"v{v}", "body": body, "draft": False})
json.dump(releases, open(sys.argv[1], "w"), indent=2)
PY

printf '<ul>\n  %s<strong>Cumulative update notes:</strong> Skipped versions now show every change since your installed version.</li>\n</ul>\n' "$LI" \
  >"$FIXTURES/new.html"

OUT="$("$ROOT/scripts/cumulative-release-notes.sh" 1.0.13 "$FIXTURES/new.html" \
  "$FIXTURES/appcast.xml" "$FIXTURES"/appcast-v*.xml "$FIXTURES/releases.json")"
printf '%s\n' "$OUT"

python3 - "$OUT" <<'PY'
import re, sys
out = sys.argv[1]
headings = re.findall(r'<h3 style="([^"]*)">([^<]*)</h3>', out)
versions = [v for _, v in headings]
expected = ["1.0.13", "1.0.12", "1.0.11", "1.0.10", "1.0.9", "1.0.8", "1.0.7", "1.0.5", "1.0.4", "1.0.3"]
assert versions == expected, f"versions {versions} != {expected}"
assert headings[0][0] == "margin: 0 0 6px 0; font-size: 13px;", headings[0][0]
assert all(s == "margin: 14px 0 6px 0; font-size: 13px; opacity: 0.75;" for s, _ in headings[1:])
assert "Dev note 1.0.12" not in out and "Dev note 1.0.8" not in out, "appcast notes must win over release bodies"
assert "Album art loads in high resolution." in out, "headerless appcast description must be carried forward"
assert "Dev note 1.0.7" in out and "Sources/SconeUI" not in out, "release bodies must be formatted"
assert "Release v1.0.6" not in out, "placeholder releases must be skipped"
assert "<strong>Dev note 1.0.5</strong></li>" in out and "Nested" not in out, "nested release bullets must be dropped"
assert "<li>" not in out, "every <li> must be styled"
print(f"\ntest-cumulative-release-notes: ok ({len(versions)} versions shown, newest first)", file=sys.stderr)
PY
