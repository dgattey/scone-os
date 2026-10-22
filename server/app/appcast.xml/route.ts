import { appcastResponse, loadSite } from "@dylkit/web";

const site = loadSite();

export function GET() {
  return appcastResponse(site);
}
