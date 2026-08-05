# PDFBinder 実装引き継ぎドキュメント

macOSネイティブ（SwiftUI + PDFKit）の「画像・PDF結合アプリ」。
**設計と基盤（コア機能一式）は実装・ビルド検証済み**。本ドキュメントは残作業をCodexへ引き継ぐためのもの。

## 0. Codexでの完成状況（2026-08-05）

本引き継ぎ後、製品完成に必要なP1とP2のパッケージング作業を実施済み。

- 画像ページの「A4に収める／原寸」切替を実装
- 書き出し完了通知と「Finderで表示」を実装
- 「ファイルを開く…」（⌘O）と「PDFを作成…」（⌘S）を実装
- PDFKit処理を直列キューへ集約
- 混在PDF・画像、順序、A4、原寸、自然順ソートの自動テストを追加
- 1回の操作で追加した複数ファイルを名前の昇順で自動整列
- 画像ページの初期値を「原寸」に変更
- PDF結合・書き出しのページ単位進捗ウインドウを実装
- 読み込んだファイルを一括で取り除く「すべてクリア」をツールバーへ追加
- ソートメニューで現在選択中の項目へチェックマークを表示
- ImageIOで画像を2048px以内へ縮小する高速プレビューを実装（書き出しは原寸品質）
- プレビュー用1ページPDFのLRUキャッシュと協調キャンセルを実装
- 書き出し開始時のプレビュー停止と、同一内容の完成PDFデータ再利用を実装
- Intel Mac／Apple Silicon両対応のUniversal `.app` ビルドを実装
- Info.plist、アプリアイコン、アドホック署名、起動確認まで完了

完成済みアプリは `dist/PDFBinder.app`。再ビルドは `./scripts/build_app.sh` で行う。
P3のページ編集・Undo/Redo・圧縮などは、完成条件には含めず将来の機能拡張として残している。

## 1. プロジェクト概要

- **目的**: 複数の画像・PDFファイルを読み込み、自由に並び替えて1つのPDFに結合するMacアプリ
- **技術スタック**: Swift 5 / SwiftUI / PDFKit / ImageIO / QuickLookThumbnailing / SwiftPM
- **対応OS**: macOS 14 (Sonoma) 以降
- **ビルド確認済み環境**: Xcode 16.4, Swift 6.1.2（2026-07-14時点）

### ビルド・実行方法

```bash
# CLIから
swift build
.build/debug/PDFBinder

# Xcodeから
# Package.swift をXcodeで開き、PDFBinderスキームを実行
```

## 2. アーキテクチャ（MVVM）

```
Sources/PDFBinder/
├── PDFBinderApp.swift              # @main エントリーポイント（WindowGroup）
├── Models/
│   ├── SourceItem.swift            # 読み込みファイル1件のモデル（種別・サイズ・ページ数）
│   └── SortOption.swift            # ソート方法の定義とソートロジック
├── ViewModels/
│   └── MergeListViewModel.swift    # 唯一のViewModel。リスト管理・プレビュー生成・書き出し
├── Services/
│   ├── PDFComposer.swift           # PDF合成ロジック（純粋関数的なenum）
│   ├── PDFCompositionSupport.swift # 合成条件キー・キャンセルトークン・キャッシュ統計
│   └── ThumbnailService.swift      # QuickLookによるサムネイル生成＋キャッシュ
└── Views/
    ├── ContentView.swift           # ルート。HSplitView（左リスト／右プレビュー）＋ツールバー
    ├── FileListPane.swift          # 左ペイン：一覧・行ビュー・D&D追加・空状態
    └── PreviewPane.swift           # 右ペイン：PDFKitView（NSViewRepresentable）
```

### データフロー

1. ファイル追加（`NSOpenPanel` または Finderからのドロップ）→ `SourceItem.make(from:)` で検証・生成
2. `MergeListViewModel.items` の `didSet` → 300msデバウンス → ImageIOで2048px以内へ縮小・キャッシュ → `PDFComposer.composePreview` → `previewDocument` 更新
3. 並び替えなどで条件が変わると、旧プレビューへ協調キャンセルを通知して不要なページ処理を停止
4. 「PDFを作成」→ 旧プレビューを停止 → 原寸品質で合成・書き出し。同一条件の完成データがあれば再合成せず保存

### 設計上の判断

- **items配列の順序 = 結合順**。ソートは配列を並び替えるだけの操作なので、ソート後の手動ドラッグ並び替えも自然に可能（要件どおり）
- **名前ソートは `localizedStandardCompare`**（Finderと同じ自然順。`2.png` < `10.png`）
- **追加時の自動ソートは新しく追加したまとまりだけ**に適用し、既存ファイルの手動順序は維持
- **画像プレビューは2048px上限**。元のページ寸法を維持し、完成PDFだけ原寸画像から生成する
- **プレビューキャッシュはURL・サイズ・更新日時・画像モード・解像度がキー**。LRU方式で合計128MBまで保持する
- **完成PDFキャッシュは合成条件が完全一致した直前の1件のみ**。256MBを超えるPDFはメモリ保護のため保持しない
- **PDFKit処理は直列のまま協調キャンセル**し、書き出し開始時に不要なプレビューを早期終了する
- **PDFページは `copy()` してから挿入**（元ドキュメントとの所有権問題を回避）
- 画像は `PDFPage(image:)` でそのままページ化（画像サイズがそのままページサイズになる）

