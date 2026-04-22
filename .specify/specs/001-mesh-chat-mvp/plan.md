# Plan: Okolica MVP — Implementation

**Spec:** 001-mesh-chat-mvp v2.0
**Status:** Draft — awaiting review
**Version:** 1.0

Maps every FR / D / A from spec.md to concrete code. No line is here without a
reason traceable to spec. If you find one, delete it.

---

## 1. Tech stack (locked)

| Concern           | Choice                           | Why                                                |
| ----------------- | -------------------------------- | -------------------------------------------------- |
| Runtime           | Python 3.11+                     | Constitution §1                                    |
| Package manager   | `uv`                             | Constitution §1                                    |
| HTTP/ASGI         | **none**                         | This is not a web service; nothing to expose.      |
| TUI               | `textual >= 0.80`                | Async-native, matches asyncio core                 |
| mDNS              | `zeroconf >= 0.132`              | The de facto Python mDNS lib                       |
| ORM               | `sqlalchemy[asyncio] >= 2.0`     | Matches gigachat-doc-helper stack                  |
| SQLite driver     | `aiosqlite`                      | Async SQLAlchemy on SQLite                         |
| Migrations        | `alembic >= 1.14`                | Constitution §3                                    |
| Validation        | `pydantic >= 2.10`               | Wire format + identity config                      |
| Tests             | `pytest >= 8`, `pytest-asyncio`  | Constitution §8                                    |
| Coverage          | `pytest-cov`                     | 70% floor (Constitution §8)                        |
| Format            | `black`, `isort`                 | Constitution §1                                    |
| Lint/type         | `pylint`, `mypy`                 | Constitution §1                                    |

**Deliberately not used:**

- `fastapi` — no HTTP interface. Adding it for "maybe later admin endpoint" is
  premature.
- `cryptography` / `pynacl` — MVP has `NullEncryptor` (D-16). Adding the lib
  ships unused attack surface.
- `click` / `typer` — Textual is the entrypoint; CLI args handled by stdlib
  `argparse` (one flag: `--config-dir`).

---

## 2. Package layout

```
okolica/
├── .specify/
│   ├── memory/
│   │   └── constitution.md
│   └── specs/
│       └── 001-mesh-chat-mvp/
│           ├── spec.md
│           ├── plan.md        ← this file
│           └── tasks.md       ← next step
├── src/
│   └── okolica/
│       ├── __init__.py
│       ├── __main__.py              # `python -m okolica`
│       ├── cli.py                   # argparse, entry point
│       │
│       ├── core/                    # business logic — NO direct I/O
│       │   ├── __init__.py
│       │   ├── models.py            # Pydantic Message, Envelope, Peer
│       │   ├── identity.py          # Identity load/create + config.json I/O
│       │   ├── store.py             # MessageStore (SQLAlchemy)
│       │   ├── queue.py             # OutboundQueue (in-memory)
│       │   ├── node.py              # MeshNode — orchestrator
│       │   ├── gossip.py            # gossip protocol state machine
│       │   ├── history.py           # history merge algorithm
│       │   └── ordering.py          # sort_messages((created_at, id)) helper
│       │
│       ├── transport/               # pluggable transports
│       │   ├── __init__.py
│       │   ├── base.py              # Transport protocol
│       │   └── udp.py               # UdpTransport (asyncio DatagramProtocol)
│       │
│       ├── discovery/               # pluggable discovery
│       │   ├── __init__.py
│       │   ├── base.py              # Discovery protocol
│       │   └── mdns.py              # ZeroconfDiscovery
│       │
│       ├── crypto/                  # pluggable encryption
│       │   ├── __init__.py
│       │   ├── base.py              # MessageEncryptor protocol
│       │   └── null.py              # NullEncryptor (MVP)
│       │
│       ├── ui/                      # Textual app — NO direct network/DB
│       │   ├── __init__.py
│       │   ├── app.py               # ChatApp (Textual App)
│       │   ├── widgets.py           # MessageList, InputBar, StatusLine
│       │   └── first_run.py         # first-run nickname prompt
│       │
│       └── db/
│           ├── __init__.py
│           ├── engine.py            # async engine, session factory
│           ├── schema.py            # SQLAlchemy Base + Message ORM model
│           └── alembic/             # migrations
│               ├── env.py
│               ├── script.py.mako
│               └── versions/
│
├── tests/
│   ├── __init__.py
│   ├── conftest.py                  # shared fixtures
│   ├── unit/
│   │   ├── test_identity.py
│   │   ├── test_models.py
│   │   ├── test_ordering.py
│   │   ├── test_queue.py
│   │   └── test_history_merge.py
│   ├── integration/
│   │   ├── test_two_nodes.py        # A-4, A-5
│   │   ├── test_three_nodes.py      # A-10 (gossip forwarding)
│   │   ├── test_history_sync.py     # A-8, A-9
│   │   └── test_offline_queue.py    # A-6, A-7
│   └── ui/
│       └── test_first_run.py        # A-1, A-2, A-3
├── pyproject.toml
├── .pre-commit-config.yaml
├── Makefile                         # common commands
├── README.md
└── .gitignore
```

