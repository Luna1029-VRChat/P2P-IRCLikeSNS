# P2P IRC-like SNS

A peer-to-peer chat application built with Godot 4 (GDScript), using Nostr relay signaling and WebRTC mesh connections.

## Architecture

- **Nostr signaling**: kind-21000 events on a session-based relay for WebRTC signaling
- **WebRTC mesh**: `webrtc-native` GDNative addon for direct peer-to-peer data channels
- **Host election**: automatic host promotion when the current host disconnects
- **Session-scoped relay**: events are auto-purged from the relay on disconnect

## Getting Started

### Prerequisites
- Godot 4.4+ (GL Compatibility renderer)
- Docker (for local relay)

### Run locally

```bash
# Start the session-based Nostr relay
cd docker && docker compose up

# Open project.godot in Godot, then run the scene
```

### Production relay
The app connects to `wss://p2p-nostr.yoinekodo.jp` by default (defined in `scripts/ChatManager.gd`).

## Building for Web

```bash
# Export via Godot Editor → Project → Export → Web
# Output goes to docs/ for GitHub Pages deployment
```

## Structure

| Path | Description |
|---|---|
| `scripts/ChatManager.gd` | Main session logic, host election, chat send/recv |
| `WebRTCHandler.gd` | WebRTC/Nostr signaling singleton (autoload) |
| `addons/nostr_godot/` | NostrGD addon (GDScript + optional GDExtension) |
| `addons/webrtc-native/` | WebRTC GDNative addon |
| `docker/` | Session-based Nostr relay (Python) |
| `ChatScene.tscn` | Main scene |

## Nostr Events

- **kind 21000**: WebRTC signaling (join, offer, answer, ICE candidates)
- **kind 0**: Profile metadata with `#s="p2p-irc"` tag
- **kind 1**: Chat messages
- **sub tag**: `#s="p2p-irc"` on all events for room scoping

## License

MIT
