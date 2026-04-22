# Tasks: Okolica MVP

**Spec:** 001-mesh-chat-mvp v2.0
**Plan:** 001-mesh-chat-mvp/plan.md v1.0
**Status:** Ready to execute

Every task is:
- **Atomic** — one concern, one PR-sized unit of work.
- **Testable** — has a clear "done" criterion.
- **Traceable** — references specific FR / A / D from spec and §N from plan.

Tasks are ordered by dependency. Later tasks assume earlier ones are complete.
Within a phase, tasks are independent and can be reordered.

Test-first is the default. If a task says "implement X", the test for X is
written first, fails, then the implementation makes it pass.

---

## Phase 0: Project skeleton (no business logic yet)

### T-001: Initialize repo and pyproject.toml
**Depends on:** nothing
**Refs:** plan §13, Constitution §1

- `uv init --package okolica`
- Create `pyproject.toml` exactly as specified in plan §13.
- Create empty `src/okolica/__init__.py` with `__version__ = "0.1.0"`.
- Add `.gitignore` (Python, uv, macOS `.DS_Store`, `~/.okolica/` is user data not repo).
- `README.md` stub with one sentence about the project.
- `uv sync` runs clean.

**Done when:** `uv sync && uv run python -c "import okolica"` succeeds.

---

### T-002: Pre-commit, linters, mypy strict
**Depends on:** T-001
**Refs:** plan §13, Constitution §1

- `.pre-commit-config.yaml` mirroring gigachat-doc-helper's hooks: black, isort,
  pylint, mypy.
- `pyproject.toml` with `[tool.black]`, `[tool.isort]`, `[tool.pylint]`,
  `[tool.mypy] strict = true`.
- `pre-commit install` runs.
- `Makefile` with `fmt`, `lint`, `test`, `run` targets (plan §14).

**Done when:** `make fmt && make lint` pass on the empty skeleton with no errors.

---

### T-003: Package layout scaffold
**Depends on:** T-002
**Refs:** plan §2

Create empty `__init__.py` in every package described in plan §2:

```
src/okolica/
  core/          transport/     discovery/
  crypto/        ui/            db/
  db/alembic/versions/
tests/
  unit/          integration/   ui/
```

Every `__init__.py` is empty except for the top `src/okolica/__init__.py`.

**Done when:** `tree src` matches plan §2 exactly.

---

### T-004: pylint import-graph rule
**Depends on:** T-003
**Refs:** plan §2 (layer rules)

- Configure pylint to fail if `ui/*` imports from `transport/`, `discovery/`, `db/`, `crypto/`.
- Configure pylint to fail if `core/*` imports from concrete implementations
  (`transport.udp`, `discovery.mdns`, `crypto.null`).
- Add one failing-by-construction test file that imports `ui` from `transport`,
  confirm pylint catches it, remove the file.

**Done when:** `make lint` enforces layer discipline. Violations fail CI.

**Note:** if pylint's `imports` checker isn't granular enough, use a small
custom checker or a pre-commit hook running `grep` over imports. Don't skip —
this rule is the whole point of the layer split.

---

## Phase 1: Data layer (pure, testable)

### T-005: Pydantic core models
**Depends on:** T-003
**Refs:** plan §4, FR-1, FR-9, FR-12, D-7, D-9, A-11, A-14

Implement `core/models.py`:
- `Identity` with validators (nick strip + non-empty, discriminator range).
- `Peer` (author_id, display, ip, port).
- `WireMessage` with `content` max 2000, `created_at` must be tz-aware UTC.
- `HistoryRequest`, `HistoryResponse` (max 100 messages).
- `Envelope` discriminated union by `type`.

Tests in `tests/unit/test_models.py`:
- Nick with leading/trailing whitespace stripped.
- Empty nick rejected (A-3, A-10 cover this via UI, but validator is here).
- Content length 2000 accepted, 2001 rejected (A-11).
- Naive datetime in `created_at` rejected; non-UTC normalized.
- `Envelope` round-trip JSON ser/deser preserves `type` discriminator.

**Done when:** `pytest tests/unit/test_models.py` passes, `mypy --strict` clean.

---

### T-006: Identity load/save
**Depends on:** T-005
**Refs:** plan §4, FR-3, FR-4, A-2

Implement `core/identity.py`:
- `load_identity(config_dir: Path) -> Identity | None` — reads
  `config_dir/config.json`, returns `None` if missing or malformed.
- `save_identity(config_dir: Path, identity: Identity) -> None` — writes
  atomically (write to `.tmp`, rename).