**Layer rules (Constitution §2):**

- `ui/` imports only from `core/`. Never from `transport/`, `discovery/`,
  `db/`, `crypto/`.
- `core/` imports from `transport.base`, `discovery.base`, `crypto.base`,
  `db/`. Never from concrete implementations (`udp.py`, `mdns.py`, `null.py`).
- Concrete implementations are wired together in `cli.py` (composition root).
- `db/` is used only by `core/store.py`. UI never touches DB directly.

This is **enforceable via pylint's `import-graph` rule** — add it to pylint
config so a violation fails CI.

---

## 3. Data layer

### SQLAlchemy model (`db/schema.py`)

```python
class Message(Base):
    __tablename__ = "messages"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)        # UUID as text
    author_id: Mapped[str] = mapped_column(String(36), index=True)
    author_nick: Mapped[str] = mapped_column(String(64))                 # nick#NNNN
    content: Mapped[str] = mapped_column(String(2000))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        Index("ix_messages_created_id", "created_at", "id"),
    )
```

**Why strings for UUIDs:** SQLite has no native UUID. Storing as canonical
hex-with-dashes (36 chars) is human-readable in `sqlite3` CLI and sorts
correctly.

**Why `DateTime(timezone=True):** Constitution §3 — naive datetimes are
banned. SQLite stores as ISO string with offset; SQLAlchemy reconstructs as
timezone-aware `datetime`.

### SQLite pragmas (`db/engine.py`)

```python
# applied on each new connection via event listener
PRAGMA journal_mode=WAL;         # D-11
PRAGMA foreign_keys=ON;          # belt-and-braces
PRAGMA synchronous=NORMAL;       # WAL-safe, faster than FULL
```

### Alembic initial migration

One migration (`0001_create_messages.py`) creates the `messages` table and
the `ix_messages_created_id` composite index. Generated via
`alembic revision --autogenerate` once the model is defined.

### MessageStore API (`core/store.py`)

```python
class MessageStore:
    def __init__(self, session_factory): ...

    async def insert_if_absent(self, msg: Message) -> bool:
        """Returns True if inserted (new), False if already existed (dedupe)."""

    async def last_n(self, n: int = 100) -> list[Message]:
        """Last N by (created_at, id) DESC, returned ASC-sorted for display."""

    async def prune_over(self, cap: int = 100) -> int:
        """Delete all but the latest `cap` messages. Returns deleted count."""

    async def bulk_upsert(self, msgs: list[Message]) -> int:
        """For history merge — insert-or-ignore, returns newly-inserted count."""
```

**No ORM session leaks.** Every method opens and closes its own transaction.
UI never holds a session object.

---

## 4. Core models (`core/models.py`)

Pydantic v2 models — **separate** from SQLAlchemy ORM per Constitution §3
discipline (wire format is not the storage format).

```python
class WireMessage(BaseModel):
    model_config = ConfigDict(frozen=True)
    id: UUID
    author_id: UUID
    author_nick: str = Field(min_length=1, max_length=64)
    content: str = Field(min_length=1, max_length=2000)
    created_at: datetime  # must be tz-aware UTC; validator enforces

class HistoryRequest(BaseModel):
    requester_id: UUID

class HistoryResponse(BaseModel):
    messages: list[WireMessage] = Field(max_length=100)

