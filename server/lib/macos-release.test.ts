import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseAppcastXml } from "./macos-release.ts";

const SAMPLE = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Sconeos</title>
    <item>
      <title>1.0.1</title>
      <sparkle:version>42</sparkle:version>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <enclosure url="https://sconeos.gattey.com/Sconeos-1.0.1.zip" length="1" type="application/octet-stream"/>
    </item>
  </channel>
</rss>`;

describe("parseAppcastXml", () => {
  it("parses version, build, and absolute download URL", () => {
    const release = parseAppcastXml(SAMPLE);
    assert.ok(release);
    assert.equal(release.version, "1.0.1");
    assert.equal(release.build, "42");
    assert.equal(release.zipPath, "/Sconeos-1.0.1.zip");
    assert.equal(release.downloadUrl, "https://sconeos.gattey.com/Sconeos-1.0.1.zip");
  });

  it("returns null for invalid xml", () => {
    assert.equal(parseAppcastXml("<rss></rss>"), null);
  });
});
