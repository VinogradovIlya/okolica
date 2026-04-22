# Spec: Okolica MVP — LAN Mesh Chat

**ID:** 001-mesh-chat-mvp
**Status:** **Finalized** — ready for /plan
**Version:** 2.0
**Supersedes:** v1 draft (pre-review)
**Target:** local development, single office LAN, Python 3.11+, asyncio

---

## 1. Intent

A desktop terminal chat for colleagues on the same local network. Each person clones
the repo and runs `okolica`. Instances discover each other via mDNS and gossip messages
peer-to-peer over UDP. There is no server — every node is equal. Works without internet
as long as participants are on the same Wi-Fi / VLAN.

The immediate use case: Sber office colleagues who want a backup channel when external
messengers are blocked. The longer-term vision: a mesh chat that could work under
broader network restrictions, with encryption added in v2.

MVP is deliberately minimal: one public channel (`#general`), CLI only, no encryption,
no file transfer, no reactions, no DMs.

---

## 2. User stories

As a user, I can:

- Run `okolica` in my terminal and join the local chat without any configuration.
- Type a message and press Enter; it appears in my terminal and in others' terminals.
- Scroll back through the last 100 messages the chat has seen.
- Quit with Ctrl+C cleanly.
- Restart and see recent messages that arrived while I was offline (if any peer saved them).
- Use the same nickname across restarts without re-typing it.
- See a clear indication when I am offline and messages are being queued.

---

## 3. Functional requirements

### Identity and first-run

- **FR-1** On first run, the app prompts for a nickname (1–32 chars, trimmed,
  non-empty, Unicode allowed).
- **FR-2** A 4-digit discriminator (1000–9999, uniform random) is generated and
  combined with the nickname: display form is `nick#NNNN`.
- **FR-3** Identity (nick, discriminator, author_id UUID) is persisted to
  `~/.okolica/config.json` and reused on subsequent runs.
- **FR-4** Deleting `~/.okolica/config.json` is an explicit reset — next run creates a
  new identity. This is not advertised as a feature, just not prevented.

### Discovery

- **FR-5** On startup, the app registers itself via mDNS under the service type
  `_okolica._udp.local.`, TXT record including `author_id` and `nick#NNNN`.
- **FR-6** The app continuously listens for other `_okolica._udp.` services on the
  LAN and maintains a live peer list (set of `(author_id, ip, port)`).
- **FR-7** When a peer disappears from mDNS (service unregistered or TTL expires),
  it is removed from the peer list.
- **FR-8** Two instances on the same machine are treated as distinct peers (they
  have different `author_id`). This is the canonical way to test locally.

### Messaging (gossip)

- **FR-9** Sending a message: the app creates a `Message` record with fields `id`
  (uuid4), `author_id`, `author_nick`, `content`, `created_at` (UTC now at send
  time), stores it locally, then sends a UDP datagram containing the
  JSON-serialized message to each known peer.
- **FR-10** Receiving a message: the app deserializes, looks up `id` in local
  store; if already seen, ignore; if new, persist and render to UI, then forward
  to every peer that is not `author_id` and not the sender (gossip propagation).
- **FR-11** Forwarding carries the original `id` — IDs are stable across hops.
  This is what enables dedupe on a mesh.
- **FR-12** Maximum message content size is 2000 Unicode characters. Oversized
  messages are rejected at input time with a UI error (not truncated silently).
- **FR-13** All outgoing payloads pass through `MessageEncryptor.encrypt` before
  hitting the transport; all incoming payloads pass through `decrypt` before
  deserialization. In MVP, both are no-ops (`NullEncryptor`).

### Ordering

- **FR-14** Messages are **always** sorted by `(created_at, id)` — ascending —
  when stored, when merged, and when displayed. `id` is a UUID and serves as a
  deterministic tiebreaker when `created_at` is identical.
- **FR-15** `received_at` is stored for debugging (seeing when a message actually
  reached this node vs when its author sent it) but is **never** used in sort
  order. Different nodes may have different `received_at` for the same message;
  that's why it can't be used as a shared ordering key.

### History