class Envelope(BaseModel):
    type: Literal["MESSAGE", "HISTORY_REQUEST", "HISTORY_RESPONSE"]
    payload: WireMessage | HistoryRequest | HistoryResponse
```

Identity is also Pydantic (for `config.json` roundtripping):

```python
class Identity(BaseModel):
    author_id: UUID
    nick: str = Field(min_length=1, max_length=32)
    discriminator: int = Field(ge=1000, le=9999)

    @property
    def display(self) -> str:
        return f"{self.nick}#{self.discriminator}"
```

**Validators:**

- `created_at` must have `tzinfo` and be UTC (normalize to UTC if different
  offset supplied).
- `nick`: strip whitespace; reject if empty after strip (D-9).

---

## 5. Transport layer (`transport/`)

### Protocol (`transport/base.py`)

```python
class Transport(Protocol):
    async def start(self) -> None: ...
    async def stop(self) -> None: ...

    @property
    def local_port(self) -> int: ...   # resolved after start()

    async def send(self, peer: Peer, raw: bytes) -> None: ...
    def incoming(self) -> AsyncIterator[tuple[Peer, bytes]]: ...
    # bytes are already post-decrypt? No — raw here. Decryption is in core.
```

Why `raw: bytes` not `Envelope`: the encryptor sits *between* transport and
core. Transport doesn't know about JSON or Envelope. This keeps
`BluetoothTransport` in v2 trivially pluggable — it gets bytes, sends bytes.

### UDP implementation (`transport/udp.py`)

Uses `asyncio.DatagramProtocol`. On `start()`:

- Create datagram endpoint with `local_addr=('0.0.0.0', 0)` (D-2: OS picks port).
- Capture assigned port from `transport.get_extra_info('sockname')`.
- Expose via `local_port` property.

Incoming packets enqueued onto an `asyncio.Queue`; `incoming()` yields from
it. Backpressure handled by queue maxsize (e.g. 1024); overflow drops oldest.

**Packet size guard:** reject outgoing datagrams >8000 bytes (log warning).
If we ever hit this with 2000-char messages, we'll know.

---

## 6. Discovery layer (`discovery/`)

### Protocol (`discovery/base.py`)

```python
class PeerEvent(BaseModel):
    kind: Literal["added", "removed"]
    peer: Peer

class Discovery(Protocol):
    async def start(self, our_peer: Peer) -> None: ...
    async def stop(self) -> None: ...
    def events(self) -> AsyncIterator[PeerEvent]: ...
    def current_peers(self) -> list[Peer]: ...
```

### mDNS implementation (`discovery/mdns.py`)

Uses `zeroconf.asyncio.AsyncZeroconf`.

**Service type:** `_okolica._udp.local.` (D-1).
**Service name:** `okolica-<short_author_id>.<service_type>` where
`short_author_id` is the first 8 chars of the UUID (zeroconf has naming
rules, avoid the full 36-char UUID in the name field).
**TXT record:** `{"author_id": "<full-uuid>", "display": "<nick>#NNNN"}`.

On discovery of a new `_okolica._udp.local.` service:

- Parse `author_id` from TXT (full UUID).
- Skip if `author_id == our_peer.author_id` (self).
- Emit `PeerEvent(kind="added", peer=...)`.

On service removal: emit `PeerEvent(kind="removed", ...)`.

**Two-on-one-machine:** zeroconf handles this natively — different service
names on same IP, different ports (from `local_port`). FR-8 / Q-1 satisfied.

---

## 7. Crypto layer (`crypto/`)

### Protocol (`crypto/base.py`)

```python
class MessageEncryptor(Protocol):
    async def encrypt(self, plaintext: bytes) -> bytes: ...
    async def decrypt(self, ciphertext: bytes) -> bytes: ...
```

Async signature is forward-looking — real encryption may involve key
lookups or exchanges. `NullEncryptor` is async for interface uniformity.

### Null implementation (`crypto/null.py`)

```python
class NullEncryptor:
    async def encrypt(self, plaintext: bytes) -> bytes:
        return plaintext
    async def decrypt(self, ciphertext: bytes) -> bytes:
        return ciphertext
