import { loadSite, SiteLayout, siteMetadata } from "@dylkit/web";
import type { ReactNode } from "react";

const site = loadSite();

export const metadata = siteMetadata(site);

export default function RootLayout({ children }: { children: ReactNode }) {
  return <SiteLayout site={site}>{children}</SiteLayout>;
}