- `generate_identity(nick: str) -> Identity` — fresh UUID, random
  discriminator in `[1000, 9999]`.

Tests in `tests/unit/test_identity.py`:
- Round-trip: save then load → same Identity.
- Missing file → `None`.
- Malformed JSON → `None` (not raise).
- Discriminator always in range.
- Two fresh identities have different `author_id`.

**Done when:** A-2 test passes at the unit level. Coverage on `core/identity.py` is 100%.

---

### T-007: Message ordering helper
**Depends on:** T-005
**Refs:** plan §3, FR-14, D-5, A-13

Implement `core/ordering.py`:
- `sort_messages(messages: Iterable[WireMessage]) -> list[WireMessage]`
  sorts by `(created_at, str(id))` ascending.
- `merge_unique(*groups: Iterable[WireMessage]) -> list[WireMessage]`
  dedupes by `id`, returns sorted.

Tests in `tests/unit/test_ordering.py`:
- Identical `created_at`, different `id` → deterministic tiebreak by `id` string (A-13).
- Merge of three overlapping lists → correct dedupe count.
- Empty input → empty output (no crash).

**Done when:** `pytest tests/unit/test_ordering.py` passes.

---

### T-008: SQLAlchemy schema + Alembic setup
**Depends on:** T-003
**Refs:** plan §3, FR-16, Constitution §3

- `db/schema.py`: `Base` + `Message` ORM model (plan §3).
- `db/engine.py`: `create_engine(db_path) -> AsyncEngine` with pragma event listener
  (WAL, foreign_keys, synchronous=NORMAL).
- `db/alembic/env.py` and `script.py.mako` configured for async SQLAlchemy.
- `alembic.ini` at `src/okolica/db/alembic.ini`.
- First migration auto-generated: `alembic revision --autogenerate -m "initial"`.
- Review the generated migration — must create `messages` table with composite
  index `ix_messages_created_id`.

Tests: none yet (next task).

**Done when:** `make migrate` against a tmp DB creates the schema. `sqlite3 tmp.db .schema`
shows expected table + index.

---

### T-009: MessageStore
**Depends on:** T-008
**Refs:** plan §3, FR-16, A-8, A-9

Implement `core/store.py`:
- `MessageStore.__init__(engine)`.
- `insert_if_absent(msg: WireMessage) -> bool` — returns True if new.
- `last_n(n: int = 100) -> list[WireMessage]` — ASC by `(created_at, id)`.
- `bulk_upsert(msgs: list[WireMessage]) -> int` — returns newly-inserted count.
- `prune_over(cap: int = 100) -> int` — keep latest `cap`, delete rest.
- Internal: `_to_orm(wire) -> Message`, `_from_orm(row) -> WireMessage`.

Tests in `tests/unit/test_store.py` (use in-memory SQLite):
- Insert then insert again with same id → second returns False, no duplicate.
- `last_n(5)` on 10 inserted messages → 5 most recent, sorted ASC.
- `bulk_upsert` with mix of new and known → count == new only.
- `prune_over(3)` on 10 messages → 3 remain, those are the latest 3.
- Sort uses `(created_at, id)` not insertion order (A-13 at store level).

**Done when:** Unit tests pass. Covers A-8 logic at the store level (integration later).

---

### T-010: OutboundQueue
**Depends on:** T-005
**Refs:** plan §9, FR-21, FR-22, FR-23, D-14, A-7

Implement `core/queue.py`:
- `QueueFullError(Exception)` with `depth` attribute.
- `OutboundQueue(cap: int = 10)`.
- `enqueue(msg) -> None`, raises `QueueFullError` at cap.
- `flush() -> list[WireMessage]`, returns and clears.
- `__len__` returns current depth.

Tests in `tests/unit/test_queue.py`:
- 10 enqueues succeed, 11th raises.
- After flush, enqueue works again (counter reset — D-15).
- FIFO order preserved on flush.

**Done when:** A-7 queue-level logic is testable; integration wiring later.

---

## Phase 2: Abstract boundaries (protocols only)

### T-011: Transport, Discovery, Encryptor protocols
**Depends on:** T-005
**Refs:** plan §5, §6, §7, Constitution §2

Create:
- `transport/base.py` with `Transport` Protocol (plan §5 signature).
- `discovery/base.py` with `Discovery` Protocol + `PeerEvent` model (plan §6).
- `crypto/base.py` with `MessageEncryptor` Protocol (plan §7, async).

No implementations yet. Just interfaces.

Tests in `tests/unit/test_protocols.py`:
- Can create a `FakeTransport` / `FakeDiscovery` / `FakeEncryptor` stub
  that satisfies the Protocol (via `isinstance` on `runtime_checkable`).
