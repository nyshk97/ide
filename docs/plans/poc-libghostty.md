# PoC: Swift + libghostty + SwiftUI 動作検証

## 目的

[REQUIREMENTS.md](../../REQUIREMENTS.md) の想定スタック「Swift + libghostty + SwiftUI」が実現可能かを最小実装で検証する。

ここを通過しないと自作IDEの本格実装に入れない（撤退ラインを超えたら Tauri 路線にフォールバック）。

---

## スコープ

### やること
- SwiftUI プロジェクトの初期化
- libghostty の組み込み
- **1タブだけのターミナル**を表示し、入力・出力が動く状態を作る
- Ghostty 設定（`~/.config/ghostty/config`）の継承を確認
- cmux のソースを参考資料として読みつつ進める

### やらないこと（PoC 範囲外）
- 複数タブ・複数ペイン
- ファイルツリー・プレビュー・サイドバー
- AI種別バッジ・BEL通知
- キーバインド（Ctrl+M 等）
- 本実装で必要な要件全般（PoC通過後の話）

---

## 撤退判断ライン

**着手から1週間（実働ベース）で1タブのターミナルが動かなければ Tauri にフォールバック**。

具体的な撤退シグナル：
- libghostty のビルド・リンクで2日以上詰まる
- ターミナル描画は動くが入力イベントが届かない/化ける
- Ghostty config の継承方法が判明しない

逆に、上記がクリアできたら Swift 路線で本実装に進む（ファイル系UI・複数ペイン等は別途プラン化）。

---

## ステップ

### 1. cmux ソース調査（半日〜1日）
- [ ] cmux のリポジトリ URL を確定する（Zenn記事 or 検索で）
- [ ] cmux を clone してビルドできる状態にする
- [ ] cmux の libghostty 統合部分を読んで構造を把握:
  - libghostty をどう依存に入れているか（SPM or 手動 or バイナリ埋め込み）
  - Terminal View 相当のラッパーをどう実装しているか
  - PTY 起動・サイズ変更・入力イベントの取り回し
  - 設定ファイル読み込みのコード経路
- [ ] 参照すべきファイル一覧をメモ

### 2. SwiftUI プロジェクト初期化（半日）
- [ ] Xcode で新規 macOS App プロジェクトを作成
- [ ] プロジェクト名・bundle ID 決定
- [ ] Swift Package Manager 経由 or 手動で libghostty を追加できる準備
- [ ] 最小限のウィンドウが起動することを確認

### 3. libghostty 組み込み（1〜2日）
- [ ] cmux と同じ方式で libghostty を依存に入れる
- [ ] ビルド・リンクが通る状態に
- [ ] libghostty の最小 API（インスタンス生成、レンダリング、入力受付）を呼び出せることを確認

### 4. 1タブのターミナル表示（1〜2日）
- [ ] SwiftUI View（または NSViewRepresentable）として Terminal View を作成
- [ ] PTY を起動して `$SHELL -l` を実行
- [ ] 出力がターミナルに描画される
- [ ] キー入力がシェルに渡る
- [ ] ウィンドウリサイズに追従

### 5. Ghostty 設定継承の確認（半日）
- [ ] `~/.config/ghostty/config` のフォント・カラースキームが反映される
- [ ] 反映されない場合、libghostty の API で読み込ませる方法を特定

### 6. 動作確認（VERIFY 風）
- [ ] `claude` コマンドを起動して TUI が崩れずに動作する
- [ ] `vim` を開いて画面遷移が正常
- [ ] `fzf` を実行してインタラクティブ動作する
- [ ] 256色・True Color の表示確認

### 7. 判断
- [ ] PoC 成功 → 本実装プラン（次のplan）の作成へ
- [ ] PoC 失敗 → REQUIREMENTS.md の想定スタックを Tauri に切替、フォールバックプラン作成

---

## 想定リスクと対策

| リスク | 兆候 | 対策 |
|---|---|---|
| libghostty のビルドが通らない | リンクエラー、ヘッダー不足 | cmux のビルド設定を完全コピー |
| Swift 未経験で詰まる | API の使い方がわからない | Claude Code に都度聞く、cmux のコードをそのまま流用 |
| libghostty API が C ベースで Swift bridging が複雑 | 型変換でハマる | cmux のラッパーを参考、もしくは ObjC ブリッジ |
| Ghostty config の場所・読込み API が判らない | 設定が反映されない | Ghostty 本体のソースを参照、フォールバックでハードコード |

---

## ログ
（実装中の方針変更・想定外の失敗を1件10行以内で追記）
