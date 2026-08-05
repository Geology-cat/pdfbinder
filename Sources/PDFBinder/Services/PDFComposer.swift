import AppKit
import ImageIO
import PDFKit

/// PDF書き出し処理の進行状況
struct PDFExportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case composing
        case writing
        case completed
    }

    let phase: Phase
    let completedPages: Int
    let totalPages: Int

    /// PDFファイルの書き込みを最後の1作業単位として扱った進捗率
    var fractionCompleted: Double {
        let pageCount = max(totalPages, 0)
        let totalUnitCount = max(pageCount + 1, 1)

        switch phase {
        case .composing:
            return Double(min(max(completedPages, 0), pageCount)) / Double(totalUnitCount)
        case .writing:
            return Double(pageCount) / Double(totalUnitCount)
        case .completed:
            return 1
        }
    }

    /// 進捗ウインドウに表示する説明
    var statusText: String {
        switch phase {
        case .composing where completedPages == 0:
            return "結合の準備中…"
        case .composing:
            return "\(completedPages) / \(totalPages) ページを処理しました"
        case .writing:
            return "PDFファイルを書き込み中…"
        case .completed:
            return "完了しました"
        }
    }

    static func preparing(totalPages: Int) -> PDFExportProgress {
        PDFExportProgress(phase: .composing, completedPages: 0, totalPages: totalPages)
    }
}

/// 複数のSourceItemから1つのPDFDocumentを合成するサービス
enum PDFComposer {

    /// Retina表示でも十分なプレビュー解像度。書き出しには適用しない
    static let previewImageMaximumPixelSize = 2048

    /// PDFKitへの同時アクセスを避けるため、合成処理を1本のキューに集約する
    private static let compositionQueue = DispatchQueue(label: "jp.pdfbinder.composition")

    /// プレビュー用1ページPDFのLRUキャッシュ
    private static var previewPageCache: [PreviewPageCacheKey: PreviewPageCacheEntry] = [:]
    private static var previewCacheAccessOrder: [PreviewPageCacheKey] = []
    private static var previewCacheCost = 0
    private static let previewCacheCostLimit = 128 * 1_024 * 1_024

    /// 直前に作成した完成PDF。巨大ファイルによるメモリ圧迫を避けるため1件だけ保持する
    private static var exportCache: ExportCacheEntry?
    private static let exportCacheCostLimit = 256 * 1_024 * 1_024
    private static let exportPreparationInputCostLimit = 512 * 1_024 * 1_024

    /// キャッシュの利用状況
    private static var previewCacheHits = 0
    private static var previewCacheMisses = 0
    private static var exportCacheHits = 0
    private static var exportCacheMisses = 0

    /// 画像ページ生成の用途
    private enum ImagePurpose {
        case fullQuality
        case preview(maximumPixelSize: Int)
    }

    /// プレビューキャッシュのキー
    private struct PreviewPageCacheKey: Hashable {
        let url: URL
        let fileSize: Int
        let modifiedAt: Date
        let imagePageMode: ImagePageMode
        let maximumPixelSize: Int
    }

    /// キャッシュ済みのプレビュー用1ページPDF
    private struct PreviewPageCacheEntry {
        let data: Data
        let imagePixelSize: CGSize
    }

    /// キャッシュ済みの完成PDF
    private struct ExportCacheEntry {
        let key: PDFCompositionKey
        let data: Data
    }

    // MARK: - 合成

    /// itemsの順番どおりに原寸品質で連結したPDFDocumentを生成する
    /// - Note: 重い処理なのでバックグラウンドスレッドから呼ぶこと
    static func compose(items: [SourceItem], imagePageMode: ImagePageMode = .original) -> PDFDocument {
        compositionQueue.sync {
            composeOnQueue(
                items: items,
                imagePageMode: imagePageMode,
                imagePurpose: .fullQuality
            ) ?? PDFDocument()
        }
    }

