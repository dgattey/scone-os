import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Sconeos",
  description:
    "Download Sconeos for macOS — spatial audio controller for Sonos households and Spotify.",
  icons: {
    icon: "/app-icon.png",
    apple: "/app-icon.png",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <head>
        <link rel="preload" href="/sconeos-preview.png" as="image" />
      </head>
      <body>{children}</body>
    </html>
  );
}