- **FR-16** Local history is capped at the last 100 messages, ordered by
  `(created_at, id)`. Messages beyond 100 are pruned on insert.
- **FR-17** On startup, the app queries up to 3 randomly chosen online peers via
  a `HISTORY_REQUEST` control message; each responds with their local last-100.
- **FR-18** Received histories are merged with local history: dedupe by `id`,
  sort by `(created_at, id)`, keep the last 100.
- **FR-19** History request has a 3-second overall timeout. Peers not responding
  in time are ignored. If zero peers respond, startup continues with whatever
  local history exists.
- **FR-20** `HISTORY_RESPONSE` always contains exactly the last 100 messages from
  the responder's local store (or fewer if it has fewer). No parameters in the
  request to vary this.

### Outbound queue

- **FR-21** If the peer list is empty when a user sends a message, the message is
  stored in an in-memory outbound queue (FIFO).
- **FR-22** The outbound queue has a hard cap of **10 messages**. When the 11th
  send is attempted while offline, the UI shows an error: "You are offline. 10
  messages pending. Reconnect to continue." The 11th message is **not** added to
  the queue.
- **FR-23** When a peer becomes known (mDNS discovery transitions peer count
  from 0 to ≥1), the outbound queue is flushed to all known peers in insertion
  order, and the internal offline counter resets to zero. Subsequent offline
  periods start fresh.
- **FR-24** The outbound queue is not persisted across restarts. Application
  restart with queued messages = messages lost. README must document this.

### UI (Textual CLI)

- **FR-25** Top pane: scrollable message list. Each line renders as
  `HH:MM author#NNNN: content`. Long content wraps. Times shown in the user's
  local timezone.
- **FR-26** Bottom pane: single-line input field. Enter sends. Ctrl+C quits.
- **FR-27** Status line: shows count of currently known peers (`3 peers online`)
  and queue depth if non-zero (`2 pending`). When the queue is full (10), shows
  `OFFLINE — queue full` in a visibly distinct style (e.g. red).
- **FR-28** On receiving a new message, the message list auto-scrolls to bottom
  unless the user has manually scrolled up.
- **FR-29** Queued (pending) messages appear in the message list immediately in
  a visibly distinct style (e.g. dimmed/italic), and transition to normal style
  once delivered.

---

## 4. Conceptual data model

**Identity** (stored at `~/.okolica/config.json`)

| field         | type   | note                              |
| ------------- | ------ | --------------------------------- |
| author_id     | UUID   | stable across renames             |
| nick          | string | 1–32 chars                        |
| discriminator | int    | 1000–9999                         |

**Message** (stored in SQLite at `~/.okolica/messages.db`)

| field       | type         | note                                 |
| ----------- | ------------ | ------------------------------------ |
| id          | UUID (PK)    | generated at author time             |
| author_id   | UUID         | links to identity                    |
| author_nick | string       | denormalized; displayed as-received  |
| content     | string       | ≤ 2000 chars                         |
| created_at  | UTC datetime | author's local UTC at send time      |
| received_at | UTC datetime | this node's UTC on first receipt; debug only |

**Indexes:**
- `id` is PK (dedupe is trivial).
- Composite index on `(created_at, id)` for fast ordered retrieval.

**Wire format** (UDP payload, JSON — wrapped by `MessageEncryptor` which is a no-op in MVP)

```json
{
  "type": "MESSAGE" | "HISTORY_REQUEST" | "HISTORY_RESPONSE",
  "payload": { ... }
}
```

- `MESSAGE` payload: `{ id, author_id, author_nick, content, created_at }`
- `HISTORY_REQUEST` payload: `{ requester_id }`
- `HISTORY_RESPONSE` payload: `{ messages: [<MESSAGE payload>, ...] }` (up to 100)

---

## 5. Decisions

Each decision is a fork where a silent wrong choice would cause pain. Numbered for
cross-reference from plan.md / tasks.md.

- **D-1 mDNS service type is `_okolica._udp.local.`** Not HTTP, not TCP — UDP matches
  our transport. Service name prefix is `okolica-<author_id>` to avoid collisions.