    /// 画像だけを縮小したプレビュー用PDFDocumentを生成する
    /// - Returns: キャンセルされた場合はnil
    static func composePreview(
        items: [SourceItem],
        imagePageMode: ImagePageMode = .original,
        maximumPixelSize: Int = previewImageMaximumPixelSize,
        cancellationToken: PDFCompositionCancellationToken,
        previewImageObserver: ((_ pixelSize: CGSize) -> Void)? = nil,
        pageProgress: ((_ completedPages: Int, _ totalPages: Int) -> Void)? = nil
    ) -> PDFDocument? {
        compositionQueue.sync {
            guard !cancellationToken.isCancelled else { return nil }
            return composeOnQueue(
                items: items,
                imagePageMode: imagePageMode,
                imagePurpose: .preview(maximumPixelSize: maximumPixelSize),
                cancellationToken: cancellationToken,
                previewImageObserver: previewImageObserver,
                pageProgress: pageProgress
            )
        }
    }

    /// compositionQueue上で実際の合成処理を行う
    private static func composeOnQueue(
        items: [SourceItem],
        imagePageMode: ImagePageMode,
        imagePurpose: ImagePurpose,
        cancellationToken: PDFCompositionCancellationToken? = nil,
        previewImageObserver: ((_ pixelSize: CGSize) -> Void)? = nil,
        pageProgress: ((_ completedPages: Int, _ totalPages: Int) -> Void)? = nil
    ) -> PDFDocument? {
        let document = PDFDocument()
        var insertIndex = 0
        var completedPages = 0
        let totalPages = items.reduce(0) { $0 + $1.pageCount }

        func advance(by count: Int = 1) {
            completedPages = min(completedPages + count, totalPages)
            pageProgress?(completedPages, totalPages)
        }

        for item in items {
            guard cancellationToken?.isCancelled != true else { return nil }

            switch item.kind {
            case .pdf:
                guard let source = PDFDocument(url: item.url) else {
                    advance(by: item.pageCount)
                    continue
                }
                for pageIndex in 0..<source.pageCount {
                    guard cancellationToken?.isCancelled != true else { return nil }
                    if let page = source.page(at: pageIndex),
                       let copied = page.copy() as? PDFPage {
                        // 元ドキュメントに属するページはコピーしてから挿入する
                        document.insert(copied, at: insertIndex)
                        insertIndex += 1
                    }
                    advance()
                }
                if source.pageCount < item.pageCount {
                    advance(by: item.pageCount - source.pageCount)
                }

            case .image:
                let page: PDFPage?
                switch imagePurpose {
                case .fullQuality:
                    page = fullQualityImagePage(for: item, mode: imagePageMode)
                case let .preview(maximumPixelSize):
                    page = previewImagePage(
                        for: item,
                        mode: imagePageMode,
                        maximumPixelSize: maximumPixelSize,
                        observer: previewImageObserver
                    )
                }

                guard cancellationToken?.isCancelled != true else { return nil }
                if let page {
                    document.insert(page, at: insertIndex)
                    insertIndex += 1
                }
                advance()
            }
        }

        return document
    }

    // MARK: - 書き出し

    /// プレビュー確定後に原寸品質の完成PDFを事前準備する
    /// - Returns: キャッシュ済み、または新たにキャッシュできた場合はtrue
    static func prepareExportCache(
        items: [SourceItem],
        imagePageMode: ImagePageMode = .original,
        cancellationToken: PDFCompositionCancellationToken,
        pageProgress: ((_ completedPages: Int, _ totalPages: Int) -> Void)? = nil
    ) -> Bool {
        compositionQueue.sync {
            let key = PDFCompositionKey(items: items, imagePageMode: imagePageMode)
            if exportCache?.key == key {
                return true
            }

            let totalInputBytes = items.reduce(Int64(0)) {
                $0 + Int64(max($1.fileSize, 0))
            }
            guard !items.isEmpty,
                  totalInputBytes <= Int64(exportPreparationInputCostLimit),
                  !cancellationToken.isCancelled,
                  let document = composeOnQueue(
                    items: items,
                    imagePageMode: imagePageMode,
                    imagePurpose: .fullQuality,
                    cancellationToken: cancellationToken,
                    pageProgress: pageProgress
                  ),
                  document.pageCount > 0,
                  !cancellationToken.isCancelled,
                  let data = document.dataRepresentation(),
                  !cancellationToken.isCancelled,
                  data.count <= exportCacheCostLimit else {
                return false
            }

            exportCache = ExportCacheEntry(key: key, data: data)
            return true
        }
    }