```

Called in `core/node.py` **both** on outbound (encrypt before
`transport.send`) and inbound (decrypt before `Envelope.model_validate_json`).
A-14 verifies the round-trip identity.

---

## 8. Core orchestrator (`core/node.py`)

`MeshNode` is the integration point. It receives already-constructed
`Transport`, `Discovery`, `MessageEncryptor`, `MessageStore`, `OutboundQueue`
(dependency injection from `cli.py`).

**Responsibilities:**

- Start transport + discovery on `start()`.
- On UI's `send(content)` call:
  - Build `WireMessage` with fresh UUID and `datetime.now(UTC)`.
  - `store.insert_if_absent(...)` (local-first).
  - Emit "new outgoing" event to UI.
  - If peer list non-empty: serialize → encrypt → `transport.send` to each peer.
  - If empty: `queue.enqueue(...)`. If queue full → raise `QueueFullError` (UI
    shows red status).
- On `transport.incoming` packet:
  - Decrypt → parse `Envelope` → dispatch by `type`.
  - `MESSAGE`: `store.insert_if_absent`; if new → emit to UI and forward to
    all peers except sender and author (FR-10).
  - `HISTORY_REQUEST`: respond with `store.last_n(100)` wrapped in
    `HistoryResponse`.
  - `HISTORY_RESPONSE`: hand off to `history_merger`.
- On `discovery.events` peer-added:
  - If queue non-empty: flush (FR-23), reset offline counter.
- On `discovery.events` peer-removed: just update internal peer list.

**History merge sub-protocol** (`core/history.py`):

On `start()`, run `_sync_history()` task in background (D-12):

1. Wait up to 1 second for `discovery.current_peers()` to become non-empty.
2. Sample up to 3 random peers (D-13).
3. Send `HISTORY_REQUEST` to each.
4. Collect responses for up to 3 seconds total (FR-19).
5. Merge into `store` via `bulk_upsert`. Then `prune_over(100)`.
6. Emit "history updated" event to UI so it re-reads last-100.

---

## 9. Outbound queue (`core/queue.py`)

Simple in-memory FIFO with hard cap 10 (D-14).

```python
class OutboundQueue:
    def __init__(self, cap: int = 10):
        self._q: deque[WireMessage] = deque()
        self._cap = cap

    def enqueue(self, msg: WireMessage) -> None:
        if len(self._q) >= self._cap:
            raise QueueFullError(len(self._q))
        self._q.append(msg)

    def flush(self) -> list[WireMessage]:
        drained = list(self._q)
        self._q.clear()
        return drained

    def __len__(self) -> int:
        return len(self._q)
