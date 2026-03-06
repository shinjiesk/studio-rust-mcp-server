# Multi-Instance Roblox Studio MCP Server 改造ガイド

## 目的

`rbx-studio-mcp`（Roblox公式MCP）を改造し、複数のRoblox Studioインスタンスをそれぞれ独立したMCPサーバーで制御できるようにする。最終的に5〜6個のStudioを並列運用する。

## 現状の問題

- `rbx-studio-mcp` はポート **44755** がハードコードされている
- サーバー（Rust）とプラグイン（Luau）の両方に44755が埋まっている
- 2つ目のサーバープロセスは "proxy mode" で1つ目に相乗りするため、Studioの区別ができない

## ソースリポジトリ

**https://github.com/Roblox/studio-rust-mcp-server**（MIT License）

## リポジトリ構造

```
studio-rust-mcp-server/
├── Cargo.toml              # Rust依存関係
├── build.rs                # ビルドスクリプト（プラグインをバイナリに埋め込み）
├── src/
│   ├── main.rs             # エントリポイント、CLIパーサー（clap）
│   ├── rbx_studio_server.rs # WebSocketサーバー（port 44755はここ）
│   ├── install.rs          # プラグインのインストール処理
│   └── error.rs            # エラー型
├── plugin/                 # Roblox Studio プラグイン（Luau）
│   ├── default.project.json # Rojoプロジェクト
│   ├── foreman.toml        # ツールチェイン（Rojo）
│   └── src/
│       ├── Main.server.luau        # プラグイン本体（ポート接続先）
│       ├── Utils/
│       │   └── GlobalVariables.luau # 定数（ポート番号の可能性大）
│       └── Tools/
│           ├── RunCode.luau
│           ├── GetConsoleOutput.luau
│           ├── InsertModel.luau
│           ├── GetStudioMode.luau
│           ├── RunScriptInPlayMode.luau
│           └── StartStopPlay.luau
└── util/                   # 署名・パッケージング
```

## 改造方針

### 1. Rust側：`--port` オプション追加

**`src/main.rs`** — CLIパーサーに `--port <PORT>` を追加：
- デフォルト: 44755（後方互換）
- 例: `rbx-studio-mcp --stdio --port 44756`

**`src/rbx_studio_server.rs`** — サーバーがlistenするポートを引数から受け取るように変更：
- `44755` のハードコードを探し、引数のport値に置き換え

**`src/install.rs`** — プラグインインストール時にポート番号を埋め込み：
- プラグインの.rbxmにポート番号がハードコードされている
- インストール時にポート番号を書き換えてから保存する、またはプラグイン名を変えて複数共存させる

### 2. プラグイン側：ポート設定の外部化

**`plugin/src/Utils/GlobalVariables.luau`** または **`plugin/src/Main.server.luau`**：
- `44755` が定義されている箇所を探す
- プラグイン名にポート番号を含める（例: `MCPStudioPlugin_44756`）ことで、Studio内で区別可能にする

**重要**: プラグインはビルド時に Rojo で `.rbxm` にコンパイルされ、`build.rs` でRustバイナリに埋め込まれる。ポートごとに異なるプラグインを生成する仕組みが必要。

### 3. ビルド

```bash
# Rustツールチェインが必要
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Rojoが必要（プラグインビルド用）
# foreman.toml に記載あり
cargo install foreman
foreman install

# ビルド
cargo build --release
# 成果物: target/release/rbx-studio-mcp
```

### 4. デプロイ（1インスタンスあたり）

```bash
# ポート44756用のサーバーをビルド・配置
cp target/release/rbx-studio-mcp /usr/local/bin/rbx-studio-mcp-44756

# プラグインのインストール（サーバー側が自動で行う場合もある）
# → ~/Documents/Roblox/Plugins/ に配置
```

### 5. Cursor MCP設定

`~/.cursor/mcp.json` にポートごとのエントリを追加：

```json
{
  "mcpServers": {
    "Roblox_Studio": {
      "command": "/path/to/rbx-studio-mcp",
      "args": ["--stdio"]
    },
    "Roblox_Studio_2": {
      "command": "/path/to/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44756"]
    }
  }
}
```

プロジェクトレベル（`.cursor/mcp.json`）で上書きすれば、Cursorインスタンスごとに異なるサーバーを使える。

## 現在の環境情報

- macOS (darwin 25.3.0, arm64)
- 既存バイナリ: `/Applications/RobloxStudioMCP.app/Contents/MacOS/rbx-studio-mcp`
- プラグインフォルダ: `/Users/shinji/Documents/Roblox/Plugins/`
- 既存プラグイン: `MCPStudioPlugin.rbxm`（port 44755）
- Rustツールチェイン: 未確認（要チェック）

## 作業の進め方

1. リポジトリをclone
2. `src/` 内のRustコードを読んで 44755 の定義箇所を特定
3. `plugin/src/` 内のLuauコードを読んで 44755 の定義箇所を特定
4. `--port` CLIオプションを追加
5. プラグインのポート番号をビルド時に注入する仕組みを作る
6. ビルドして動作確認
7. 2つ目のポートで起動し、2つのStudioが独立して操作できることを確認

## 注意

- 署名（`util/sign.macos.sh`）は開発中は不要。ただし macOS Gatekeeper の制約があれば `xattr -cr` で回避
- `build.rs` がプラグインの .rbxm をバイナリに埋め込むので、プラグイン変更後はRustを再ビルドする必要がある