    /// 合成したPDFを指定URLへ書き出す。同一内容なら直前の完成PDFを再利用する
    /// - Returns: 書き出しに成功したらtrue
    static func export(
        items: [SourceItem],
        imagePageMode: ImagePageMode = .original,
        to url: URL,
        progress: (@Sendable (PDFExportProgress) -> Void)? = nil
    ) -> Bool {
        compositionQueue.sync {
            let key = PDFCompositionKey(items: items, imagePageMode: imagePageMode)
            let totalPages = items.reduce(0) { $0 + $1.pageCount }
            progress?(.preparing(totalPages: totalPages))

            if let cached = exportCache, cached.key == key {
                exportCacheHits += 1
                progress?(
                    PDFExportProgress(
                        phase: .writing,
                        completedPages: totalPages,
                        totalPages: totalPages
                    )
                )
                return write(
                    data: cached.data,
                    to: url,
                    totalPages: totalPages,
                    progress: progress
                )
            }

            exportCacheMisses += 1
            guard let document = composeOnQueue(
                items: items,
                imagePageMode: imagePageMode,
                imagePurpose: .fullQuality,
                pageProgress: { completedPages, _ in
                    progress?(
                        PDFExportProgress(
                            phase: .composing,
                            completedPages: completedPages,
                            totalPages: totalPages
                        )
                    )
                }
            ), document.pageCount > 0 else {
                return false
            }

            progress?(
                PDFExportProgress(
                    phase: .writing,
                    completedPages: totalPages,
                    totalPages: totalPages
                )
            )
            guard let data = document.dataRepresentation() else { return false }

            let success = write(
                data: data,
                to: url,
                totalPages: totalPages,
                progress: progress
            )
            if success {
                if data.count <= exportCacheCostLimit {
                    exportCache = ExportCacheEntry(key: key, data: data)
                } else {
                    exportCache = nil
                }
            }
            return success
        }
    }

    /// PDFデータをファイルへ安全に書き出す
    private static func write(
        data: Data,
        to url: URL,
        totalPages: Int,
        progress: (@Sendable (PDFExportProgress) -> Void)?
    ) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            progress?(
                PDFExportProgress(
                    phase: .completed,
                    completedPages: totalPages,
                    totalPages: totalPages
                )
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - 画像ページ

    /// 原寸品質の画像ページを生成する
    private static func fullQualityImagePage(for item: SourceItem, mode: ImagePageMode) -> PDFPage? {
        guard let image = NSImage(contentsOf: item.url) else { return nil }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }

        let pageSize: CGSize
        let aspectFit: Bool
        switch mode {
        case .original:
            pageSize = image.size
            aspectFit = false
        case .fitA4:
            pageSize = a4PageSize
            aspectFit = true
        }

        guard let data = renderedPageData(from: cgImage, pageSize: pageSize, aspectFit: aspectFit) else {
            return nil
        }
        return page(from: data)
    }

