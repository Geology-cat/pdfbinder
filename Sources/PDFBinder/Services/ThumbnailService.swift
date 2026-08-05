import AppKit
import QuickLookThumbnailing

/// ファイルのサムネイル生成とキャッシュを担うサービス
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    /// URL単位のキャッシュ（同じファイルを複数回追加しても再生成しない）
    private var cache: [URL: NSImage] = [:]

    private init() {}

    /// サムネイルを非同期で取得する。失敗した場合はnil
    func thumbnail(for url: URL, size: CGSize = CGSize(width: 48, height: 64)) async -> NSImage? {
        if let cached = cache[url] {
            return cached
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.nsImage
            cache[url] = image
            return image
        } catch {
            return nil
        }
    }

    /// キャッシュを破棄する（リストのクリア時に呼ぶ）
    func clearCache() {
        cache.removeAll()
    }
}