## 3. 実装済み機能（動作確認レベル）

| 機能 | 状態 |
|---|---|
| 複数ファイル読み込み（オープンパネル / D&D） | 実装済み・ビルド検証済み |
| 追加した複数ファイルの名前昇順ソート | 実装済み・自動テスト済み |
| 対応形式判定（PDF + `UTType.image` 準拠全形式）・非対応スキップ通知 | 実装済み |
| ドラッグによる手動並び替え（`onMove`） | 実装済み |
| ソート6種（名前↑↓・更新日時↑↓・サイズ↑↓）、選択中チェック、ソート後の手動並び替え | 実装済み・自動テスト済み |
| 結合PDFの高速ライブプレビュー（縮小・LRUキャッシュ・協調キャンセル） | 実装済み・自動テスト済み |
| PDF書き出し（保存パネル → Finder表示・同一内容の完成データ再利用） | 実装済み・自動テスト済み |
| PDF結合・書き出しの進捗ウインドウ | 実装済み・自動テスト済み |
| サムネイル表示（QuickLook、キャッシュ付き） | 実装済み |
| 選択削除（ツールバー / Deleteキー）・すべてクリア | 実装済み・自動テスト済み |
| エラーアラート、空状態表示、ドロップハイライト | 実装済み |

**注意**: `swift build` 成功と起動確認まで実施済み。**実ファイルでのE2E操作確認（D&D・ソート・書き出し）は未実施**なので、最初に一通り手動確認すること。

## 4. 残作業（優先度順）

### P1: 動作確認と仕上げ

1. **E2E手動テスト**: 画像（PNG/JPEG/HEIC）とPDFを混在追加 → 並び替え → ソート → 書き出し、の一連を確認
2. **書き出し完了のフィードバック改善**: 現在は完了アラートとFinder表示。必要に応じて通知やトーストを検討

### P2: アプリとしてのパッケージング

4. **.appバンドル化**: SwiftPM実行形式のままでは配布不可。以下のいずれかで対応
   - Xcodeで新規App projectを作成し `Sources/PDFBinder/` を取り込む（推奨・最も確実）
   - XcodeGen（`project.yml`）や `swift bundler` の利用
   - Info.plist には `CFBundleName`, `NSHumanReadableCopyright` 等を設定。アイコン（AppIcon）作成も必要
5. **サンドボックス対応**（App Store配布や公証をする場合）: `com.apple.security.files.user-selected.read-only` エンタイトルメント。D&Dで受け取ったURLへの継続アクセスにはsecurity-scoped bookmarkが必要になる点に注意
6. **ウィンドウ復元・メニュー整備**: 「ファイル > 開く…」(⌘O)、「保存」(⌘S) をCommandsで追加（`PDFBinderApp.swift` にプレースホルダあり）

### P3: 機能拡張（余力があれば）

7. **ページ単位の操作**: PDF内の特定ページのみ抽出・削除・回転（`SourceItem` を「ファイル」から「ページ範囲」を持つモデルに拡張）
8. **Undo/Redo**: `UndoManager` 連携（並び替え・削除の取り消し）
9. **大量ファイル対策**: プレビューの差分更新、サムネイルの`NSCache`化
10. **書き出しオプション**: 圧縮品質、パスワード保護（`PDFDocumentWriteOption`）
11. **ドラッグでFinderへ書き出し**（リストからのドラッグアウト）
12. **単体テスト**: `SortOption.sorted` と `PDFComposer.compose` はロジックが純粋なのでテスト追加が容易

## 5. 既知の制約・注意点

- **PDFKitのスレッド安全性**: `PDFDocument` の合成は `Task.detached` でバックグラウンド実行しているが、PDFKitは厳密にはスレッドセーフ保証がない。問題が出たら合成を直列キュー1本に集約すること
- **Swift 6言語モードは未使用**（tools-version 5.10）。Strict concurrencyを有効にすると `PDFDocument`（non-Sendable）の受け渡しで警告が出るため、移行時は `@unchecked Sendable` ラッパー等の対応が必要
- **同一ファイルの複数回追加は許容**する設計（`id: UUID` で区別）
- `ThumbnailService` のキャッシュはURLキーの単純なDictionary。ファイル内容が変わっても更新されない
- プレビューの `PDFKitView.updateNSView` はドキュメント差し替え時にスクロール位置がリセットされる（`===` 比較で同一時のみ回避）

## 6. UIデザイン方針

- **標準的なmacOSアプリの作法に従う**: システム標準コントロール、SF Symbols、`ContentUnavailableView`、ツールバー配置（左：追加/削除/並び替え、右：主要アクション「PDFを作成」をprominent表示）
- レイアウト: `HSplitView`。左ペイン340–520pt、右プレビューは可変。最小ウィンドウ 900×560
- リスト行: 結合順の番号 + サムネイル(40×52) + ファイル名 + メタ情報（種別・ページ数・サイズ）+ ドラッグハンドル
- ダークモードはシステムセマンティックカラーのみ使用しているため自動対応
- 文言はすべて日本語。コード内コメントも日本語（ユーザーのCLAUDE.md規約）

## 7. コーディング規約

- 会話・コメント・コミットメッセージは日本語
- ViewModelは `@MainActor`。重い処理（PDF合成）のみ `Task.detached`
- Viewは状態を持たずViewModel経由で操作（行のサムネイル `@State` のみ例外）
