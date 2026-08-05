import SwiftUI
import UniformTypeIdentifiers

/// 左ペイン：結合対象ファイルの一覧（ドラッグで並び替え・ドロップで追加）
struct FileListPane: View {
    @ObservedObject var viewModel: MergeListViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if viewModel.items.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFiles(urls: urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
        }
    }

    /// リスト上部のサマリー表示
    private var header: some View {
        HStack {
            Text("\(viewModel.items.count) ファイル")
                .font(.headline)
            Spacer()
            if !viewModel.items.isEmpty {
                Text("合計 \(viewModel.totalPageCount) ページ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// ファイル一覧（選択・ドラッグ並び替え・Deleteキー削除に対応）
    private var fileList: some View {
        List(selection: $viewModel.selection) {
            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                FileRowView(item: item, order: index + 1)
                    .tag(item.id)
            }
            .onMove { source, destination in
                viewModel.move(from: source, to: destination)
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            viewModel.removeSelected()
        }
    }

    /// ファイル未追加時の空状態表示
    private var emptyState: some View {
        ContentUnavailableView {
            Label("ファイルがありません", systemImage: "doc.on.doc")
        } description: {
            Text("画像やPDFをここにドラッグ＆ドロップするか、\nツールバーの「＋」から追加してください。")
        } actions: {
            Button("ファイルを追加…") {
                viewModel.presentOpenPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ドロップ受け入れ中のハイライト表示
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(6)
            .allowsHitTesting(false)
    }
}

/// リストの1行分の表示
struct FileRowView: View {
    let item: SourceItem
    /// 結合順（1始まり）
    let order: Int

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            thumbnailView

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Label(item.kind.rawValue, systemImage: item.kind.symbolName)
                        .labelStyle(.titleAndIcon)
                    Text("・")
                    Text(item.kind == .pdf ? "\(item.pageCount) ページ" : "1 ページ")
                    Text("・")
                    Text(item.fileSizeText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("ドラッグして並び替え")
        }
        .padding(.vertical, 4)
        .task(id: item.url) {
            thumbnail = await ThumbnailService.shared.thumbnail(for: item.url)
        }
    }

    /// サムネイル（生成完了まではファイル種別アイコンを表示）
    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 52)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }
}