- These fakes will be reused by core tests.

**Done when:** `mypy --strict` confirms fakes satisfy protocols.

---

### T-012: NullEncryptor
**Depends on:** T-011
**Refs:** plan §7, D-16, FR-13, A-14

Implement `crypto/null.py`:
```python
class NullEncryptor:
    async def encrypt(self, plaintext: bytes) -> bytes:
        return plaintext
    async def decrypt(self, ciphertext: bytes) -> bytes:
        return ciphertext
```

Tests in `tests/unit/test_null_encryptor.py`:
- A-14: `encrypt(x)` then `decrypt(...)` yields `x` for various payloads
  (empty, ASCII, UTF-8, binary, 10KB random).

**Done when:** A-14 passes at the unit level.

---

## Phase 3: Core orchestrator + history merge

### T-013: MeshNode skeleton with fake transports
**Depends on:** T-005 T-007 T-009 T-010 T-011 T-012
**Refs:** plan §8

Implement `core/node.py` — `MeshNode` class — but test it with
`FakeTransport` + `FakeDiscovery` (from T-011), not real ones.

Scope:
- Constructor: DI for all collaborators (plan §8).
- `start()`: starts transport, starts discovery, starts background
  `_receive_loop` and `_discovery_loop`.
- `stop()`: reverse order.
- `send(content: str)` — build WireMessage, store locally, send to peers or queue.
- Handle incoming MESSAGE: dedupe, store, forward, emit UI event.

**Not yet implemented in this task:**
- History sync (T-014).
- UI event streams (T-015).

Tests in `tests/unit/test_node.py`:
- `send` with no peers → message in queue.
- `send` with 1 peer → `FakeTransport.sent` contains one packet.
- Incoming MESSAGE → `store.last_n()` contains it.
- Incoming duplicate → only one copy.
- Three-node gossip: A's MESSAGE arrives at B via FakeTransport,
  B forwards to C.

**Done when:** node logic is testable without any real network.

---

### T-014: History sync sub-protocol
**Depends on:** T-013
**Refs:** plan §8, FR-17, FR-18, FR-19, FR-20, D-4, D-12, D-13, A-8, A-9

Implement `core/history.py` + wire into `MeshNode.start()`:
- Background task started after `start()`.
- Up to 1s wait for any peer.
- Sample ≤3 random peers.
- Send HISTORY_REQUEST; collect responses up to 3s total timeout.
- On HISTORY_REQUEST received: respond with `store.last_n(100)`.
- On HISTORY_RESPONSE received: `store.bulk_upsert` + `prune_over(100)`.
- Emit "history updated" event.

Tests in `tests/unit/test_history.py` (with FakeTransport/Discovery):
- A has 150 msgs, C queries A → C ends with exactly 100 latest (A-8).
- A has [A1..A3], B has [B1..B3] interleaved times; C queries both → C
  has all 6 sorted by `(created_at, id)` (A-9).
- Peers never respond within 3s → `_sync_history` exits cleanly, no crash.

**Done when:** A-8 and A-9 pass at unit level.

---

## Phase 4: Real transports

### T-015: UdpTransport
**Depends on:** T-011
**Refs:** plan §5, D-2, FR-7

Implement `transport/udp.py`:
- `asyncio.DatagramProtocol`-based implementation of `Transport`.
- `start()`: create endpoint on `('0.0.0.0', 0)`, capture assigned port.
- `local_port` property after start.
- `send(peer, raw)`: `sendto`; reject if `len(raw) > 8000` with warning log.
- Incoming: `datagram_received` enqueues onto asyncio.Queue (maxsize=1024,
  drop oldest on overflow).
- `incoming()` async iterator yields from queue.
- `stop()`: closes transport, drains queue.

Tests in `tests/unit/test_udp_transport.py`:
- Two `UdpTransport` instances on localhost, different ports → A sends,
  B receives (bytes equal).
- `local_port` returns a real assigned port after `start()`.
- Oversized payload → logged warning, not sent.
- `stop()` during pending send → clean.

**Done when:** two-socket localhost send/receive works.

---

### T-016: ZeroconfDiscovery
**Depends on:** T-011
**Refs:** plan §6, D-1, FR-5, FR-6, FR-7, FR-8, A-3, A-4

Implement `discovery/mdns.py`:
- Uses `zeroconf.asyncio.AsyncZeroconf` + `AsyncServiceBrowser`.
- Service type: `_okolica._udp.local.`.
- Service name: `okolica-<author_id[:8]>.<service_type>`.
- TXT record: author_id (full), display nick.
- `start(our_peer)`: register own service, browse for others.
- `current_peers()`, `events()` per plan §6.
- Emits `added` on new TXT parsed; `removed` on service disappearance.
- Skips self by `author_id`.

