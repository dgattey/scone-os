import { getMacOSRelease } from "@/lib/macos-release";
import styles from "./page.module.css";

export const dynamic = "force-static";

export default function HomePage() {
  const release = getMacOSRelease();

  return (
    <main className={styles.page}>
      <div className={styles.heroUnit}>
        <div className={styles.photoColumn}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/sconeos-preview.png"
            alt="Sconeos floorplan map and multi-room speaker controls on macOS"
            width={2232}
            height={1480}
            fetchPriority="high"
            className={styles.windowPreview}
          />
        </div>

        <div className={styles.downloadColumn}>
          <div className={styles.headingBlock}>
            <div className={styles.brandRow}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src="/app-icon.png"
                alt=""
                width={56}
                height={56}
                className={styles.appIcon}
              />
              <span className={styles.badge}>macOS 14+ · Apple Silicon</span>
            </div>
            <h1 className={styles.title}>Welcome to Sconeos</h1>
            <p className={styles.subtitle}>
              The spatial audio controller for Sonos households and Spotify — floorplan room map,
              discrete volume steps, and instant scene grouping.
            </p>
          </div>

          {release ? (
            <div className={styles.downloadActions}>
              <a className={styles.downloadButton} href="/download/macos">
                Download for macOS{release.version ? ` (v${release.version})` : ""}
              </a>
              {!release.downloadReady ? (
                <p className={styles.hint}>
                  That version is still deploying. Refresh in a minute if download fails.
                </p>
              ) : null}

              <details className={styles.manualApproval}>
                <summary>First time on this Mac? macOS may block the app</summary>
                <div className={styles.manualApprovalBody}>
                  <p className={styles.finePrint}>
                    After you download and try to open Sconeos once, approve it in System
                    Settings.
                  </p>
                  <ol className={styles.manualSteps}>
                    <li>
                      Try opening <strong>Sconeos</strong> from Applications so macOS
                      records the block.
                    </li>
                    <li>
                      Open <strong>System Settings → Privacy & Security</strong>.
                    </li>
                    <li>
                      Under Security, click <strong>Open Anyway</strong> next to the Sconeos
                      message.
                    </li>
                    <li>Open the app again.</li>
                  </ol>
                  <figure className={styles.manualApprovalFigure}>
                    <div className={styles.manualApprovalMedia}>
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img
                        src="/macos-open-anyway.png"
                        alt="Privacy and Security settings showing the app was blocked with an Open Anyway button"
                        width={1024}
                        height={903}
                        decoding="async"
                      />
                    </div>
                    <figcaption>
                      Open Anyway appears after you try to launch the app once.
                    </figcaption>
                  </figure>
                </div>
              </details>
            </div>
          ) : (
            <p className={styles.noRelease}>
              A macOS build is not published yet. Check back after the next release.
            </p>
          )}
        </div>
      </div>
    </main>
  );
}
