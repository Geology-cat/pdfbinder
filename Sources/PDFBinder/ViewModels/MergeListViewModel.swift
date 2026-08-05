import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// ファイルリストとプレビュー生成・書き出しを管理するViewModel
@MainActor
final class MergeListViewModel: ObservableObject {

    /// 結合対象のファイル一覧（表示順 = 結合順）
    @Published private(set) var items: [SourceItem] = [] {
        didSet { schedulePreviewUpdate() }
    }

    /// リストでの選択状態
    @Published var selection: Set<UUID> = []

    /// 並び替えメニューで現在選択されているソート順
    @Published private(set) var selectedSortOption: SortOption? = .nameAscending

    /// プレビュー用に合成したPDF（itemsが空のときはnil）
    @Published private(set) var previewDocument: PDFDocument?

    /// プレビュー生成中かどうか
    @Published private(set) var isGeneratingPreview = false

    /// PDF書き出し中かどうか
    @Published private(set) var isExporting = false

    /// PDF書き出しの進行状況
    @Published private(set) var exportProgress = PDFExportProgress.preparing(totalPages: 0)

    /// 画像をPDFへ変換するときのページサイズ
    @Published var imagePageMode: ImagePageMode = .original {
        didSet { schedulePreviewUpdate() }
    }

    /// 書き出し完了時の通知表示
    @Published private(set) var exportCompletionMessage: String?

    /// 直前に書き出したファイルのURL
    private var exportedFileURL: URL?

    /// エラー表示用メッセージ（nil以外でアラート表示）
    @Published var errorMessage: String?

    /// プレビュー更新のデバウンス用タスク
    private var previewTask: Task<Void, Never>?

    /// 結合後の合計ページ数
    var totalPageCount: Int {
        items.reduce(0) { $0 + $1.pageCount }
    }

    // MARK: - ファイルの追加・削除

    /// URL群からファイルを追加する。非対応の形式はスキップする
    func addFiles(urls: [URL]) {
        var added: [SourceItem] = []
        var skipped: [String] = []
        let wasEmpty = items.isEmpty

        for url in urls {
            if let item = SourceItem.make(from: url) {
                added.append(item)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }

        // ファイル選択APIやFinderから渡される順序には依存せず、
        // 1回の操作で追加したファイルをFinderと同じ自然な名前順にそろえる。
        // 追加済みファイルの手動並び替えは維持するため、新しいまとまりだけをソートする。
        items.append(contentsOf: SortOption.nameAscending.sorted(added))
        if !added.isEmpty {
            // 既存リストへ追加した場合、リスト全体としては特定のソート順ではなくなる。
            selectedSortOption = wasEmpty ? .nameAscending : nil
        }

        if !skipped.isEmpty {
            errorMessage = "対応していない形式のためスキップしました：\n" + skipped.joined(separator: "\n")
        }
    }

    /// ファイル選択パネルを開いて追加する
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "追加するファイルを選択"
        panel.prompt = "追加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]

        if panel.runModal() == .OK {
            addFiles(urls: panel.urls)
        }
    }

    /// 選択中のアイテムを削除する
    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    /// 読み込んだすべてのアイテムをリストからクリアする（元ファイルは削除しない）
    func clearAll() {
        items.removeAll()
        selection.removeAll()
        selectedSortOption = .nameAscending
        ThumbnailService.shared.clearCache()
    }

    // MARK: - 並び替え

    /// ドラッグによる手動並び替え（ListのonMoveから呼ばれる）
    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        selectedSortOption = nil
    }

    /// 指定のソート方法で並び替える。並び替え後も手動での移動は可能
    func sort(by option: SortOption) {
        selectedSortOption = option
        items = option.sorted(items)
    }

    // MARK: - プレビュー

    /// items変更後に300msデバウンスしてプレビューを再生成する
    private func schedulePreviewUpdate() {
        previewTask?.cancel()

        guard !items.isEmpty else {
            previewDocument = nil
            isGeneratingPreview = false
            return
        }

        let snapshot = items
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }

            self.isGeneratingPreview = true
            let imagePageMode = self.imagePageMode
            let document = await Task.detached(priority: .userInitiated) {
                PDFComposer.compose(items: snapshot, imagePageMode: imagePageMode)
            }.value

            guard !Task.isCancelled else { return }
            self.previewDocument = document
            self.isGeneratingPreview = false
        }
    }

    // MARK: - 書き出し

    /// 保存パネルを開いてPDFを書き出す
    func exportPDF() {
        guard !items.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "PDFを保存"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "結合済み.pdf"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = items
        let imagePageMode = imagePageMode
        exportProgress = .preparing(totalPages: totalPageCount)
        isExporting = true
        Task { [weak self] in
            guard let self else { return }

            let (progressStream, progressContinuation) = AsyncStream<PDFExportProgress>.makeStream()
            let exportTask = Task.detached(priority: .userInitiated) {
                let success = PDFComposer.export(
                    items: snapshot,
                    imagePageMode: imagePageMode,
                    to: url
                ) { progress in
                    progressContinuation.yield(progress)
                }
                progressContinuation.finish()
                return success
            }

            for await progress in progressStream {
                self.exportProgress = progress
            }

            let success = await exportTask.value
            self.isExporting = false
            if success {
                self.exportedFileURL = url
                self.exportCompletionMessage = "「\(url.lastPathComponent)」を保存しました。"
            } else {
                self.errorMessage = "PDFの書き出しに失敗しました。"
            }
        }
    }

    /// 完了通知を閉じる
    func dismissExportCompletion() {
        exportCompletionMessage = nil
    }

    /// 直前に書き出したファイルをFinderで表示する
    func revealExportedFile() {
        guard let exportedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedFileURL])
        dismissExportCompletion()
    }
}
