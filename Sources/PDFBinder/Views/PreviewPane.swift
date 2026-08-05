import PDFKit
import SwiftUI

/// 右ペイン：結合結果のPDFプレビュー
struct PreviewPane: View {
    @ObservedObject var viewModel: MergeListViewModel

    var body: some View {
        ZStack {
            if let document = viewModel.previewDocument, document.pageCount > 0 {
                PDFKitView(document: document)
            } else {
                emptyState
            }

            if viewModel.isGeneratingPreview {
                generatingIndicator
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// プレビュー対象がないときの表示
    private var emptyState: some View {
        ContentUnavailableView {
            Label("プレビュー", systemImage: "eye")
        } description: {
            Text("ファイルを追加すると、結合後のPDFが\nここにプレビュー表示されます。")
        }
    }

    /// プレビュー生成中のインジケータ（右上に小さく表示）
    private var generatingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("プレビューを更新中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
            }
            Spacer()
        }
    }
}

/// PDFKitのPDFViewをSwiftUIで使うためのラッパー
struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // 同一ドキュメントの再設定を避ける（スクロール位置の維持のため）
        if view.document !== document {
            view.document = document
        }
    }
}
