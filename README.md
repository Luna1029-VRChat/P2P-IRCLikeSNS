# P2P IRC-like SNS / Nostr クライアント

Godot 4 (GDScript) で作られた Nostr クライアント兼 P2P チャットアプリ。

Nostr リレーで署名・購読し、WebRTC メッシュ接続で P2P チャットを行う。

## 機能

- Nostr プロトコル対応（kind 1 投稿、kind 0 プロフィール）
- マルチリレー接続（設定UIで追加・削除可能）
- グローバルタイムライン表示（最大50件、自動更新）
- プロフィール管理（表示名・バイオグラフィ）
- P2P IRC チャット（WebRTC メッシュ + Nostr signaling）
- ホスト自動昇格（切断時に次の参加者がホストに）
- Web 書き出し対応（GitHub Pages デプロイ）

## アーキテクチャ

| 層 | 技術 |
|---|---|
| UI | Godot 4.7 Control / GDScript |
| 署名・鍵管理 | NostrGD アドオン（GDScript + GDExtension / Webでは JS ブリッジ） |
| リレー通信 | WebSocket |
| P2P 通信 | WebRTC（IPv6, mesh, DataChannel） |
| クロスプラットフォーム | Linux, Android, Web (Emscripten) |

## 使い方

### 開発環境

```bash
# リレー（Docker）
cd docker && docker compose up

# Godot 4.7 で project.godot を開いて実行
```

### Web 書き出し

```bash
# Godot 4.7 ヘッドレスで書き出し
godot --headless --export-release "Web"

# 出力先: docs/ （GitHub Pages）
```

### ビルド設定

`export_presets.cfg`:
- Web: `exclude_filter="addons/nostr_godot/gdextension/*"`（Web では GDExtension 除外）
- PWA: 有効（サービスワーカーが COOP/COEP ヘッダーを追加）

## ディレクトリ構成

| パス | 説明 |
|---|---|
| `main.gd` | メインロジック、UI構築、イベント処理 |
| `scripts/ChatManager.gd` | P2P IRC チャット管理 |
| `WebRTCHandler.gd` | WebRTC シグナリング（autoload） |
| `addons/nostr_godot/` | NostrGD アドオン |
| `addons/webrtc-native/` | WebRTC GDNative |
| `icons/` | SVG アイコンセット |
| `docker/` | セッション型 Nostr リレー (Python) |

## ライセンス

MIT
