# Okolica — Constitution

**Version:** 1.0 (finalized)
**Purpose:** LAN mesh messenger for offices where external networks may be blocked.
Nodes discover each other via mDNS and gossip messages peer-to-peer over UDP.
No central server.

This document defines non-negotiable principles. An AI agent or contributor proposing
a change that violates these must explicitly flag the violation and justify it in the PR.

## 1. Runtime and toolchain

- **Python 3.11+.** Use `zoneinfo` (stdlib), `tomllib` (stdlib). No 3.12-exclusive syntax
  unless we bump `requires-python`.
- **uv manages dependencies.** All commands run as `uv run <cmd>`. No bare `python` or
  `pip install`. No `requirements.txt` — single source of truth is `pyproject.toml`.
- **Linters are authoritative:** black (line-length 120), isort (profile "black"),
  pylint, mypy. Pre-commit hooks gate all commits. No migration to ruff without
  explicit approval — the gigachat-doc-helper codebase uses the same stack and we
  match it deliberately.

## 2. Architecture

- **Async by default.** All I/O — network sockets, SQLite, filesystem — goes through
  asyncio. No thread-based I/O in the hot path.
- **Transport is a pluggable interface.** `Transport` protocol defines `send(payload,
  peer)` and `receive() -> AsyncIterator[Envelope]`. MVP ships a UDP-based
  implementation. A future `BluetoothTransport` must slot in without touching
  business logic. This is a *hard* architectural constraint — do not embed UDP
  specifics into the service layer.
- **Discovery is a pluggable interface.** `Discovery` protocol defines `announce()`
  and `peers() -> AsyncIterator[PeerEvent]`. MVP ships mDNS via `zeroconf`. Manual
  IP-list fallback is post-MVP.
- **Encryption is a pluggable interface, no-op in MVP.** `MessageEncryptor` protocol
  defines `encrypt(payload) -> bytes` and `decrypt(bytes) -> payload`. MVP ships a
  `NullEncryptor` that passes bytes through unchanged. A v2 `LibsodiumEncryptor`
  must slot in without touching business logic. Core code always calls
  `encryptor.encrypt/decrypt`, never branches on "is encryption enabled".
- **Three layers:**
  - `transport/` — raw wire protocol (UDP, later BT)
  - `core/` — gossip protocol, message store, identity, history merging, encryption
    hook (no I/O primitives directly; uses Transport + Discovery + Encryptor)
  - `ui/` — Textual CLI (no network code directly; calls core)
- **No central state.** Every node is equal. No "server mode". If the code path reads
  "the server does X" — it's wrong.

## 3. Protocol and data

- **Message is immutable once created.** A message has `id` (uuid4), `author_id`,
  `author_nick`, `content`, `created_at` (UTC). Nodes do not mutate received messages.
- **Message identity is content-independent.** Two nodes receiving the same message
  must compute the same `id` (the id is generated at author time, carried through).
  Deduplication uses `id`, not content hash.
- **Clocks are not synchronized.** `created_at` is the author's local UTC at send
  time. Ordering uses `(created_at, id)` as a deterministic tuple — accept that
  clocks drift, and this is best-effort. Lamport / vector clocks are out of scope
  for MVP.
- **Ordering is by `(created_at, id)`, always, on every node.** `received_at` is
  stored for debugging only and never used for UI ordering. Without this rule,
  different nodes would see the same conversation in different orders — this is a
  correctness invariant, not a style choice.
- **SQLite for local store.** Every node has its own `~/.okolica/messages.db`. Schema
  changes go through Alembic migrations — even for a single-file hobby DB. This is
  deliberate: the discipline matters more than the size.
- **Wire format is JSON.** Not protobuf, not msgpack. JSON survives debugging with
  `tcpdump` and is learnable. Performance is not a concern at MVP scale (office of
  ~20 people).

## 4. Identity

- **Nick + numeric discriminator, persistent.** Format: `dima#4521`. Stored in
  `~/.okolica/config.json` on first run, never regenerated. Deleting the config file
  = new identity (this is acceptable).
- **Discriminator is 4 random digits 1000–9999.** Collision probability in a
  20-person office is negligible; we do not coordinate discriminators across nodes.
- **`author_id` is a persistent UUID,** separate from the visible nick. Nick can
  theoretically be changed later without breaking message attribution.

## 5. History merging

- **On startup, query up to 3 random online peers** for their last 100 messages each.
  Fan-out of 3 is deliberate: larger fan-out causes UDP buffer overflow and network
  noise at office scale.
- **Merge by message `id`,** dedupe, sort by `(created_at, id)`, keep last 100.
- **If no peers respond within 3 seconds**, start with whatever local history exists.
  Do not block the UI.
- **This is best-effort, not consistent.** A user joining during a netsplit sees what
  their side of the split has. Accepted.

## 6. Outbound queue

- **If no peers are online, queue messages locally.** In-memory, FIFO.
- **Hard cap: 10 queued messages.** Beyond 10, new sends are rejected with a UI
  error ("You are offline. 10 messages pending. Reconnect to continue."). This is a
  deliberate UX choice — forcing the user to notice they are offline is better than
  silent drops.
- **Counter resets on reconnection.** When the peer list transitions from empty to
  non-empty and the queue flushes, the "10 messages while offline" counter resets
  to zero. Subsequent offline periods start fresh.
- **Queue is not persisted across restarts.** Restarting the app with queued
  messages = messages lost. Document clearly in README.

## 7. Security

- **MVP security model is "trusted LAN".** Anyone on the same Wi-Fi who runs Okolica
  joins the chat. No encryption, no authentication, no shared secret. The
  `NullEncryptor` is wired in but passes everything through.
- **This is explicit and documented.** README must warn users. Do not deploy
  outside trusted network environments.
- **Future work (v2+):** real encryption via libsodium — X25519 Diffie-Hellman for
  key exchange, ChaCha20-Poly1305 for message payloads. Architecture is already
  prepared (see §2, `MessageEncryptor` hook).

## 8. Testing

- **pytest, functional style.** Fixtures, module-level functions, no test classes.
- **Real transports in integration tests** where possible (two asyncio UDP sockets
  on localhost, different ports). Mock only hard external boundaries (filesystem
  in some cases, zeroconf).
- **Coverage floor 70%.** Stricter than gigachat-doc-helper (which is 50%) because
  this is a learning project where the test-discipline itself is the goal.
- **Every acceptance criterion in spec.md maps to at least one test.** The
  tasks.md breakdown enforces this — a task is "not done" until its test passes.

## 9. Change policy

- **Spec is the source of truth.** If code disagrees with spec, spec wins — either
  update spec (with rationale in PR) or fix code to match.
- **Smallest viable diff.** No opportunistic refactoring in feature PRs.
- **Explain-before-fix.** Any agent proposal starts with root cause, then solution.
