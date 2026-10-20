import { DownloadPage, loadSite } from "@dylkit/web";

export const dynamic = "force-static";

export default function HomePage() {
  return <DownloadPage site={loadSite()} />;
}
