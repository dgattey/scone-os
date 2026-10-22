import { DownloadPage, latestRelease, loadSite } from "@dylkit/web";

const site = loadSite();

export default async function HomePage() {
  return <DownloadPage site={site} release={await latestRelease(site)} />;
}
