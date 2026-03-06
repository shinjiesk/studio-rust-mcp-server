# studio-rust-mcp-server アーキテクチャ概要

## プロジェクト概要

Roblox Studio と AI クライアント (Claude Desktop, Cursor 等) を Model Context Protocol (MCP) で接続する Rust 製ブリッジサーバー。AI がRoblox Studio内でコード実行、モデル挿入、プレイモード制御などを行えるようにする。

## 全体アーキテクチャ

```
AI Client (Claude/Cursor)
    ↕ stdio (MCP プロトコル)
Rust MCP Server (rmcp)
    ↕ HTTP long-poll (localhost:44755)
Roblox Studio Plugin (Luau)
```

## ディレクトリ構造

```
├── src/                    # Rust サーバー本体
│   ├── main.rs             # エントリポイント、CLI、サーバー起動
│   ├── rbx_studio_server.rs # MCP ツール定義、HTTP ハンドラ、共有状態
│   ├── error.rs            # axum 用カスタムエラー型
│   └── install.rs          # プラグイン・MCP クライアント自動設定
├── plugin/                 # Roblox Studio プラグイン (Luau)
│   ├── default.project.json # Rojo プロジェクト設定
│   └── src/
│       ├── Main.server.luau         # プラグインエントリポイント
│       ├── MockWebSocketService.luau # HTTP long-poll クライアント
│       ├── Types.luau               # 型定義
│       ├── Tools/                   # ツール実装 (6個)
│       │   ├── RunCode.luau
│       │   ├── InsertModel.luau
│       │   ├── GetConsoleOutput.luau
│       │   ├── GetStudioMode.luau
│       │   ├── StartStopPlay.luau
│       │   └── RunScriptInPlayMode.luau
│       └── Utils/                   # ユーティリティ
│           ├── ConsoleOutput.luau
│           ├── DataModelType.luau
│           ├── GameStopUtil.luau
│           ├── GlobalVariables.luau
│           ├── PluginUtils.luau
│           └── ToolDispatcher.luau
├── build.rs                # ビルドスクリプト (Rojo でプラグイン .rbxm を生成)
├── util/                   # 署名・リリース用スクリプト (macOS/Windows)
├── Cargo.toml
└── README.md
```

---

## Rust サーバー詳細

### main.rs — エントリポイント

- **CLI引数**: `--stdio` (MCP サーバーモード), `--port` (プラグイン接続ポート、デフォルト 44755)
- **引数なし**: インストーラーとして動作 (`install::install()`)
- **`--stdio` あり**: 2つのサーバーを同時起動
  1. **axum HTTP サーバー** (localhost:44755) — Studio プラグインとの通信用
  2. **rmcp MCP サーバー** (stdio) — AI クライアントとの通信用
- ポートが既に使用中の場合、**dud proxy モード**で起動 (後述)

### rbx_studio_server.rs — コアロジック

#### 共有状態 `AppState`

```rust
pub struct AppState {
    process_queue: VecDeque<ToolArguments>,     // コマンドキュー
    output_map: HashMap<Uuid, mpsc::Sender>,    // レスポンス待ちチャネル
    waiter/trigger: watch channel,              // 新コマンド通知
}
```

#### MCP ツール定義 (6個)

| ツール名 | 説明 |
|----------|------|
| `run_code` | Studio でLuauコードを実行し出力を返す |
| `insert_model` | Roblox マーケットプレイスからモデルを挿入 |
| `get_console_output` | Studio コンソール出力を取得 |
| `start_stop_play` | プレイ/停止/サーバーモード制御 |
| `run_script_in_play_mode` | プレイモードでスクリプトを実行（自動停止付き） |
| `get_studio_mode` | 現在のモード取得 (`start_play`/`run_server`/`stop`) |

#### 通信フロー

1. AI クライアント → MCP stdio → `generic_tool_run()` でキューに投入
2. `watch::channel` で新コマンドを通知
3. Studio プラグインが `GET /request` をlong-poll、コマンドを取得
4. プラグインがツールを実行
5. 結果を `POST /response` で送信
6. Rust サーバーが `mpsc::channel` 経由で結果を受け取り、AI に返却

#### HTTP エンドポイント

| メソッド | パス | 用途 |
|----------|------|------|
| GET | `/request` | プラグインがコマンドをlong-poll (15秒タイムアウト、空なら423) |
| POST | `/response` | プラグインが実行結果を返送 |
| POST | `/proxy` | 2番目以降のMCPインスタンスがコマンドを転送 |

### install.rs — インストーラー

- `build.rs` がビルド時に Rojo で生成した `MCPStudioPlugin.rbxm` を `include_bytes!` で埋め込み
- `roblox_install` クレートで Studio のプラグインディレクトリを特定し、`.rbxm` をコピー
- 以下のMCPクライアント設定ファイルに自動登録:
  - **Claude Desktop**: `~/Library/Application Support/Claude/claude_desktop_config.json`
  - **Cursor**: `~/.cursor/mcp.json`
  - **Antigravity (Gemini)**: `~/.gemini/antigravity/mcp_config.json`
  - **Claude Code**: セットアップコマンドを表示
- macOS: `native-dialog` でGUIダイアログ表示、`security-translocate` でApp Translocation対応
- Windows: `cmd /c pause` で結果表示

### error.rs — エラーハンドリング

`color_eyre::Report` を axum の `IntoResponse` に変換するラッパー型。500エラーとしてレスポンスを返す。

### build.rs — ビルドスクリプト

`librojo` (Rojo の Rust ライブラリ) を使って `plugin/` ディレクトリから `MCPStudioPlugin.rbxm` をビルド。`OUT_DIR` に出力し、`include_bytes!` でバイナリに埋め込まれる。

