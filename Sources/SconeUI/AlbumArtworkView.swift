import ImageIO
import DylCore
import DylDesign
import SwiftUI
import SconeDomain
import SconeStore

#if canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#endif

private let artworkSession = URLSession.bounded(requestTimeout: 8, cache: .shared)

@MainActor
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()
    private let cache: NSCache<NSURL, PlatformImage> = {
        let c = NSCache<NSURL, PlatformImage>()
        c.countLimit = 160
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    func cachedImage(for url: URL) -> Image? {
        guard let platform = cache.object(forKey: url as NSURL) else { return nil }
        return makeSwiftUIImage(platform)
    }

    func load(url: URL, maxPixelSize: Int = 320) async -> Image? {
        if let cached = cachedImage(for: url) { return cached }
        if let existing = inFlight[url] {
            guard let platform = await existing.value else { return nil }
            return makeSwiftUIImage(platform)
        }

        let task = Task.detached(priority: .utility) { () -> PlatformImage? in
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, response) = try? await artworkSession.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            return Self.downsample(data: data, maxPixelSize: maxPixelSize)
        }
        inFlight[url] = task
        let loaded = await task.value
        inFlight[url] = nil
        if let loaded {
            cache.setObject(loaded, forKey: url as NSURL, cost: maxPixelSize * maxPixelSize * 4)
            return makeSwiftUIImage(loaded)
        }
        return nil
    }

    private func makeSwiftUIImage(_ image: PlatformImage) -> Image {
        #if canImport(AppKit)
        Image(nsImage: image)
        #elseif canImport(UIKit)
        Image(uiImage: image)
        #endif
    }

    nonisolated private static func downsample(data: Data, maxPixelSize: Int) -> PlatformImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return PlatformImage(data: data)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #elseif canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #endif
    }
}

struct AlbumArtworkView: View {
    var url: URL?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    @State private var loadedImage: Image?

    var body: some View {
        ZStack {
            if let displayImage = loadedImage ?? (url.flatMap { ArtworkImageCache.shared.cachedImage(for: $0) }) {
                displayImage
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [MidnightGlass.cardElevatedFill, MidnightGlass.obsidian],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Circle()
                        .strokeBorder(MidnightGlass.gold.opacity(0.24), lineWidth: max(1, size * 0.03))
                        .frame(width: size * 0.64, height: size * 0.64)
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: size * 0.42, weight: .regular))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [MidnightGlass.gold.opacity(0.85), MidnightGlass.copper.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(MidnightGlass.cardBorder, lineWidth: 1)
        }
        .task(id: url) {
            guard let url else {
                loadedImage = nil
                return
            }
            if let cached = ArtworkImageCache.shared.cachedImage(for: url) {
                loadedImage = cached
                return
            }
            loadedImage = await ArtworkImageCache.shared.load(url: url)
        }
    }
}

struct PlaybackSourceBadge: View {
    var source: PlaybackSource

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .bold))
            Text(source.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(MidnightGlass.gold)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(MidnightGlass.gold.opacity(0.14)))
        .overlay(Capsule().strokeBorder(MidnightGlass.gold.opacity(0.38), lineWidth: 0.85))
    }

    private var iconName: String {
        switch source {
        case .spotify: "dot.radiowaves.left.and.right"
        case .sonosQueue: "music.note.list"
        case .tvAudio: "tv.fill"
        case .radio: "antenna.radiowaves.left.and.right"
        case .lineIn: "cable.connector"
        }
    }
}

struct UpNextQueueCard: View {
    var track: NowPlayingTrack
    var roomName: String
    var maxHeight: CGFloat? = nil
    var embedded: Bool = false
    var onSelectQueueItem: (QueueItem) -> Void

    var body: some View {
        if embedded {
            content
        } else {
            content
                .padding(16)
                .glassCard(radius: 18)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Up Next")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MidnightGlass.gold)
                if !embedded, let source = track.source {
                    Text("· \(source.shortBadge)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MidnightGlass.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(track.upNext.count) \(track.upNext.count == 1 ? "track" : "tracks")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MidnightGlass.secondaryText)
            }
            .padding(.horizontal, embedded ? 4 : 2)

            if track.upNext.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MidnightGlass.secondaryText)
                    Text("No upcoming tracks queued in \(roomName)")
                        .font(.caption)
                        .foregroundStyle(MidnightGlass.secondaryText)
                }
                .padding(.vertical, 8)
            } else if let maxHeight {
                ScrollView {
                    queueList
                }
                .frame(maxHeight: maxHeight)
            } else {
                queueList
            }
        }
    }

    private var queueList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(track.upNext.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(MidnightGlass.cardBorder.opacity(0.45))
                        .frame(height: 1)
                        .padding(.leading, 66)
                }
                UpNextRow(
                    index: index + 1,
                    item: item,
                    onTap: { onSelectQueueItem(item) }
                )
            }
        }
    }
}

private struct UpNextRow: View {
    var index: Int
    var item: QueueItem
    var onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    if hovered {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MidnightGlass.gold)
                    } else {
                        Text("\(index)")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(MidnightGlass.secondaryText)
                    }
                }
                .frame(width: 18, alignment: .center)

                AlbumArtworkView(url: item.artworkURL, size: 32, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(hovered ? MidnightGlass.gold : MidnightGlass.primaryText)
                        .lineLimit(1)
                    if let artist = item.artist, !artist.isEmpty {
                        Text(item.album.map { "\(artist) · \($0)" } ?? artist)
                            .font(.caption)
                            .foregroundStyle(MidnightGlass.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let duration = item.duration {
                    Text(formatDuration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(MidnightGlass.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? MidnightGlass.subtleFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let total = max(0, Int(duration.components.seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