Tests in `tests/integration/test_mdns.py`:
- Two ZeroconfDiscovery instances on same loopback → each sees the other
  within 5 seconds (A-4).
- Same machine, different author_ids → distinct peers (FR-8).

**Note:** these tests may be flaky on macOS CI (plan §15 R-6). Mark with
`@pytest.mark.network` so they can be skipped locally if mDNS is firewalled.

**Done when:** integration test `test_mdns.py::test_two_peers_discover` passes
on Linux.

---

## Phase 5: Integration

### T-017: `build_node` factory and integration fixtures
**Depends on:** T-013 T-015 T-016
**Refs:** plan §11, §12

- `tests/conftest.py`: `node_factory` fixture (plan §12 pattern).
- Helper `build_node(config_dir, nick) -> MeshNode` that wires real UDP +
  real zeroconf + NullEncryptor + real SQLite (in tmp_path) + OutboundQueue.
- Helpers: `wait_until(pred, timeout)`, `wait_for_message(node, content,
  timeout)`.

**Done when:** fixtures exist and two-node integration tests in T-018 can
start nodes and shut them down cleanly.

---

### T-018: Integration test — two-node exchange
**Depends on:** T-017
**Refs:** A-4, A-5, A-12

`tests/integration/test_two_nodes.py`:
- A-4: two nodes discover within 5s.
- A-5: A sends "hello", B receives within 1s, same id on both.
- A-12: Ctrl+C equivalent (`await node.stop()`) cleanly unregisters service,
  no exceptions logged.

**Done when:** `pytest tests/integration/test_two_nodes.py` passes green.

---

### T-019: Integration test — three-node gossip
**Depends on:** T-017
**Refs:** A-10

`tests/integration/test_three_nodes.py`:
- Start A, B, C.
- A sends message.
- B receives and forwards; C receives via B.
- Even if all three are in each other's peer lists (redundant paths), C has
  exactly one copy of the message.

**Done when:** A-10 passes.

---

### T-020: Integration test — history sync
**Depends on:** T-017
**Refs:** A-8, A-9

`tests/integration/test_history_sync.py`:
- A-8: pre-seed A's SQLite with 150 synthetic messages. Start C; C ends up
  with exactly 100 most recent after sync completes.
- A-9: pre-seed A with [A1..A3], B with [B1..B3] interleaved. Start C,
  query both. C has all 6, sorted correctly.

**Done when:** both tests pass.

---

### T-021: Integration test — offline queue
**Depends on:** T-017
**Refs:** A-6, A-7

`tests/integration/test_offline_queue.py`:
- A-6: start A alone, send "hello" → queued. Start B. Within 2s of
  B's discovery by A, "hello" arrives at B.
- A-7: with no peers, send 10 messages (all queued). 11th raises
  `QueueFullError`. Start B. Queue flushes. Then A.send succeeds again.

**Done when:** both A-6 and A-7 pass.

---

## Phase 6: UI

### T-022: First-run screen
**Depends on:** T-006
**Refs:** plan §10, FR-1, FR-2, A-1, A-3

Implement `ui/first_run.py`:
- Single Textual screen with centered Input + label.
- On submit: strip, validate.
- Invalid → show error, keep input open, stay on screen (A-3).
- Valid → `generate_identity(nick)` + `save_identity` + dismiss.

Tests in `tests/ui/test_first_run.py` using Textual `Pilot`:
- A-1: enter "dima", confirm → config.json created with correct shape.
- A-3: enter "   " → error shown, stays on screen. Enter "dima" → proceeds.

**Done when:** both UI tests pass.

---

### T-023: Chat screen — layout + status line
**Depends on:** T-022
**Refs:** plan §10, FR-19, FR-20, FR-21, FR-22

Implement `ui/widgets.py` and `ui/app.py`:
- Layout: `MessageList` (top, scrollable), `Input` (middle), `Footer` (bottom).
- `Footer` shows "N peers online · M pending" (FR-27).
- Red style on footer when queue full (FR-27).
- Auto-scroll logic: follow bottom unless user scrolled up (FR-28).

UI-only tests (no node wiring yet): render an empty app, check initial state.

**Done when:** `ChatApp(mock_node)` renders without errors via Pilot.

---

### T-024: Wire UI to MeshNode via event streams
**Depends on:** T-023 T-013
**Refs:** plan §10