---

## マルチインスタンス対応

複数の AI クライアントが同時に MCP サーバーを起動した場合:

1. **最初のインスタンス**: ポート 44755 をバインドし、HTTP サーバーとして動作
2. **2番目以降のインスタンス**: ポートバインドに失敗 → **dud proxy モード**
   - ローカルキューからコマンドを取り出し、プライマリの `POST /proxy` に転送
   - プライマリがプラグインとの通信を代行し、結果を返す

これにより、1つの Studio プラグインで複数の AI クライアントからのリクエストを処理可能。

---

## Roblox Studio プラグイン詳細

### Main.server.luau — エントリポイント

- `MockWebSocketService` で Rust サーバーに接続 (HTTP long-poll)
- ツールバーに「Toggle MCP」と「MCP Settings」ボタンを作成
- ポート設定はプレイスIDごとに保存 (`placeKey()`) — 複数 Studio インスタンス対応
- `ChangeHistoryService` でツール実行を Undo 可能に記録
- プレイモード中 (`RunService:IsRunning()`) はプラグインを無効化
- サーバーDataModelでは `GameStopUtil.monitorForStopPlay` を起動

### MockWebSocketService.luau — 擬似WebSocketクライアント

Roblox の `HttpService` を使った HTTP long-poll 実装:
- `_OpenImpl`: `GET /request` を繰り返しポーリング
  - 200: メッセージ受信 (`MessageReceived` イベント発火)
  - 423: コマンドなし、即座に再ポーリング
  - エラー: 1秒待って再試行
- `Send`: `POST /response` でJSONを送信
- WebSocket風のイベントAPI (`Opened`, `Closed`, `MessageReceived`)

### ツール実装

#### RunCode.luau
- `loadstring` で任意のLuauコードを実行
- `print`/`warn`/`error` をフックして出力をキャプチャ
- テーブルの再帰的シリアライズ対応（userdata→文字列変換含む）
- 戻り値も `[RETURNED RESULTS]` としてキャプチャ

#### InsertModel.luau
- `InsertService:GetFreeModels()` でマーケットプレイス検索
- 最初の結果を `game:GetObjects()` でロード
- 物理オブジェクト→Model、複数オブジェクト→Folder にまとめる
- カメラ中心のRaycast位置に配置

#### GetConsoleOutput.luau
- `ConsoleOutput.outputMessage` を返すだけのシンプルなツール

#### GetStudioMode.luau
- `GlobalVariables.studioMode` を返す (`"stop"`, `"start_play"`, `"run_server"`)

#### StartStopPlay.luau
- `StudioTestService:ExecutePlayModeAsync/ExecuteRunModeAsync` で制御
- `callWithTimeout` で既にプレイ中のケースを検出 (0.1秒タイムアウト)
- 停止は `GameStopUtil.stopPlay()` を経由（別DataModelへのメッセージング）

#### RunScriptInPlayMode.luau
- テストスクリプトを `ServerScriptService` に注入
- テストスクリプトは: ログキャプチャ、タイムアウト制御、`StudioTestService:EndTest()` で結果を構造化して返す
- 実行後自動的に停止し、テストスクリプトを削除
- 戻り値: `{ success, value, error, logs, errors, duration, isTimeout }`

### ユーティリティ

| モジュール | 役割 |
|-----------|------|
| `ConsoleOutput` | `LogService.MessageOut` を購読、最大10000文字まで蓄積 |
| `DataModelType` | 現在のDataModel種別判定 (Edit/Client/Server) |
| `GameStopUtil` | Edit DataModel→Server DataModel間のメッセージング。プラグイン設定をフラグとして使い、ポーリングで検知 |
| `GlobalVariables` | 共有状態 (`studioMode`) |
| `PluginUtils` | `plugin:GetSetting/SetSetting` のラッパー |
| `ToolDispatcher` | ツール名→ハンドラ関数のレジストリとディスパッチ |

---

## 主要な依存関係

### Rust

| クレート | 用途 |
|---------|------|
| `rmcp` | MCP プロトコル実装 (stdio transport) |
| `axum` | HTTP サーバー (プラグイン通信用) |
| `tokio` | 非同期ランタイム |
| `reqwest` | HTTP クライアント (dud proxy用) |
| `roblox_install` | Studio インストールパス検出 |
| `clap` | CLI引数パース |
| `color-eyre` | エラーハンドリング |
| `uuid` | コマンドID生成 |
| `native-dialog` | macOS GUIダイアログ |
| `security-translocate` | macOS App Translocation対応 |
| `rojo` (ビルド時) | Luauプラグインの .rbxm ビルド |

### Roblox (Luau)

- `HttpService` — HTTP通信
- `StudioTestService` — プレイモード制御
- `InsertService` — マーケットプレイス検索・モデル挿入
- `LogService` — コンソール出力キャプチャ
- `ChangeHistoryService` — Undo/Redo統合

---

## ビルドと実行

```sh
# ビルド（プラグインも自動ビルド）
cargo build --release

# インストーラーとして実行（プラグインインストール + クライアント設定）
cargo run

# MCP サーバーとして実行
cargo run -- --stdio

# カスタムポートで実行
cargo run -- --stdio --port 55000
```

## 注意事項

- README の冒頭に記載のとおり、Roblox 公式の組み込みMCPサーバーに移行済み。このリポジトリはリファレンス実装として残されている。
- `build.rs` で Rojo ビルドが走るため、初回ビルドにはそれなりの時間がかかる。
- macOS では App Translocation によるパス問題を `security-translocate` で解決している。
