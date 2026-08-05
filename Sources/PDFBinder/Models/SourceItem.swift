import Foundation
import UniformTypeIdentifiers
import PDFKit

/// 読み込んだファイルの種別
enum SourceKind: String, Hashable, Sendable {
    case image = "画像"
    case pdf = "PDF"

    /// リスト行に表示するSF Symbol名
    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        }
    }
}

/// 結合対象の1ファイルを表すモデル
struct SourceItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let kind: SourceKind
    /// ファイルサイズ（バイト）
    let fileSize: Int
    /// 最終更新日時
    let modifiedAt: Date
    /// ページ数（画像は常に1）
    let pageCount: Int

    var fileName: String { url.lastPathComponent }

    /// 表示用のファイルサイズ文字列
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    /// URLからSourceItemを生成する。対応していない形式の場合はnilを返す
    static func make(from url: URL) -> SourceItem? {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let contentType = values.contentType else {
            return nil
        }

        let kind: SourceKind
        let pageCount: Int
        if contentType.conforms(to: .pdf) {
            kind = .pdf
            // CGPDFDocumentはページ数取得のみなので軽量
            pageCount = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
            guard pageCount > 0 else { return nil }
        } else if contentType.conforms(to: .image) {
            kind = .image
            pageCount = 1
        } else {
            return nil
        }

        return SourceItem(
            id: UUID(),
            url: url,
            kind: kind,
            fileSize: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            pageCount: pageCount
        )
    }
}
