import AppKit
import PDFKit
import XCTest
@testable import PDFBinder

final class PDFBinderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        PDFComposer.resetCachesForTesting()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFBinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        PDFComposer.resetCachesForTesting()
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func test名前の自然順ソート() throws {
        let ten = try makeImageFile(name: "10.png", size: CGSize(width: 100, height: 100))
        let two = try makeImageFile(name: "2.png", size: CGSize(width: 100, height: 100))
        let one = try makeImageFile(name: "1.png", size: CGSize(width: 100, height: 100))
        let items = try [ten, two, one].map { try XCTUnwrap(SourceItem.make(from: $0)) }

        XCTAssertEqual(
            SortOption.nameAscending.sorted(items).map(\.fileName),
            ["1.png", "2.png", "10.png"]
        )
    }

    @MainActor
    func test複数ファイル追加時は名前昇順になる() throws {
        let ten = try makeImageFile(name: "10.png", size: CGSize(width: 100, height: 100))
        let two = try makeImageFile(name: "2.png", size: CGSize(width: 100, height: 100))
        let one = try makeImageFile(name: "1.png", size: CGSize(width: 100, height: 100))
        let viewModel = MergeListViewModel()

        viewModel.addFiles(urls: [ten, two, one])

        XCTAssertEqual(viewModel.items.map(\.fileName), ["1.png", "2.png", "10.png"])
        viewModel.clearAll()
    }

    @MainActor
    func testソート順の選択状態が並び替え操作に追従する() throws {
        let one = try makeImageFile(name: "1.png", size: CGSize(width: 100, height: 100))
        let two = try makeImageFile(name: "2.png", size: CGSize(width: 100, height: 100))
        let viewModel = MergeListViewModel()

        viewModel.addFiles(urls: [one, two])
        XCTAssertEqual(viewModel.selectedSortOption, .nameAscending)

        viewModel.sort(by: .nameDescending)

        XCTAssertEqual(viewModel.selectedSortOption, .nameDescending)
        XCTAssertEqual(viewModel.items.map(\.fileName), ["2.png", "1.png"])

        viewModel.move(from: IndexSet(integer: 0), to: 2)

        XCTAssertNil(viewModel.selectedSortOption)
        viewModel.clearAll()
    }

    @MainActor
    func testすべてクリアで読み込み内容と選択を消去する() throws {
        let one = try makeImageFile(name: "1.png", size: CGSize(width: 100, height: 100))
        let two = try makeImageFile(name: "2.png", size: CGSize(width: 100, height: 100))
        let viewModel = MergeListViewModel()
        viewModel.addFiles(urls: [one, two])
        viewModel.selection = Set(viewModel.items.map(\.id))
        viewModel.sort(by: .nameDescending)

        viewModel.clearAll()

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.selection.isEmpty)
        XCTAssertNil(viewModel.previewDocument)
        XCTAssertEqual(viewModel.selectedSortOption, .nameAscending)
    }

    @MainActor
    func test画像ページモードの初期値は原寸() {
        let viewModel = MergeListViewModel()

        XCTAssertEqual(viewModel.imagePageMode, .original)
    }

    func test画像をA4ページへ変換する() throws {
        let imageURL = try makeImageFile(
            name: "横長.png",
            size: CGSize(width: 1600, height: 900)
        )
        let item = try XCTUnwrap(SourceItem.make(from: imageURL))

        let document = PDFComposer.compose(items: [item], imagePageMode: .fitA4)

        XCTAssertEqual(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 595.28, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 841.89, accuracy: 0.1)
    }

    func test画像の原寸ページを維持する() throws {
        let imageURL = try makeImageFile(
            name: "原寸.png",
            size: CGSize(width: 320, height: 240)
        )
        let item = try XCTUnwrap(SourceItem.make(from: imageURL))

        let document = PDFComposer.compose(items: [item])

        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 320, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 240, accuracy: 0.1)
    }

    func testプレビュー画像を縮小して原寸ページ寸法を維持する() throws {
        let imageURL = try makeImageFile(
            name: "大きな画像.png",
            size: CGSize(width: 2400, height: 1800)
        )
        let item = try XCTUnwrap(SourceItem.make(from: imageURL))
        let cancellationToken = PDFCompositionCancellationToken()
        var observedPixelSizes: [CGSize] = []

        let document = try XCTUnwrap(
            PDFComposer.composePreview(
                items: [item],
                imagePageMode: .original,
                maximumPixelSize: 512,
                cancellationToken: cancellationToken
            ) { pixelSize in
                observedPixelSizes.append(pixelSize)
            }
        )

        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 2400, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 1800, accuracy: 0.1)
        let pixelSize = try XCTUnwrap(observedPixelSizes.first)
        XCTAssertLessThanOrEqual(max(pixelSize.width, pixelSize.height), 512)
    }

    func testプレビュー用ページを同一条件でキャッシュする() throws {
        let imageURL = try makeImageFile(
            name: "キャッシュ.png",
            size: CGSize(width: 1200, height: 900)
        )
        let item = try XCTUnwrap(SourceItem.make(from: imageURL))

        XCTAssertNotNil(
            PDFComposer.composePreview(
                items: [item],
                cancellationToken: PDFCompositionCancellationToken()
            )
        )
        var statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.previewMisses, 1)
        XCTAssertEqual(statistics.previewHits, 0)

        XCTAssertNotNil(
            PDFComposer.composePreview(
                items: [item],
                cancellationToken: PDFCompositionCancellationToken()
            )
        )
        statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.previewMisses, 1)
        XCTAssertEqual(statistics.previewHits, 1)
    }

    func testプレビュー合成をページ間でキャンセルする() throws {
        let sourcePDF = try makePDFFile(name: "キャンセル.pdf", pageSizes: [
            CGSize(width: 300, height: 400),
            CGSize(width: 400, height: 500),
            CGSize(width: 500, height: 600)
        ])
        let item = try XCTUnwrap(SourceItem.make(from: sourcePDF))
        let cancellationToken = PDFCompositionCancellationToken()

        let document = PDFComposer.composePreview(
            items: [item],
            cancellationToken: cancellationToken,
            pageProgress: { completedPages, _ in
                if completedPages == 1 {
                    cancellationToken.cancel()
                }
            }
        )

        XCTAssertNil(document)
    }

    func test同一条件のPDF書き出しで完成データを再利用する() throws {
        let imageURL = try makeImageFile(
            name: "再利用.png",
            size: CGSize(width: 640, height: 480)
        )
        let secondImageURL = try makeImageFile(
            name: "再利用2.png",
            size: CGSize(width: 480, height: 640)
        )
        let item = try XCTUnwrap(SourceItem.make(from: imageURL))
        let secondItem = try XCTUnwrap(SourceItem.make(from: secondImageURL))
        let items = [item, secondItem]
        let firstURL = temporaryDirectory.appendingPathComponent("1回目.pdf")
        let secondURL = temporaryDirectory.appendingPathComponent("2回目.pdf")
        let changedURL = temporaryDirectory.appendingPathComponent("条件変更.pdf")
        let reorderedURL = temporaryDirectory.appendingPathComponent("順序変更.pdf")

        XCTAssertTrue(PDFComposer.export(items: items, to: firstURL))
        var statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.exportMisses, 1)
        XCTAssertEqual(statistics.exportHits, 0)

        XCTAssertTrue(PDFComposer.export(items: items, to: secondURL))
        statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.exportMisses, 1)
        XCTAssertEqual(statistics.exportHits, 1)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))

        XCTAssertTrue(PDFComposer.export(items: items, imagePageMode: .fitA4, to: changedURL))
        statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.exportMisses, 2)

        XCTAssertTrue(PDFComposer.export(items: Array(items.reversed()), to: reorderedURL))
        statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.exportMisses, 3)
    }

    func testプレビュー後の事前準備を最初のPDF保存で再利用する() throws {
        let imageURL = try makeImageFile(
            name: "事前準備.png",
            size: CGSize(width: 800, height: 600)
        )
        let item = try XCTUnwrap(SourceItem.make(from: imageURL))
        let outputURL = temporaryDirectory.appendingPathComponent("事前準備済み.pdf")

        XCTAssertTrue(
            PDFComposer.prepareExportCache(
                items: [item],
                cancellationToken: PDFCompositionCancellationToken()
            )
        )
        var statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.exportHits, 0)
        XCTAssertEqual(statistics.exportMisses, 0)

        XCTAssertTrue(PDFComposer.export(items: [item], to: outputURL))
        statistics = PDFComposer.cacheStatistics()
        XCTAssertEqual(statistics.exportHits, 1)
        XCTAssertEqual(statistics.exportMisses, 0)
        XCTAssertEqual(PDFDocument(url: outputURL)?.pageCount, 1)
    }

    func testPDF書き出しの進捗が単調に進み完了する() throws {
        let sourcePDF = try makePDFFile(name: "2ページ.pdf", pageSizes: [
            CGSize(width: 300, height: 400),
            CGSize(width: 400, height: 500)
        ])
        let imageURL = try makeImageFile(
            name: "末尾.png",
            size: CGSize(width: 640, height: 480)
        )
        let items = try [sourcePDF, imageURL].map {
            try XCTUnwrap(SourceItem.make(from: $0))
        }
        let outputURL = temporaryDirectory.appendingPathComponent("進捗確認.pdf")
        let recorder = ProgressRecorder()

        let success = PDFComposer.export(items: items, to: outputURL) { progress in
            recorder.append(progress)
        }
        let updates = recorder.values

        XCTAssertTrue(success)
        XCTAssertEqual(updates.first, .preparing(totalPages: 3))
        XCTAssertEqual(updates.last?.phase, .completed)
        XCTAssertEqual(updates.last?.fractionCompleted, 1)
        XCTAssertTrue(updates.contains { $0.phase == .writing })
        XCTAssertEqual(updates.map(\.fractionCompleted), updates.map(\.fractionCompleted).sorted())
    }

    func testPDFと画像を指定順で結合して書き出す() throws {
        let sourcePDF = try makePDFFile(name: "2ページ.pdf", pageSizes: [
            CGSize(width: 300, height: 400),
            CGSize(width: 400, height: 500)
        ])
        let imageURL = try makeImageFile(
            name: "末尾.png",
            size: CGSize(width: 640, height: 480)
        )
        let items = try [sourcePDF, imageURL].map {
            try XCTUnwrap(SourceItem.make(from: $0))
        }
        let outputURL = temporaryDirectory.appendingPathComponent("結合結果.pdf")

        XCTAssertTrue(PDFComposer.export(items: items, imagePageMode: .fitA4, to: outputURL))

        let exported = try XCTUnwrap(PDFDocument(url: outputURL))
        XCTAssertEqual(exported.pageCount, 3)
        XCTAssertEqual(exported.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 300, accuracy: 0.1)
        XCTAssertEqual(exported.page(at: 1)?.bounds(for: .mediaBox).width ?? 0, 400, accuracy: 0.1)
        XCTAssertEqual(exported.page(at: 2)?.bounds(for: .mediaBox).width ?? 0, 595.28, accuracy: 0.1)

        // PDFBINDER_TEST_OUTPUT指定時のみ、目視確認用の成果物を残す
        if let verificationPath = ProcessInfo.processInfo.environment["PDFBINDER_TEST_OUTPUT"] {
            let verificationURL = URL(fileURLWithPath: verificationPath)
            try? FileManager.default.removeItem(at: verificationURL)
            try FileManager.default.copyItem(at: outputURL, to: verificationURL)
        }
    }

    private func makeImageFile(name: String, size: CGSize) throws -> URL {
        let image = makeImage(size: size)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makePDFFile(name: String, pageSizes: [CGSize]) throws -> URL {
        let document = PDFDocument()
        for (index, size) in pageSizes.enumerated() {
            let page = try XCTUnwrap(PDFPage(image: makeImage(size: size)))
            document.insert(page, at: index)
        }
        let url = temporaryDirectory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func makeImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemBlue.setFill()
        NSRect(
            x: size.width * 0.1,
            y: size.height * 0.1,
            width: size.width * 0.8,
            height: size.height * 0.8
        ).fill()
        image.unlockFocus()
        return image
    }
}

/// Sendableな進捗コールバックからテスト結果を安全に収集する
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PDFExportProgress] = []

    var values: [PDFExportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: PDFExportProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
