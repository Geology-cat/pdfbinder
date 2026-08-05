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

    /// 同期的なPDF合成処理へキャンセル要求を伝えるトークン
    private var previewCancellationToken: PDFCompositionCancellationToken?

    /// 現在表示しているプレビューの合成条件
    private var previewDocumentKey: PDFCompositionKey?

    /// プレビュー確定後に原寸品質の完成PDFを事前準備するタスク
    private var exportPreparationTask: Task<Void, Never>?

    /// 完成PDFの事前準備へキャンセル要求を伝えるトークン
    private var exportPreparationCancellationToken: PDFCompositionCancellationToken?

    /// 現在事前準備している完成PDFの合成条件
    private var exportPreparationKey: PDFCompositionKey?

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
        cancelPreviewGeneration()
        cancelExportPreparation()
        items.removeAll()
        selection.removeAll()
        selectedSortOption = .nameAscending
        ThumbnailService.shared.clearCache()
        PDFComposer.clearCaches()
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
        cancelPreviewGeneration()
        cancelExportPreparation()

        guard !items.isEmpty else {
            previewDocument = nil
            previewDocumentKey = nil
            isGeneratingPreview = false
            return
        }

        let snapshot = items
        let imagePageMode = imagePageMode
        let compositionKey = PDFCompositionKey(
            items: snapshot,
            imagePageMode: imagePageMode
        )
        let cancellationToken = PDFCompositionCancellationToken()
        previewCancellationToken = cancellationToken

        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self,
                  self.previewCancellationToken === cancellationToken,
                  !cancellationToken.isCancelled else {
                return
            }

            self.isGeneratingPreview = true
            let document = await Task.detached(priority: .userInitiated) {
                PDFComposer.composePreview(
                    items: snapshot,
                    imagePageMode: imagePageMode,
                    cancellationToken: cancellationToken
                )
            }.value

            guard self.previewCancellationToken === cancellationToken else { return }
            self.previewTask = nil
            self.previewCancellationToken = nil
            self.isGeneratingPreview = false

            guard !cancellationToken.isCancelled,
                  let document,
                  self.currentCompositionKey == compositionKey else {
                return
            }
            self.previewDocument = document
            self.previewDocumentKey = compositionKey
            self.startExportPreparation(
                items: snapshot,
                imagePageMode: imagePageMode,
                compositionKey: compositionKey
            )
        }
    }

    /// 待機中・実行中のプレビュー生成を協調的に停止する
    private func cancelPreviewGeneration() {
        previewTask?.cancel()
        previewTask = nil
        previewCancellationToken?.cancel()
        previewCancellationToken = nil
        isGeneratingPreview = false
    }

    /// 原寸品質の完成PDFを低優先度で事前準備する
    private func startExportPreparation(
        items: [SourceItem],
        imagePageMode: ImagePageMode,
        compositionKey: PDFCompositionKey
    ) {
        cancelExportPreparation()

        let cancellationToken = PDFCompositionCancellationToken()
        exportPreparationCancellationToken = cancellationToken
        exportPreparationKey = compositionKey

        let workerTask = Task.detached(priority: .utility) {
            PDFComposer.prepareExportCache(
                items: items,
                imagePageMode: imagePageMode,
                cancellationToken: cancellationToken
            )
        }
        exportPreparationTask = Task { [weak self] in
            _ = await workerTask.value
            guard let self,
                  self.exportPreparationCancellationToken === cancellationToken else {
                return
            }
            self.exportPreparationTask = nil
            self.exportPreparationCancellationToken = nil
            self.exportPreparationKey = nil
        }
    }

    /// 条件が変わった完成PDFの事前準備を停止する
    private func cancelExportPreparation() {
        exportPreparationTask?.cancel()
        exportPreparationTask = nil
        exportPreparationCancellationToken?.cancel()
        exportPreparationCancellationToken = nil
        exportPreparationKey = nil
    }

    /// 現在のファイル順・内容・画像モードを表す合成条件
    private var currentCompositionKey: PDFCompositionKey {
        PDFCompositionKey(items: items, imagePageMode: imagePageMode)
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

        // 書き出しを古いプレビュー処理より優先する。
        cancelPreviewGeneration()
        let snapshot = items
        let imagePageMode = imagePageMode
        let exportKey = PDFCompositionKey(items: snapshot, imagePageMode: imagePageMode)
        if exportPreparationKey != exportKey {
            cancelExportPreparation()
        }
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

            // 書き出し開始時に未完成のプレビューを止めた場合だけ再生成する。
            if self.previewDocumentKey != self.currentCompositionKey,
               self.previewCancellationToken == nil {
                self.schedulePreviewUpdate()
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
