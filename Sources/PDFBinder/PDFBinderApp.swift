import SwiftUI

/// アプリのエントリーポイント
@main
struct PDFBinderApp: App {
    @StateObject private var viewModel = MergeListViewModel()

    var body: some Scene {
        WindowGroup("PDF結合") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("ファイルを開く…") {
                    viewModel.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("PDFを作成…") {
                    viewModel.exportPDF()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel.items.isEmpty || viewModel.isExporting)
            }
        }
    }
}