- **D-2 UDP port is dynamic, chosen by the OS at startup.** Node binds to port 0,
  OS assigns, actual port is advertised via mDNS TXT record. Port stays fixed
  for the process lifetime. Rejected: fixed port 5353 — breaks multiple instances
  on one machine, conflicts with mDNS itself.

- **D-3 Discriminator is 4 decimal digits, not Discord's 4 hex.** Cleaner in a
  terminal, smaller space (9000 vs 65536). For 20-person office, birthday
  paradox collision probability is ~2%. Acceptable.

- **D-4 History request on startup is "best effort", not retry loop.** 3 seconds,
  3 random peers, whoever answers wins. Rejected: retry every 5s for 1 minute.
  Blocking the UI or spamming the network for a nicety is wrong trade-off.

- **D-5 Message ordering is `(created_at, id)` on every node, always.** `created_at`
  is the author's clock — unsynchronized between nodes. Ties broken by `id`
  (UUID), giving deterministic but meaningless ordering for simultaneous
  messages. The goal is *all nodes agree on the same order*, not *the order
  matches reality*. Rejected: "in order of arrival" — different for every node,
  breaks the shared-view invariant.

- **D-6 No edit, no delete, no reactions in MVP.** Once a message is out, it's
  out. Rejected: "soft delete with tombstone" — adds distributed-systems
  complexity that undermines the learning goal.

- **D-7 `content` limit is 2000 chars, not bytes.** Python string length. UTF-8
  bytes may be 3x more; UDP payload stays under ~8KB which is safe for default
  MTU without fragmentation.

- **D-8 Gossip forwarding is unconditional** for messages not seen before. No TTL
  counter, no hop limit. At 20 nodes the cost is trivial; at 200 nodes this
  needs revisiting. Rejected: BGP-style SPF for 20 people — absurd.

- **D-9 Empty or whitespace-only nickname is rejected.** No default "anonymous"
  fallback — forces the user to make a choice.

