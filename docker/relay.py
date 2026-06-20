#!/usr/bin/env python3
"""Session-based Nostr relay for p2p-irc.

When a client disconnects, ALL events (kind 0, 21000, etc.) from that
pubkey are purged from the relay.  This gives a session-scoped chat:
when you leave, your messages and profile disappear.
"""

import asyncio
import json
import logging
import time
from collections import defaultdict
from typing import Any

import websockets
from websockets.asyncio.server import ServerConnection
from websockets.exceptions import ConnectionClosed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("relay")

HOST = "0.0.0.0"
PORT = 8080

# ---------------------------------------------------------------------------
# Event store
# ---------------------------------------------------------------------------

class EventStore:
    """In-memory event store with per-pubkey tracking."""

    def __init__(self) -> None:
        self._events: dict[str, dict[str, Any]] = {}       # event_id → event
        self._by_pubkey: dict[str, set[str]] = defaultdict(set)  # pubkey → {event_id}
        self._conn_count: dict[str, int] = defaultdict(int)      # pubkey → active WS count

    def add_connection(self, pubkey: str) -> None:
        self._conn_count[pubkey] += 1

    def remove_connection(self, pubkey: str) -> int:
        self._conn_count[pubkey] = max(0, self._conn_count[pubkey] - 1)
        return self._conn_count[pubkey]

    def put(self, event: dict[str, Any]) -> str | None:
        eid = event.get("id", "")
        if not eid:
            return "missing id"
        self._events[eid] = event
        pubkey = event.get("pubkey", "")
        self._by_pubkey[pubkey].add(eid)
        return None

    def delete_pubkey(self, pubkey: str) -> list[str]:
        """Delete all events from *pubkey* and return their ids."""
        eids = self._by_pubkey.pop(pubkey, set())
        for eid in eids:
            self._events.pop(eid, None)
        log.info("Purged %d events for pubkey=%s", len(eids), pubkey[:12])
        return list(eids)

    def query(self, filters: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Return events matching the given Nostr filters."""
        results: list[dict[str, Any]] = []
        seen: set[str] = set()
        for fil in filters:
            for ev in self._match(fil):
                eid = ev.get("id", "")
                if eid not in seen:
                    seen.add(eid)
                    results.append(ev)
        results.sort(key=lambda e: e.get("created_at", 0), reverse=True)
        limit = None
        for fil in filters:
            l = fil.get("limit")
            if l is not None:
                limit = min(limit, l) if limit is not None else l
        if limit is not None:
            results = results[:limit]
        return results

    def _match(self, fil: dict[str, Any]) -> list[dict[str, Any]]:
        candidates = list(self._events.values())

        kinds = fil.get("kinds")
        if kinds is not None:
            candidates = [e for e in candidates if e.get("kind") in kinds]

        authors = fil.get("authors")
        if authors is not None:
            candidates = [e for e in candidates if e.get("pubkey") in authors]

        ids = fil.get("ids")
        if ids is not None:
            candidates = [e for e in candidates if e.get("id") in ids]

        for key, val in fil.items():
            if key.startswith("#") and len(key) == 2:
                tag_name = key[1]
                tag_vals = val if isinstance(val, list) else [val]
                candidates = [
                    e for e in candidates
                    if self._has_tag(e, tag_name, tag_vals)
                ]

        return candidates

    @staticmethod
    def _has_tag(event: dict, tag_name: str, values: list[str]) -> bool:
        tags = event.get("tags", [])
        for t in tags:
            if isinstance(t, list) and len(t) >= 2 and t[0] == tag_name and t[1] in values:
                return True
        return False


# ---------------------------------------------------------------------------
# Connection registry for broadcast
# ---------------------------------------------------------------------------

_registry: dict[ServerConnection, str | None] = {}
store = EventStore()


async def broadcast_event(event: dict, sender: ServerConnection) -> None:
    """Send EVENT to all connected clients except *sender*."""
    payload = json.dumps(["EVENT", "_", event])
    for conn in list(_registry.keys()):
        if conn is sender:
            continue
        try:
            await conn.send(payload)
        except Exception:
            _registry.pop(conn, None)


# ---------------------------------------------------------------------------
# Client handler
# ---------------------------------------------------------------------------

async def handle_client(ws: ServerConnection) -> None:
    pubkey: str | None = None
    subs: dict[str, list[dict]] = {}

    log.info("New connection from %s", ws.remote_address)

    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(msg, list) or len(msg) < 2:
                continue

            cmd = msg[0]

            if cmd == "EVENT":
                event = msg[1]
                err = store.put(event)
                eid = event.get("id", "")
                if err:
                    await ws.send(json.dumps(["OK", eid, False, err]))
                else:
                    pk = event.get("pubkey", "")
                    if pubkey is None:
                        pubkey = pk
                        store.add_connection(pubkey)
                        _registry[ws] = pubkey
                    await ws.send(json.dumps(["OK", eid, True, ""]))
                    await broadcast_event(event, ws)

            elif cmd == "REQ":
                sub_id = msg[1]
                filters = msg[2:]
                subs[sub_id] = filters
                past = store.query(filters)
                for ev in past:
                    await ws.send(json.dumps(["EVENT", sub_id, ev]))
                await ws.send(json.dumps(["EOSE", sub_id]))

            elif cmd == "CLOSE":
                sub_id = msg[1]
                subs.pop(sub_id, None)

    except ConnectionClosed:
        pass
    finally:
        if pubkey:
            remaining = store.remove_connection(pubkey)
            log.info(
                "Client left pubkey=%s remaining_connections=%d",
                pubkey[:12], remaining,
            )
            if remaining == 0:
                store.delete_pubkey(pubkey)
        _registry.pop(ws, None)
        log.info("Connection closed from %s", ws.remote_address)


async def main() -> None:
    log.info("Starting session-based Nostr relay on %s:%d", HOST, PORT)
    async with websockets.serve(
        handle_client,
        HOST,
        PORT,
        ping_interval=30,
        ping_timeout=10,
    ):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
