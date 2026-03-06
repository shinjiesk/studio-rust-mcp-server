# Studio MCP Server - Multi-Chat Fork

> [!NOTE]
> 日本語は[こちら](#日本語)

This is a fork of [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) with **multi-chat support for Cursor**.

## Why this fork?

Roblox Studio now ships with a [built-in MCP Server](https://create.roblox.com/docs/studio/mcp). However, the built-in server uses a single connection with a target-switching model (`set_active_studio`), which **does not work with multiple Cursor chat sessions simultaneously**. If two chats try to control different Studio instances, they conflict.

This fork solves that by running **up to 5 independent MCP server instances** on separate ports (44755-44759). Each Cursor chat gets its own dedicated server, enabling true parallel control of multiple Studio instances.

When the official built-in MCP server supports multi-chat natively, this fork will no longer be needed.

## Features

- **Multi-chat parallel control** - Each Cursor chat connects to a separate MCP server, controlling its own Studio instance independently
- **Auto-connect plugin** - The Studio plugin automatically finds and connects to an available server (no manual port selection)
- **Disconnect detection** - Plugin detects server disconnection within seconds and retries automatically
- **Connection notifications** - Cursor receives MCP log notifications when Studio connects or disconnects
- **Immediate error on disconnect** - Tool calls fail immediately if Studio is not connected (no hanging)

## Prerequisites

- [Rust](https://www.rust-lang.org/tools/install)
- [Roblox Studio](https://create.roblox.com/docs/en-us/studio/setup)
- [Cursor](https://www.cursor.com/)

## Setup

### 1. Build

```sh
git clone https://github.com/shinjiesk/studio-rust-mcp-server.git
cd studio-rust-mcp-server
cargo build --release
```

### 2. Install the plugin

Copy the built plugin to your Roblox Studio plugins directory:

```sh
cp target/release/build/rbx-studio-mcp-*/out/MCPStudioPlugin.rbxm \
   ~/Documents/Roblox/Plugins/
```

Or run the installer (also installs the plugin):

```sh
cargo run
```

### 3. Configure Cursor

Add the following to your **project-level** `.cursor/mcp.json`. Replace the command path with your actual build path.

```json
{
  "mcpServers": {
    "Roblox_Studio_1": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44755"]
    },
    "Roblox_Studio_2": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44756"]
    },
    "Roblox_Studio_3": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44757"]
    },
    "Roblox_Studio_4": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44758"]
    },
    "Roblox_Studio_5": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44759"]
    }
  }
}
```

### 4. Enable in Cursor

1. Open Cursor with the project folder containing `.cursor/mcp.json`
2. Go to **Settings > MCP**
3. Enable `Roblox_Studio_1` through `Roblox_Studio_5`

### 5. Open Studio

Open Roblox Studio. The "MCP Status" widget will appear automatically showing the connection status. Each Studio instance connects to its own port.

## Included tools

| Tool | Description |
|------|-------------|
| `run_code` | Run Luau code in Studio and return the output |
| `insert_model` | Insert a model from the Roblox Creator Store |
| `get_console_output` | Get the console output from Studio |
| `start_stop_play` | Start or stop play mode |
| `run_script_in_play_mode` | Run a script in play mode with auto-stop |
| `get_studio_mode` | Get the current Studio mode |

## Architecture

```
Cursor Chat 1  ──stdio──  MCP Server (port 44755)  ──HTTP──  Studio Plugin 1
Cursor Chat 2  ──stdio──  MCP Server (port 44756)  ──HTTP──  Studio Plugin 2
Cursor Chat 3  ──stdio──  MCP Server (port 44757)  ──HTTP──  Studio Plugin 3
  ...                        ...                                ...
```

Each MCP server instance binds to a fixed port. The Studio plugin scans ports 44755-44759, finds an available server, and connects automatically.

## License

MIT License - See [LICENSE](LICENSE) for details.

Based on [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) by Roblox Corporation.

---

<a id="日本語"></a>

# Studio MCP Server - マルチチャット対応 Fork

これは [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server) の fork で、**Cursor のマルチチャットに対応**しています。

## なぜこの fork が必要か

Roblox Studio には[組み込み MCP サーバー](https://create.roblox.com/docs/studio/mcp)が搭載されました。しかし、組み込み版は接続先を切り替える方式（`set_active_studio`）のため、**複数の Cursor チャットから同時に別々の Studio を操作するとコンフリクトが発生します**。

この fork は **最大 5 つの独立した MCP サーバーインスタンス**を別々のポート（44755-44759）で起動することで、各チャットが専用のサーバーを持ち、複数の Studio を並行制御できます。

公式の組み込み MCP サーバーがマルチチャットにネイティブ対応した場合、この fork は役割を終えます。

## 特徴

- **マルチチャット並行制御** - 各 Cursor チャットが別々の MCP サーバーに接続し、独立して Studio を操作
- **プラグイン自動接続** - Studio プラグインが空いているサーバーを自動検出して接続（ポートの手動選択不要）
- **切断検知** - サーバー切断を数秒で検知し、自動リトライ
- **接続通知** - Studio の接続・切断を MCP ログ通知で Cursor に伝達
- **未接続時の即時エラー** - Studio 未接続時のツール呼び出しはハングせず即座にエラーを返す

## 前提条件

- [Rust](https://www.rust-lang.org/tools/install)
- [Roblox Studio](https://create.roblox.com/docs/en-us/studio/setup)
- [Cursor](https://www.cursor.com/)

## セットアップ

### 1. ビルド

```sh
git clone https://github.com/shinjiesk/studio-rust-mcp-server.git
cd studio-rust-mcp-server
cargo build --release
```

### 2. プラグインのインストール

ビルドされたプラグインを Roblox Studio のプラグインディレクトリにコピーします:

```sh
cp target/release/build/rbx-studio-mcp-*/out/MCPStudioPlugin.rbxm \
   ~/Documents/Roblox/Plugins/
```

または、インストーラーを実行します（プラグインも同時にインストールされます）:

```sh
cargo run
```

### 3. Cursor の設定

**プロジェクトレベル**の `.cursor/mcp.json` に以下を追加します。command のパスは実際のビルドパスに置き換えてください。

```json
{
  "mcpServers": {
    "Roblox_Studio_1": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44755"]
    },
    "Roblox_Studio_2": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44756"]
    },
    "Roblox_Studio_3": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44757"]
    },
    "Roblox_Studio_4": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44758"]
    },
    "Roblox_Studio_5": {
      "command": "/path/to/studio-rust-mcp-server/target/release/rbx-studio-mcp",
      "args": ["--stdio", "--port", "44759"]
    }
  }
}
```

### 4. Cursor で有効化

1. `.cursor/mcp.json` があるプロジェクトフォルダを Cursor で開く
2. **Settings > MCP** を開く
3. `Roblox_Studio_1` ~ `Roblox_Studio_5` を全て **Enabled** にする

### 5. Studio を起動

Roblox Studio を開くと「MCP Status」ウィジェットが自動表示され、接続状態が確認できます。各 Studio インスタンスは自動的に別々のポートに接続します。

## 含まれるツール

| ツール | 説明 |
|--------|------|
| `run_code` | Studio で Luau コードを実行し出力を返す |
| `insert_model` | Roblox Creator Store からモデルを挿入 |
| `get_console_output` | Studio のコンソール出力を取得 |
| `start_stop_play` | プレイモードの開始・停止 |
| `run_script_in_play_mode` | プレイモードでスクリプトを実行（自動停止付き） |
| `get_studio_mode` | 現在の Studio モードを取得 |

## アーキテクチャ

```
Cursor Chat 1  ──stdio──  MCP Server (port 44755)  ──HTTP──  Studio Plugin 1
Cursor Chat 2  ──stdio──  MCP Server (port 44756)  ──HTTP──  Studio Plugin 2
Cursor Chat 3  ──stdio──  MCP Server (port 44757)  ──HTTP──  Studio Plugin 3
  ...                        ...                                ...
```

各 MCP サーバーインスタンスは固定ポートにバインドされます。Studio プラグインはポート 44755-44759 をスキャンし、空いているサーバーを見つけて自動接続します。

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) を参照。

[Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server)（Roblox Corporation）をベースにしています。