- `MeshNode` exposes:
  - `incoming_messages()` async iterator (new MESSAGEs)
  - `peer_count_changes()`
  - `queue_depth_changes()`
  - `history_updated()`
- `ChatApp` runs background tasks consuming these streams, updating widgets
  with `app.call_from_thread` or native reactive.
- User Input submit → `await node.send(content)`. On `QueueFullError` →
  render error toast / set footer red.
- Queued (pending) messages show in dimmed style until delivered (FR-29).

No new acceptance tests here — A-5/A-6/etc. already cover the node side, and
T-025 covers the end-to-end smoke.

**Done when:** manual run (`make run` in two terminals on localhost) shows a
working chat.

---

### T-025: End-to-end smoke test
**Depends on:** T-024
**Refs:** whole spec

Using Textual `Pilot` + two real `MeshNode`s on localhost:
- Pilot A: type "hello", press Enter.
- Assert within 2s: Pilot B's MessageList contains "hello" with A's nick.
- Pilot B: type "привет back".
- Assert within 2s: Pilot A's MessageList contains "привет back".

**Done when:** the smoke test passes. This is the closest thing to a
product-level sanity check before manual testing.

---

## Phase 7: Documentation and polish

### T-026: README
**Depends on:** T-025
**Refs:** spec §7 (security disclaimer), plan §15 (known risks)

`README.md` covers:
- What Okolica is (one paragraph).
- **Security warning** (Constitution §7): trusted LAN only, no encryption.
- Installation: `uv sync`.
- First run: `make run`.
- Known limitations (R-1..R-6 from plan §15, in user-facing language).
- Architecture diagram (ASCII): nodes, mDNS, UDP, no server.
- Contributing: link to `.specify/` for how the spec-driven flow works.

**Done when:** a new person can clone and run following README alone.

---

### T-027: Constitution compliance audit
**Depends on:** T-026
**Refs:** Constitution (all sections)

Walk through Constitution point by point, verify compliance:
- §1 Python 3.11, uv, linters ✓
- §2 Layer rules enforced (T-004) ✓
- §3 JSON wire format, WAL, Alembic ✓
- §4 Identity format ✓
- §5 Fan-out 3, 3s timeout ✓
- §6 Queue cap 10, reset on reconnect ✓
- §7 NullEncryptor wired, README warns ✓
- §8 Coverage ≥70%, real transports in integration ✓
- §9 Spec is source of truth — open PR linking FR → code locations

**Done when:** compliance checklist complete; coverage at or above 70%.

---

## Dependency graph (simplified)

```
T-001 ─ T-002 ─ T-003 ─ T-004
                  │
                  ├─ T-005 (models) ─┬─ T-006 (identity)
                  │                  ├─ T-007 (ordering)
                  │                  ├─ T-010 (queue)
                  │                  └─ T-011 (protocols) ─ T-012 (null encryptor)
                  │
                  └─ T-008 (schema) ─ T-009 (store)

T-013 (MeshNode) ← T-005, T-007, T-009, T-010, T-011, T-012
T-014 (history)  ← T-013

T-015 (UDP)       ← T-011
T-016 (mDNS)      ← T-011

T-017 (fixtures)  ← T-013, T-015, T-016
T-018 (2-node)    ← T-017
T-019 (3-node)    ← T-017
T-020 (history)   ← T-017
T-021 (queue)     ← T-017

T-022 (first-run) ← T-006
T-023 (layout)    ← T-022
T-024 (wiring)    ← T-023, T-013
T-025 (smoke)     ← T-024

T-026 (README)    ← T-025
T-027 (audit)     ← T-026
```

**Critical path:** T-001 → T-002 → T-003 → T-005 → T-011 → T-013 → T-014 →
T-017 → T-024 → T-025 → T-026 → T-027.

The phase structure is there to help mental chunking. In practice:
- **Phase 0 + 1** = "foundations" — boring but load-bearing.
- **Phase 2 + 3** = "all the hard logic, no networking" — most bugs caught here.
- **Phase 4** = "the scary network stuff" — isolated precisely because it's
  hardest to debug.
- **Phase 5** = "it actually works end-to-end" — first dopamine hit.
- **Phase 6** = "it's a product now, not just a library" — second dopamine.
- **Phase 7** = "others can run it" — ship-ready.

---

## What "done" means for the whole MVP

- All 14 A-criteria pass.
- `make lint && make test` green.
- Coverage ≥70%.
- Two humans can `make run` on separate machines in the same Wi-Fi and chat.
- README is good enough that a third human can join within 10 minutes of
  receiving the repo URL.

When all of those are true, Okolica MVP ships.
