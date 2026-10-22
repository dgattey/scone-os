import { iconResponse, loadSite } from "@dylkit/web";

const site = loadSite();

export function GET(request: Request) {
  return iconResponse(site, request);
}
