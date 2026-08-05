import AppKit
import PDFKit

/// 複数のSourceItemから1つのPDFDocumentを合成するサービス
enum PDFComposer {

    /// PDFKitへの同時アクセスを避けるため、合成処理を1本のキューに集約する
    private static let compositionQueue = DispatchQueue(label: "jp.pdfbinder.composition")

    /// itemsの順番どおりにページを連結したPDFDocumentを生成する
    /// - Note: 重い処理なのでバックグラウンドスレッドから呼ぶこと
    static func compose(items: [SourceItem], imagePageMode: ImagePageMode = .fitA4) -> PDFDocument {
        compositionQueue.sync {
            composeOnQueue(items: items, imagePageMode: imagePageMode)
        }
    }

    /// compositionQueue上で実際の合成処理を行う
    private static func composeOnQueue(items: [SourceItem], imagePageMode: ImagePageMode) -> PDFDocument {
        let document = PDFDocument()
        var insertIndex = 0

        for item in items {
            switch item.kind {
            case .pdf:
                guard let source = PDFDocument(url: item.url) else { continue }
                for pageIndex in 0..<source.pageCount {
                    guard let page = source.page(at: pageIndex) else { continue }
                    // 元ドキュメントに属するページはコピーしてから挿入する
                    guard let copied = page.copy() as? PDFPage else { continue }
                    document.insert(copied, at: insertIndex)
                    insertIndex += 1
                }
            case .image:
                guard let image = NSImage(contentsOf: item.url),
                      let page = imagePage(from: image, mode: imagePageMode) else { continue }
                document.insert(page, at: insertIndex)
                insertIndex += 1
            }
        }

        return document
    }

    /// 合成したPDFを指定URLへ書き出す
    /// - Returns: 書き出しに成功したらtrue
    static func export(
        items: [SourceItem],
        imagePageMode: ImagePageMode = .fitA4,
        to url: URL
    ) -> Bool {
        compositionQueue.sync {
            let document = composeOnQueue(items: items, imagePageMode: imagePageMode)
            guard document.pageCount > 0 else { return false }
            return document.write(to: url)
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
