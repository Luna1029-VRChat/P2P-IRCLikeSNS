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
2. 検出: kind 0 `#s="p2p-irc"` で既存参加者を検出（`_is_stale_event` は自分以外の pubkey では無視）
3. 参加: 既存ホストがいれば `join`（kind 21000, `#p`+`#s`）を送信 → WebRTC 接続。いなければ自分がホストに
4. ホスト復帰: ホスト変更時はゲストが再 `join` を送信（`_on_host_signal_received` / `_process_discover_event`）
5. ホスト昇格: 切断時は次の（`created_at` 順）参加者が昇格
6. リレー: セッション型（切断時にイベント消去）

### WebRTC（`addons/webrtc-native/`）
- Linux/Android/iOS/Windows では `webrtc-native` GDExtension（libdatachannel ベース）を使用
- `project.godot` の `[native_extensions]` に登録
- Web エクスポート時は除外（wasm 非対応。ブラウザ内蔵 WebRTC を使用）
- STUN: `stun.l.google.com:19302`, `stun1.l.google.com:19302`（IPv4/IPv6 デュアルスタック）
- IPv4 ICE 候補フィルタリングは行わない

### UI スケール
- `window/stretch/scale=2.0`, mode=`canvas_items`, aspect=`expand`
- すべてのフォントサイズ・レイアウトサイズはこの 2x スケール前提で設計
- モバイル判定: ビューポート幅 300px 未満（実効解像度ベース）

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
- Web 書き出しは `addons/webrtc-native/*` も除外（wasm 未対応。ブラウザ内蔵 WebRTC を使用）
- `npm run deploy` → Godot ヘッドレス書き出し → `docs/` に出力 → GitHub Pages
- `webrtc-native` GDExtension はネイティブプラットフォームでのみ有効（`project.godot` の `native_extensions` に登録）
- `_is_stale_event` は自分以外の pubkey では常に `false` を返す（既存参加者のイベントを誤って無視しないため）
- `join` イベントの受信は `p` タグチェックをスキップ（ホストが変わった後の再参加を許容）

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
