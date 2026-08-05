import Foundation

/// 画像をPDFページへ変換するときのページサイズ
enum ImagePageMode: String, CaseIterable, Identifiable {
    case fitA4 = "A4に収める"
    case original = "原寸"

    var id: String { rawValue }
}