```

No persistence (D-14 / FR-24). No TTL. The 10-cap is checked by `MeshNode`
before calling `enqueue` so it can present a user-friendly error.

The "offline counter reset" (D-15 / FR-23) is just `queue.flush()` + nothing
else — there's no separate counter because the queue itself *is* the counter.

---

## 10. UI layer (`ui/`)

### Textual App (`ui/app.py`)

Single-screen layout:

```
┌──────────────────────────────────────────────────┐
│ Messages (ScrollableContainer)                   │
│   10:23 dima#4521: привет                        │
│   10:24 vasya#2819: сам привет                   │
│   ...                                            │
├──────────────────────────────────────────────────┤
│ > _                                              │  ← Input widget
├──────────────────────────────────────────────────┤
│ 3 peers online  •  0 pending                     │  ← Footer status
└──────────────────────────────────────────────────┘
```

Widgets:

- `MessageList(VerticalScroll)` — owns a list of `MessageRow`. Auto-scrolls
  to bottom unless user scrolled up (track via `scroll_y` vs `max_scroll_y`).
- `Input` — stdlib Textual widget. `on_submitted` → call `node.send(content)`.
  On `QueueFullError` → display toast "OFFLINE — queue full" (FR-27, red style).
- `Footer` — reactive on `peer_count` and `queue_len`. Red style when
  `queue_len == 10`.

### First-run prompt (`ui/first_run.py`)

Separate Textual screen shown if `~/.okolica/config.json` missing.

- Single centered `Input` widget with placeholder "Enter your nickname".
- On submit: strip, validate (1..32 chars, non-empty). If invalid, show error,
  keep input open (A-3).
- If valid: generate `author_id`, random discriminator, write config, dismiss
  screen, proceed to chat.

### UI ↔ core wiring

UI doesn't `await` on node operations directly. Instead:

- `ChatApp` holds a reference to `MeshNode`.
- Node exposes **events** as async iterators:
  - `node.incoming_messages()` — new `Message` objects
  - `node.peer_count_changes()` — int changes
  - `node.queue_depth_changes()` — int changes
  - `node.history_updated()` — signal to re-read last-100
- UI runs background tasks consuming these streams and updating widgets.

This keeps UI from blocking on network I/O — Textual stays responsive even if
a `transport.send` is slow.

---

## 11. Entry point (`cli.py` + `__main__.py`)

```python
async def main(argv: list[str]) -> int:
    args = parse_args(argv)  # --config-dir, --version

    # 1. Ensure config dir exists
    ensure_dir(args.config_dir)

    # 2. Load or create identity
    identity = load_identity(args.config_dir) or await first_run_prompt(args.config_dir)

    # 3. Initialize DB + run migrations
    engine = create_async_engine(f"sqlite+aiosqlite:///{args.config_dir}/messages.db")
    await run_migrations(engine)
    store = MessageStore(engine)

    # 4. Wire everything up (composition root)
    transport = UdpTransport()
    await transport.start()  # needed early so local_port is known

    our_peer = Peer(
        author_id=identity.author_id,
        display=identity.display,
        ip=get_primary_ip(),
        port=transport.local_port,
    )

    discovery = ZeroconfDiscovery(service_type="_okolica._udp.local.")
    encryptor = NullEncryptor()
    queue = OutboundQueue(cap=10)

    node = MeshNode(
        identity=identity,
        transport=transport,
        discovery=discovery,
        encryptor=encryptor,
        store=store,
        queue=queue,
    )
    await node.start(our_peer=our_peer)

    # 5. Launch Textual app (blocks until Ctrl+C)
    try:
        await ChatApp(node=node, identity=identity).run_async()
    finally:
        await node.stop()
        await engine.dispose()

    return 0
```

Composition root stays dumb: instantiate concrete classes, wire them, hand
off to `MeshNode` and `ChatApp`. This is the only place that knows both
`UdpTransport` and `ZeroconfDiscovery` exist.

---

## 12. Testing strategy

Mapping of **acceptance criteria → test files**:

| A-ID  | Test file                          | Kind        | Notes                                    |
| ----- | ---------------------------------- | ----------- | ---------------------------------------- |
| A-1   | `tests/ui/test_first_run.py`       | UI          | Textual pilot + tmp config dir           |
| A-2   | `tests/unit/test_identity.py`      | unit        | roundtrip config.json                    |
| A-3   | `tests/ui/test_first_run.py`       | UI          | Invalid nick re-prompts                  |
| A-4   | `tests/integration/test_two_nodes` | integration | Two real UDP sockets + real zeroconf     |
| A-5   | `tests/integration/test_two_nodes` | integration |                                          |
| A-6   | `tests/integration/test_offline_queue` | integration | Start A alone, then bring B up       |
| A-7   | `tests/integration/test_offline_queue` | integration | Queue cap + reset                    |
| A-8   | `tests/integration/test_history_sync`  | integration | Pre-populate DB for A                 |
| A-9   | `tests/integration/test_history_sync`  | integration | Three-way merge                       |
| A-10  | `tests/integration/test_three_nodes`   | integration | Gossip forwarding + dedupe            |
| A-11  | `tests/unit/test_models.py`            | unit        | Pydantic validator                    |
| A-12  | `tests/integration/test_two_nodes`     | integration | Ctrl+C cleanup                        |
| A-13  | `tests/unit/test_ordering.py`          | unit        | Tiebreak on id                        |
| A-14  | `tests/unit/test_models.py` or similar | unit        | NullEncryptor identity                |

**Integration test pattern:**

```python
@pytest_asyncio.fixture
async def node_factory(tmp_path):
    """Spawns a fully-wired MeshNode on localhost with a fresh tmpdir."""
    nodes = []
    async def _make(name: str) -> MeshNode:
        node = await build_node(config_dir=tmp_path / name, nick=name)
        nodes.append(node)
        return node
    yield _make
    for n in nodes:
        await n.stop()