    /// 縮小画像からプレビュー用ページを生成し、同一条件ならキャッシュを利用する
    private static func previewImagePage(
        for item: SourceItem,
        mode: ImagePageMode,
        maximumPixelSize: Int,
        observer: ((_ pixelSize: CGSize) -> Void)?
    ) -> PDFPage? {
        let key = PreviewPageCacheKey(
            url: item.url,
            fileSize: item.fileSize,
            modifiedAt: item.modifiedAt,
            imagePageMode: mode,
            maximumPixelSize: maximumPixelSize
        )

        if let cached = cachedPreviewPage(for: key) {
            previewCacheHits += 1
            observer?(cached.imagePixelSize)
            return page(from: cached.data)
        }

        previewCacheMisses += 1
        guard let imageSource = CGImageSourceCreateWithURL(item.url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let pageSize: CGSize
        let aspectFit: Bool
        switch mode {
        case .original:
            pageSize = NSImage(contentsOf: item.url)?.size ?? imagePixelSize
            aspectFit = false
        case .fitA4:
            pageSize = a4PageSize
            aspectFit = true
        }

        guard let data = renderedPageData(from: cgImage, pageSize: pageSize, aspectFit: aspectFit) else {
            return nil
        }

        let entry = PreviewPageCacheEntry(data: data, imagePixelSize: imagePixelSize)
        storePreviewPage(entry, for: key)
        observer?(imagePixelSize)
        return page(from: data)
    }

    /// 指定したページサイズへ画像を描画し、1ページPDFのDataを生成する
    private static func renderedPageData(
        from image: CGImage,
        pageSize: CGSize,
        aspectFit: Bool
    ) -> Data? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)

        let drawRect: CGRect
        if aspectFit {
            let imageSize = CGSize(width: image.width, height: image.height)
            let scale = min(mediaBox.width / imageSize.width, mediaBox.height / imageSize.height)
            let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            drawRect = CGRect(
                x: (mediaBox.width - fittedSize.width) / 2,
                y: (mediaBox.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        } else {
            drawRect = mediaBox
        }

        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// 1ページPDFのDataから独立したPDFPageを生成する
    private static func page(from data: Data) -> PDFPage? {
        guard let document = PDFDocument(data: data),
              let sourcePage = document.page(at: 0) else {
            return nil
        }
        return sourcePage.copy() as? PDFPage
    }

    private static let a4PageSize = CGSize(width: 595.28, height: 841.89)

    // MARK: - キャッシュ

    /// プレビューキャッシュから取得し、LRU順を更新する
    private static func cachedPreviewPage(for key: PreviewPageCacheKey) -> PreviewPageCacheEntry? {
        guard let entry = previewPageCache[key] else { return nil }
        previewCacheAccessOrder.removeAll { $0 == key }
        previewCacheAccessOrder.append(key)
        return entry
    }

    /// プレビューキャッシュへ保存し、上限を超えた古い項目を破棄する
    private static func storePreviewPage(_ entry: PreviewPageCacheEntry, for key: PreviewPageCacheKey) {
        if let existing = previewPageCache[key] {
            previewCacheCost -= existing.data.count
            previewCacheAccessOrder.removeAll { $0 == key }
        }

        previewPageCache[key] = entry
        previewCacheAccessOrder.append(key)
        previewCacheCost += entry.data.count

        while previewCacheCost > previewCacheCostLimit,
              let oldestKey = previewCacheAccessOrder.first {
            previewCacheAccessOrder.removeFirst()
            if let removed = previewPageCache.removeValue(forKey: oldestKey) {
                previewCacheCost -= removed.data.count
            }
        }
    }

    /// アプリ操作を止めずにキャッシュを破棄する
    static func clearCaches() {
        compositionQueue.async {
            clearCachesOnQueue(resetStatistics: false)
        }
    }

    /// テスト用にキャッシュと統計を同期的に初期化する
    static func resetCachesForTesting() {
        compositionQueue.sync {
            clearCachesOnQueue(resetStatistics: true)
        }
    }

    /// キャッシュ統計を取得する
    static func cacheStatistics() -> PDFComposerCacheStatistics {
        compositionQueue.sync {
            PDFComposerCacheStatistics(
                previewHits: previewCacheHits,
                previewMisses: previewCacheMisses,
                exportHits: exportCacheHits,
                exportMisses: exportCacheMisses
            )
        }
    }

    private static func clearCachesOnQueue(resetStatistics: Bool) {
        previewPageCache.removeAll()
        previewCacheAccessOrder.removeAll()
        previewCacheCost = 0
        exportCache = nil

        if resetStatistics {
            previewCacheHits = 0
            previewCacheMisses = 0
            exportCacheHits = 0
            exportCacheMisses = 0
        }
    }
}
