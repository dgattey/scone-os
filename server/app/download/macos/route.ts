import { downloadResponse, loadSite } from "@dylkit/web";

const site = loadSite();

export function GET() {
  return downloadResponse(site);
}
