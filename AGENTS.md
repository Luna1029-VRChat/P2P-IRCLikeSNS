# AGENTS.md

## プロジェクト概要
Godot 4.x GDScript で構築された P2P IRC スタイル SNS。Nostr リレーシグナリング（kind 21000 + kind 0 with `#s="p2p-irc"`）と WebRTC メッシュ接続を使用し、ホスト選出・昇格を行う。ターゲット: Web 書き出し（GitHub Pages）＋ Android ＋ Linux ネイティブ。

## 主要アーキテクチャ

### NostrGD アドオン（`addons/nostr_godot/`）
- 純 GDScript + オプションの C++ GDExtension（`libnostr_crypto.so`）で secp256k1 高速化
- `project.godot` で `NostrGD` として自動ロード
- プリビルド `.so`: `addons/nostr_godot/gdextension/lib/libnostr_crypto.so`
- サブモジュール: `addons/nostr_godot/gdextension/godot-cpp/`
- フォールバック: GDExtension が利用不可の場合（Web 等）は純 GDScript 暗号（`secp256k1.gd`、署名に約1.3秒）
- Web では JavaScriptBridge（@noble/secp256k1 埋め込み）を使用、署名が高速

### 自動ロード（`project.godot`）
- `WebRTCHandler` → `res://WebRTCHandler.gd`
- `NostrGD` → `res://addons/nostr_godot/nostr_gd_client.gd`
- `ChatManager` → `res://scripts/ChatManager.gd`

### シグナル
- `NostrGD.EventReceived` → 2引数: `(subscription_id: String, event_dict: Dictionary)` — `url` パラメータなし
- `WebRTCHandler.state_changed` → `(new_state: int)`
- `NostrGD.Connected` → `(url: String)`
- `NostrGD.Disconnected` → `(url: String)`

### チャットフロー
1. 起動: リレー自動接続、キーペア自動生成、自動購読
2. 盗聴: kind 21000 リレー放送による読み取り専用タイムライン（「参加」前）
3. 参加: kind 0 を `#s="p2p-irc"` 付きで送信、WebRTC メッシュ接続、DataChannel + kind 21000 で送受信
4. ホスト: 最初の参加者がホスト、切断時は次の（`created_at` 順）参加者が昇格
5. リレー: セッション型（切断時にイベント消去）

### リレー
- 本番: `wss://p2p-nostr.yoinekodo.jp`
- ローカル: `ws://localhost:8080`（`docker/` で `docker compose up`）
- セッションスコープ: 切断時に pubkey の全イベントを削除

## 主要な決定事項
- C# は Godot 4 が Web 書き出しに対応していないため断念。Web では純 GDScript + JavaScriptBridge
- NostrGD アドオンは直接コピー（サブモジュールではない）。`.gdextension` のネストパス問題を回避。`godot-cpp` のみサブモジュール
- `build/`、`docs/`、CMake アーティファクト、`libsecp256k1/` は gitignore — 必要に応じて再生成
- GDExtension wasm による Web 暗号化は断念 — 読み込みが成功しなかった
- JavaScriptBridge 暗号化: @noble/secp256k1（8KB ESM バンドル）を GDScript 文字列として埋め込み、eval で注入
- 純 JS の SHA-256 + HMAC-SHA256 実装を埋め込み、noble の同期的 `sign()` をサポート
- Web 書き出しは `addons/nostr_godot/gdextension/*` を除外
- `npm run deploy` → Godot ヘッドレス書き出し → `docs/` に出力 → GitHub Pages

## GDExtension ビルド
```bash
cd addons/nostr_godot/gdextension
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
cp libnostr_crypto.so ../lib/
```

## コーディング規約
- GDScript、2スペースインデント
- シグナル接続は `signal_name.connect(callable)`（文字列ベースの `connect()` は不使用）
- 変数/関数は `snake_case`、enum/定数は `PascalCase`
- Dictionary のキーは文字列（enum キーは不使用）
