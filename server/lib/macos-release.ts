import fs from "fs";
import path from "path";

export type MacOSRelease = {
  version: string;
  build: string;
  /** Pathname for the zip, e.g. `/Sconeos-1.0.1.zip`. */
  zipPath: string;
  /** Absolute URL used for download redirects. */
  downloadUrl: string;
  /** False when appcast names a zip that is not in `server/public/` (broken tree or mid-release build). */
  downloadReady: boolean;
};

export function parseAppcastXml(xml: string): Omit<MacOSRelease, "downloadReady"> | null {
  const version =
    xml.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1] ??
    xml.match(/<title>([^<]+)<\/title>/)?.[1];
  const build = xml.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1] ?? "";
  const enclosure = xml.match(/<enclosure\s+url="([^"]+)"/)?.[1];
  if (!version || !enclosure) return null;

  let downloadUrl = enclosure;
  let zipPath: string;
  try {
    const url = new URL(enclosure);
    downloadUrl = url.href;
    zipPath = url.pathname;
  } catch {
    zipPath = enclosure.startsWith("/") ? enclosure : `/${enclosure}`;
    downloadUrl = `${getSiteOrigin()}${zipPath}`;
  }

  return { version, build, zipPath, downloadUrl };
}

export function getSiteOrigin(): string {
  if (process.env.SCONEOS_SITE_ORIGIN) {
    return process.env.SCONEOS_SITE_ORIGIN.replace(/\/$/, "");
  }
  if (process.env.VERCEL_ENV === "production") {
    return "https://sconeos.gattey.com";
  }
  if (process.env.VERCEL_URL) {
    return `https://${process.env.VERCEL_URL}`;
  }
  return `http://localhost:${process.env.PORT ?? 3000}`;
}

function readBundledAppcastXml(): string | null {
  const appcastPath = path.join(process.cwd(), "public", "appcast.xml");
  if (!fs.existsSync(appcastPath)) return null;
  return fs.readFileSync(appcastPath, "utf8");
}

function zipExistsInPublic(zipPath: string): boolean {
  const localZip = path.join(process.cwd(), "public", zipPath.replace(/^\//, ""));
  return fs.existsSync(localZip);
}

/** Reads committed `server/public/` artifacts (static at build / deploy time). */
export function getMacOSRelease(): MacOSRelease | null {
  const xml = readBundledAppcastXml();
  if (!xml) return null;

  const parsed = parseAppcastXml(xml);
  if (!parsed) return null;

  const downloadReady = zipExistsInPublic(parsed.zipPath);
  return { ...parsed, downloadReady };
}
