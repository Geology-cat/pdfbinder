import AppKit
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

    /// PDFKitへの同時アクセスを避けるため、合成処理を1本のキューに集約する
    private static let compositionQueue = DispatchQueue(label: "jp.pdfbinder.composition")

    /// itemsの順番どおりにページを連結したPDFDocumentを生成する
    /// - Note: 重い処理なのでバックグラウンドスレッドから呼ぶこと
    static func compose(items: [SourceItem], imagePageMode: ImagePageMode = .original) -> PDFDocument {
        compositionQueue.sync {
            composeOnQueue(items: items, imagePageMode: imagePageMode)
        }
    }

    /// compositionQueue上で実際の合成処理を行う
    private static func composeOnQueue(
        items: [SourceItem],
        imagePageMode: ImagePageMode,
        pageProgress: ((_ completedPages: Int, _ totalPages: Int) -> Void)? = nil
    ) -> PDFDocument {
        let document = PDFDocument()
        var insertIndex = 0
        var completedPages = 0
        let totalPages = items.reduce(0) { $0 + $1.pageCount }

        func advance(by count: Int = 1) {
            completedPages = min(completedPages + count, totalPages)
            pageProgress?(completedPages, totalPages)
        }

        for item in items {
            switch item.kind {
            case .pdf:
                guard let source = PDFDocument(url: item.url) else {
                    advance(by: item.pageCount)
                    continue
                }
                for pageIndex in 0..<source.pageCount {
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
                if let image = NSImage(contentsOf: item.url),
                   let page = imagePage(from: image, mode: imagePageMode) {
                    document.insert(page, at: insertIndex)
                    insertIndex += 1
                }
                advance()
            }
        }

        return document
    }

    /// 合成したPDFを指定URLへ書き出す
    /// - Returns: 書き出しに成功したらtrue
    static func export(
        items: [SourceItem],
        imagePageMode: ImagePageMode = .original,
        to url: URL,
        progress: (@Sendable (PDFExportProgress) -> Void)? = nil
    ) -> Bool {
        compositionQueue.sync {
            let totalPages = items.reduce(0) { $0 + $1.pageCount }
            progress?(.preparing(totalPages: totalPages))

            let document = composeOnQueue(
                items: items,
                imagePageMode: imagePageMode
            ) { completedPages, _ in
                progress?(
                    PDFExportProgress(
                        phase: .composing,
                        completedPages: completedPages,
                        totalPages: totalPages
                    )
                )
            }

            guard document.pageCount > 0 else { return false }
            progress?(
                PDFExportProgress(
                    phase: .writing,
                    completedPages: totalPages,
                    totalPages: totalPages
                )
            )

            let success = document.write(to: url)
            if success {
                progress?(
                    PDFExportProgress(
                        phase: .completed,
                        completedPages: totalPages,
                        totalPages: totalPages
                    )
                )
            }
            return success
        }
    }

    /// 指定モードに応じた画像ページを生成する
    private static func imagePage(from image: NSImage, mode: ImagePageMode) -> PDFPage? {
        switch mode {
        case .original:
            return renderedPage(from: image, pageSize: image.size, aspectFit: false)
        case .fitA4:
            // 72 dpiでのA4サイズ（210 x 297 mm）
            return renderedPage(
                from: image,
                pageSize: CGSize(width: 595.28, height: 841.89),
                aspectFit: true
            )
        }
    }

    /// 指定したページサイズへ画像を描画してPDFPageを生成する
    private static func renderedPage(
        from image: NSImage,
        pageSize: CGSize,
        aspectFit: Bool
    ) -> PDFPage? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }

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
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
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
        context.draw(cgImage, in: drawRect)
        context.endPDFPage()
        context.closePDF()

        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
