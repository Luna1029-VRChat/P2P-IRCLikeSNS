# AGENTS.md

## Project Overview
P2P IRC-style SNS built with Godot 4.x GDScript. Uses Nostr relay signaling (kind 21000 + kind 0 with `#s="p2p-irc"`) and WebRTC mesh connections with host election/promotion. Target: Web export (GitHub Pages).

## Key Architecture

### NostrGD Addon (`addons/nostr_godot/`)
- Pure GDScript with optional C++ GDExtension (`libnostr_crypto.so`) for secp256k1 acceleration
- Autoloaded as `NostrGD` via `project.godot`
- Pre-built `.so` at `addons/nostr_godot/gdextension/lib/libnostr_crypto.so`
- Submodule: `godot-cpp` at `addons/nostr_godot/gdextension/godot-cpp/`
- Fallback: pure GDScript crypto via `secp256k1.gd` (~1.3s per sign) when GDExtension unavailable (e.g. Web)

### Autoloads (`project.godot`)
- `WebRTCHandler` → `res://WebRTCHandler.gd`
- `NostrGD` → `res://addons/nostr_godot/nostr_gd_client.gd`

### Signals
- `NostrGD.EventReceived` emits 2 params: `(subscription_id: String, event_dict: Dictionary)` — no `url` param
- `WebRTCHandler.state_changed` emits `(new_state: int)`
- `NostrGD.Connected` emits `(url: String)`
- `NostrGD.Disconnected` emits `(url: String)`

### Chat Flow
1. Startup: auto-connect relay, auto-generate keypair (via WebRTCHandler), auto-subscribe
2. Eavesdrop: read-only timeline via kind 21000 relay broadcast (before "参加")
3. Join: send kind 0 with `#s="p2p-irc"`, connect WebRTC mesh, send/recv via DataChannel + kind 21000
4. Host: first joiner is host; on disconnect, next (by `created_at`) is promoted
5. Relay: session-based (events purged on disconnect)

### Relay
- Production: `wss://p2p-nostr.yoinekodo.jp`
- Local: `ws://localhost:8080` via `docker compose up` in `docker/`
- Session-scoped: all events from a pubkey deleted on disconnect

## Key Decisions
- Dropped C# because Godot 4 cannot export C# to Web. Pure GDScript + JavaScriptBridge on Web.
- NostrGD addon is copied directly (not a submodule) to avoid nested path issues with `.gdextension`; only `godot-cpp` is a submodule.
- `build/`, `docs/`, CMake artifacts, and `libsecp256k1/` are gitignored — regenerate or fetch as needed.

## GDExtension Building
```bash
cd addons/nostr_godot/gdextension
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
cp libnostr_crypto.so ../lib/
```

## Conventions
- GDScript, 2-space indent
- Signal connections via `signal_name.connect(callable)` (not the string-based `connect()`)
- `snake_case` for variables/functions, `PascalCase` for enums/constants
- String keys in Dictionaries (no enum keys)
