import Foundation

/// リストのソート方法。ソート後もユーザーは手動で並び替え可能
enum SortOption: String, CaseIterable, Identifiable {
    case nameAscending = "名前（昇順）"
    case nameDescending = "名前（降順）"
    case dateAscending = "更新日時（古い順）"
    case dateDescending = "更新日時（新しい順）"
    case sizeAscending = "サイズ（小さい順）"
    case sizeDescending = "サイズ（大きい順）"

    var id: String { rawValue }

    /// このソート方法で並び替えた配列を返す
    func sorted(_ items: [SourceItem]) -> [SourceItem] {
        switch self {
        case .nameAscending:
            // Finderと同じ自然順ソート（"2.png" < "10.png"）
            return items.sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .nameDescending:
            return items.sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedDescending
            }
        case .dateAscending:
            return items.sorted { $0.modifiedAt < $1.modifiedAt }
        case .dateDescending:
            return items.sorted { $0.modifiedAt > $1.modifiedAt }
        case .sizeAscending:
            return items.sorted { $0.fileSize < $1.fileSize }
        case .sizeDescending:
            return items.sorted { $0.fileSize > $1.fileSize }
        }
    }
}