async def test_two_nodes_exchange(node_factory):
    a = await node_factory("alice")
    b = await node_factory("bob")
    await wait_until(lambda: len(a.peers) == 1, timeout=5.0)  # A-4
    await a.send("hello")
    msg = await wait_for_message(b, content="hello", timeout=1.0)  # A-5
    assert msg.author_id == a.identity.author_id
```

**`wait_until` / `wait_for_message`** — small polling helpers in `conftest.py`.
Avoid `asyncio.sleep(N)` in tests; poll with short intervals.

**Mocking policy (Constitution §8):**

- Real UDP sockets on localhost — **yes**.
- Real zeroconf — **yes** on Linux; may need `FakeDiscovery` on macOS CI if
  multicast is restricted (fallback plan).
- Real SQLite — **yes**, each test gets a tmp DB.
- Mocked: only filesystem on a few unit tests for cleanness.

**Coverage target:** 70%, enforced by `--cov-fail-under=70`.

---

## 13. pyproject.toml shape

Mirrors `gigachat-doc-helper`'s structure (Constitution §1 — match the
learned stack):

```toml
[project]
name = "okolica"
version = "0.1.0"
requires-python = ">=3.11,<3.13"
dependencies = [
    "textual>=0.80",
    "zeroconf>=0.132",
    "sqlalchemy[asyncio]>=2.0",
    "aiosqlite>=0.20",
    "alembic>=1.14",
    "pydantic>=2.10",
]

[dependency-groups]
dev = [
    "pytest>=8",
    "pytest-asyncio>=0.24",
    "pytest-cov>=5",
    "black>=24",
    "isort>=5",
    "pylint>=3",
    "mypy>=1.13",
    "pre-commit>=4",
]

[project.scripts]
okolica = "okolica.cli:main_sync"

[tool.pytest.ini_options]
asyncio_mode = "auto"
asyncio_default_fixture_loop_scope = "function"
testpaths = ["tests"]
addopts = [
    "-v", "-ra", "--tb=short",
    "--cov=src/okolica", "--cov-branch",
    "--cov-fail-under=70", "--cov-report=term-missing",
]

[tool.black]
line-length = 120
target-version = ["py311"]

[tool.isort]
profile = "black"
line_length = 120

[tool.mypy]
python_version = "3.11"
strict = true  # stricter than gigachat-doc-helper — learning project
```

---

## 14. Makefile

```makefile
.PHONY: install lint fmt test run

install:
	uv sync

fmt:
	uv run isort src tests
	uv run black src tests

lint:
	uv run pylint src
	uv run mypy src

test:
	uv run pytest

run:
	uv run okolica

migrate:
	uv run alembic -c src/okolica/db/alembic.ini upgrade head

revision:
	uv run alembic -c src/okolica/db/alembic.ini revision --autogenerate -m "$(m)"
```

---

## 15. Risks and open concerns

Carry-over from spec §8 plus implementation-specific:

- **R-1 (mDNS blocked in corp Wi-Fi)** — if it bites, add `discovery/static.py`
  with a JSON peer list. Interface is already abstracted.
- **R-2 (client isolation)** — untestable until we're on real Sber network.
  No fix plan; document as hard limitation.
- **R-3 (clock skew)** — accepted. v2 could add Lamport clocks in `core/ordering.py`.
- **R-4 (UDP >8KB fragmentation)** — monitor in integration tests, document
  limitation.
- **R-5 (Textual + zeroconf event loop interaction)** — both use asyncio, but
  zeroconf spawns its own threadpool for blocking socket calls. Watch for
  spurious event-loop-closed errors on shutdown. Mitigation: strict ordering
  in `node.stop()` — stop discovery before transport before engine.dispose.
- **R-6 (tests flaky on CI due to multicast)** — GitHub Actions Linux runners
  have mDNS; macOS runners are flaky. If we hit this, split test matrix: UI
  + unit + integration on Linux, UI + unit on macOS.

---

## 16. What this plan does NOT decide

Left for `tasks.md`:

- Task order (what's built first).
- Test-first vs implementation-first per task.
- How many PRs this becomes.
- Specific commit boundaries.
- `README.md` content.

Left for future PRs:

- CI setup (GitHub Actions YAML).
- Packaging / distribution (wheel vs source install).
- Release process.
