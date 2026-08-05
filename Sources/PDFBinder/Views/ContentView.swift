import SwiftUI

/// メイン画面：左にファイルリスト、右にプレビューの2ペイン構成
struct ContentView: View {
    @ObservedObject var viewModel: MergeListViewModel

    var body: some View {
        HSplitView {
            FileListPane(viewModel: viewModel)
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)

            PreviewPane(viewModel: viewModel)
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        .toolbar { toolbarContent }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isExporting },
                set: { _ in }
            )
        ) {
            ExportProgressView(progress: viewModel.exportProgress)
                .interactiveDismissDisabled()
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            "書き出し完了",
            isPresented: Binding(
                get: { viewModel.exportCompletionMessage != nil },
                set: { if !$0 { viewModel.dismissExportCompletion() } }
            )
        ) {
            Button("Finderで表示") {
                viewModel.revealExportedFile()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.exportCompletionMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                viewModel.presentOpenPanel()
            } label: {
                Label("ファイルを追加", systemImage: "plus")
            }
            .help("画像またはPDFを追加")

            Button {
                viewModel.removeSelected()
            } label: {
                Label("選択を削除", systemImage: "minus")
            }
            .disabled(viewModel.selection.isEmpty)
            .help("選択したファイルをリストから削除")

            Menu {
                ForEach(SortOption.allCases) { option in
                    Button(option.rawValue) {
                        viewModel.sort(by: option)
                    }
                }
                Divider()
                Button("すべて削除", role: .destructive) {
                    viewModel.removeAll()
                }
                .disabled(viewModel.items.isEmpty)
            } label: {
                Label("並び替え", systemImage: "arrow.up.arrow.down")
            }
            .help("ファイルを並び替え")

            Picker("画像ページ", selection: $viewModel.imagePageMode) {
                ForEach(ImagePageMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .help("画像をA4に収めるか、元のサイズで配置するかを選択")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.exportPDF()
            } label: {
                if viewModel.isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("PDFを作成", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.items.isEmpty || viewModel.isExporting)
            .help("結合したPDFを保存")
        }
    }
}

/// PDF結合・書き出し中に表示する進捗ウインドウ
private struct ExportProgressView: View {
    let progress: PDFExportProgress

    private var percentageText: String {
        "\(Int((progress.fractionCompleted * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text("PDFを作成中")
                        .font(.headline)
                    Text("結合と保存が終わるまでお待ちください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(.linear)

            HStack {
                Text(progress.statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentageText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .padding(28)
        .frame(width: 420)
    }
}
