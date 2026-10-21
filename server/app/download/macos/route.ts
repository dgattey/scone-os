import { downloadResponse, loadSite } from "@dylkit/web";

// Runs during `next build`, while the zip is on disk; Vercel leaves large `public/` files out of function bundles.
export const dynamic = "force-static";

export function GET() {
  return downloadResponse(loadSite());
}
