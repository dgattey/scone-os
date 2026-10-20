import { loadSite, SiteLayout, siteMetadata } from "@dylkit/web";
import type { ReactNode } from "react";

export const metadata = siteMetadata(loadSite());

export default function RootLayout({ children }: { children: ReactNode }) {
  return <SiteLayout site={loadSite()}>{children}</SiteLayout>;
}
