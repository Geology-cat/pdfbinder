# PDFBinder

複数の画像・PDFファイルを結合して1つのPDFを作成するmacOSネイティブアプリ（SwiftUI + PDFKit）。

## 主な機能

- 画像（PNG / JPEG / HEIC など）とPDFの複数読み込み（ファイル選択・ドラッグ＆ドロップ）
- ドラッグによる自由な並び替え＋名前・更新日時・サイズでのソート（ソート後の手動並び替えも可能）
- 結合結果のライブプレビュー
- 画像ページを「A4に収める／原寸」から選択
- 1つのPDFとして書き出し
- ファイルを開く（⌘O）・PDFを作成（⌘S）のメニュー操作

## 動作環境

- macOS 14 (Sonoma) 以降
- ビルドには Xcode 16 以降

## アプリのビルド

```bash
./scripts/build_app.sh
open dist/PDFBinder.app
```

生成物は `dist/PDFBinder.app` です。Intel MacとApple Siliconの両方で動作するUniversal Binaryとして、ローカル実行用にアドホック署名されます。

## 開発とテスト

```bash
swift build
swift test
.build/debug/PDFBinder
```

または `Package.swift` をXcodeで開いて実行できます。

## 配布用DMGの作成

```bash
./scripts/build_dmg.sh
```

`dist/PDFBinder-1.0.1.dmg` が生成されます。DMGにはUniversal版アプリ、使い方ガイド、初回起動準備AppleScript、Applicationsフォルダへのショートカットが含まれます。

初回起動準備AppleScriptは、`/Applications/PDFBinder.app` の隔離属性だけを解除します。Mac全体のGatekeeper設定は変更しません。

## 開発引き継ぎ

実装状況・アーキテクチャ・残作業は [HANDOFF.md](HANDOFF.md) を参照。
