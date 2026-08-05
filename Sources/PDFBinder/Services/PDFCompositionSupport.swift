import Foundation

/// ファイル順・内容・画像配置モードを含む合成結果の識別子
struct PDFCompositionKey: Hashable, Sendable {
    let items: [SourceItem]
    let imagePageMode: ImagePageMode
}

/// 同期的なPDFKit処理へキャンセル要求を安全に伝える
final class PDFCompositionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }
}

/// キャッシュが実際に利用されたことを検証・診断するための統計
struct PDFComposerCacheStatistics: Equatable, Sendable {
    let previewHits: Int
    let previewMisses: Int
    let exportHits: Int
    let exportMisses: Int
}