- **D-10 Config file location is `~/.okolica/`, not XDG.** Simpler for cross-
  platform (macOS users don't have `$XDG_CONFIG_HOME` by default). Rejected:
  `platformdirs` dependency — overkill for MVP.

- **D-11 SQLite journal mode is WAL.** Handles concurrent reads from UI and
  writes from receiver cleanly within one process.

- **D-12 Startup is non-blocking.** UI renders immediately with whatever local
  history exists; history merge from peers happens in background and updates
  the view when it arrives. Rejected: block until peer discovery — bad UX on
  empty network (first run) and slow on every subsequent run.

- **D-13 History fan-out is exactly 3 peers.** Rejected: "ask everyone" — with
  20 nodes that's 20×100 = 2000 messages simultaneously arriving on a single
  UDP socket. Default socket buffer ~64KB = packet loss. 3 is the standard
  gossip-protocol fan-out (Cassandra, Consul, Serf).

- **D-14 Outbound queue cap is 10, not unlimited.** Rejected: unlimited queue —
  silent data loss when process killed. Rejected: FIFO eviction (keep newest) —
  user thinks old messages sent, they didn't. Chosen: reject new sends at cap,
  UI shows "OFFLINE — queue full". Forces the user to notice.

- **D-15 Counter resets at reconnect.** When peer count goes 0→≥1 and queue
  flushes, the "messages while offline" count resets to zero. Simpler mental
  model: "each offline period gets 10".

- **D-16 MVP ships no encryption, but the hook is in place.** Wire payloads pass
  through `MessageEncryptor.encrypt/decrypt` which is a no-op in MVP
  (`NullEncryptor`). v2 can drop in `LibsodiumEncryptor` without touching
  gossip logic. Rejected: implement encryption in MVP — doubles scope, needs
  PKI design which is its own project.

- **D-17 DMs are explicitly out of MVP.** Broadcast-to-`#general` only. DMs
  require routing decisions, per-chat history, and mandatory encryption (even
  in trusted LAN, broadcast DMs are a privacy leak). v2 work.

---

## 6. Out of scope (explicit non-goals)

- Authentication, encryption, shared secrets (hook exists, not used).
- Direct messages, private channels, multiple channels.
- File transfer, images, links with preview.
- Reactions, threads, quotes, replies.
- Message edit or delete after send.
- Typing indicators, read receipts, online presence.
- Mobile clients, web clients, desktop GUI.
- Bluetooth transport (architected for, not implemented).
- Cross-subnet / cross-VLAN mesh (mDNS is single-broadcast-domain by design).
- Bridges to Telegram / Matrix / IRC.
- Persistence of outbound queue across restarts.
- Messages older than 100-per-node (no long-term archive).
- Localization of UI strings (English only).
- Windows support (macOS + Linux only — zeroconf on Windows is flaky).

---

## 7. Acceptance criteria

Each of these maps to at least one test in `tasks.md`. A-numbered tests run as
integration tests using two or more asyncio instances on localhost with different
ports.

- **A-1** First run on a clean system prompts for a nick. Entering "dima" creates
  `~/.okolica/config.json` with `nick=dima`, discriminator ∈ [1000, 9999], valid UUID `author_id`.
- **A-2** Second run with existing config file does not prompt; identity loaded as-is.
- **A-3** Empty or whitespace-only nickname on first run re-prompts instead of accepting.
- **A-4** Two nodes A and B on localhost discover each other via mDNS within 5
  seconds of both being online.
- **A-5** Node A sends "hello" while B is online. B receives it within 1 second.
  Message `id` is identical on both nodes.
- **A-6** Node A sends "hello" while no peers are online. Message is queued; UI
  shows "1 pending". Node B joins. Within 2 seconds of B's discovery, B has
  received "hello" and A's queue is empty.
- **A-7** With no peers online, user sends 10 messages — all accepted, all queued.
  11th send is rejected with UI error. B joins; the 10 messages flush; then user
  sends a new message — accepted (counter reset).
- **A-8** Node A has 150 messages in history (synthesized). Node C starts and
  requests history. C's local store ends up with exactly 100 most recent
  messages, sorted ascending by `(created_at, id)`.
- **A-9** Nodes A and B both have messages A1, A2, A3 (from A) and B1, B2, B3
  (from B) with interleaved `created_at`. Node C starts, queries both, merges.
  C has all 6 unique messages, deduped, sorted by `(created_at, id)` —
  identically to what A and B see.
- **A-10** Three nodes A, B, C. A sends a message. B receives and forwards to C.
  C receives from B (not A directly). If A also routes to C directly, C sees
  the message exactly once.
- **A-11** Message with content length 2001 is rejected at input; 2000 is accepted.
- **A-12** Ctrl+C during normal operation cleanly unregisters the mDNS service
  and exits without tracebacks.
- **A-13** Two messages with identical `created_at` but different `id` appear in
  the same order on all nodes (sorted by `id` lexicographically as tiebreaker).
- **A-14** `NullEncryptor.encrypt(x) == x` and `NullEncryptor.decrypt(x) == x`
  for all valid payloads. Wire format over the network is the raw JSON (verifiable
  with `tcpdump` in manual testing).

---

## 8. Known risks and non-blocking concerns

Not open questions — these are things to keep in mind but not blocking /plan.

- **R-1 Corporate Wi-Fi may block mDNS.** If `zeroconf` doesn't work in Sber's
  network, we'll need a manual peer-IP config as fallback. Not building it now;
  if discovered at first real deployment, v1.1 feature.
- **R-2 NAT / client-isolation on corporate Wi-Fi.** Some corporate APs isolate
  clients from each other. Would block UDP direct-to-peer. Only way to know is
  to try. If hit, document as known limitation.
- **R-3 Clock skew between machines can misorder messages.** A colleague with
  clock 5 minutes ahead will appear to "always write latest". Acceptable for
  MVP. v2 could add Lamport clocks if this becomes painful.
- **R-4 UDP payload >8KB will fragment.** A 2000-char UTF-8 message with a few
  4-byte emojis can approach this. Fragmented UDP is fine on LAN but occasionally
  lossy. If this causes issues, reduce `content` limit or switch to length-prefixed
  framing over reliable transport.
