# P2P IRC-like SNS / Nostr P2P チャット

Godot 4.7 (GDScript) で作られた P2P チャットアプリ。

Nostr リレー（kind 21000 + kind 0）でシグナリングし、WebRTC DataChannel で P2P テキストチャット・ファイル転送を行う。

## 機能

- P2P IRC チャット（WebRTC DataChannel + Nostr signaling）
- ホスト自動選出・昇格（最初の参加者がホスト、切断時は `created_at` 順で昇格）
- ルーム検出（kind 0 `#s="p2p-irc"`）
- ファイル転送（PCK 自動ロード対応）
- IPv4/IPv6 デュアルスタック STUN
- クロスプラットフォーム: Linux ネイティブ / Android / Web (GitHub Pages)

## アーキテクチャ

| 層 | 技術 |
|---|---|
| UI | Godot 4.7 Control / GDScript（`window/stretch/scale=2.0`） |
| 署名・鍵管理 | NostrGD アドオン（GDScript + GDExtension / Web では JS ブリッジ） |
| リレー通信 | WebSocket（Nostr プロトコル） |
| P2P 通信 | WebRTC DataChannel（webrtc-native GDExtension / Web ではブラウザ内蔵） |
| シグナリング | kind 21000 `#s="p2p-irc"` + kind 0 `#s="p2p-irc"` |

## 使い方

### 開発環境

```bash
# リレー（Docker）
cd docker && docker compose up

# Godot 4.7 で project.godot を開いて実行
```

### Web 書き出し

```bash
godot --headless --export-release "Web"
# 出力先: docs/ （GitHub Pages）
```

### エクスポート設定

`export_presets.cfg`:
- Web: `exclude_filter="addons/nostr_godot/gdextension/*,addons/webrtc-native/*"`（GDExtension は wasm 非対応のため除外）
- PWA: 有効（サービスワーカーが COOP/COEP ヘッダーを追加）
- スケール: `window/stretch/scale=2.0`, mode=`canvas_items`, aspect=`expand`

## ディレクトリ構成

| パス | 説明 |
|---|---|
| `ChatScene.tscn` | メインシーン（UI レイアウト） |
| `scripts/ChatManager.gd` | P2P IRC チャット管理（autoload） |
| `WebRTCHandler.gd` | WebRTC シグナリング（autoload） |
| `addons/nostr_godot/` | NostrGD アドオン（自動ロード） |
| `addons/webrtc-native/` | WebRTC GDExtension（Linux/Android/iOS/Windows） |
| `icons/` | SVG アイコンセット |
| `docker/` | セッション型 Nostr リレー (Python) |

## ライセンス

MIT
