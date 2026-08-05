import AppKit
import PDFKit
import XCTest
@testable import PDFBinder

final class PDFBinderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFBinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
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

        let document = PDFComposer.compose(items: [item], imagePageMode: .original)

        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 320, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 240, accuracy: 0.1)
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
