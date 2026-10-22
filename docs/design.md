# cancho-mqtt-client: design

> **Status: slices 1 to 3 built (the codec; the state machine for connect, QoS 0 and QoS 1 publish, subscribe, ping, disconnect, with two example programs).** Claims are read from a named file, measured (with the command), or
> marked **choice** or **open**. Section 11 says what is built; section 10 says which probes are answered. A claim found false is
> corrected in place and marked *(corrected)*.

## 1. Scope

**In (v1).** An MQTT 3.1.1 client over plain TCP:

| Packet | Direction | v1 |
|---|---|---|
| CONNECT (clean session, keep-alive, user name and password, will) | out | encode |
| CONNACK | in | decode |
| PUBLISH (QoS 0 and 1; retain; dup) | out and in | encode and decode |
| PUBACK | out and in | encode and decode |
| SUBSCRIBE / SUBACK | out / in | encode / decode |
| UNSUBSCRIBE / UNSUBACK | out / in | encode / decode |
| PINGREQ / PINGRESP | out / in | encode / decode |
| DISCONNECT | out | encode |
| PUBREC, PUBREL, PUBCOMP (QoS 2) | both | **not in v1**: a received QoS 2 PUBLISH is refused with `client.qos2-unsupported`, and a subscribe asking for QoS 2 is clamped to 1 and says so |

Also in: a reconnect with a bounded backoff, a bound on every buffer, and a rule tag for every refusal.

**Out.** TLS (the broker has none; add when cancho-mqtt#31 lands), MQTT 5, WebSockets, QoS 2 publishing, persistence of unacknowledged
messages across a process restart, clustering. Each is a later issue with its own design section.

## 2. Why a new repository, and what it is not

The broker's authority row is `net_in`; a client's is `net_out`. Putting a client in the broker's repository would put both in one report
or two programs in one repo, which this project's rule (one program, one authority row) argues against. A library is also what other
programs import, with its own pin, like `cancho-pg` and `cancho-schema`. The ingest and the simulator of the PoC platform are
**programs**, they live in `cancho-industrial/platform/`, and they carry the authority row. This repository holds the library, a pair
of minimal examples (`pub`, `sub`) used by its tests, and nothing platform-specific.

## 3. The authority row

A library has no `main`, so it has no report of its own: the report is the program's. What this library may require of its caller is
stated, and a gate checks it (section 9, gate 4):

- network: a connected stream, handed in by the caller. The library never opens one itself in v1 of the state machine (section 4); a
  small `connect` helper takes the caller's `Net` capability and a literal address. Narrowing to one `host:port` is by the **caller**
  (cancho's `narrow` takes a literal; a library cannot be generic over an address: cancho's `docs/agent-tools.md` §3.1 and cancho-dns's
  design measured this). So a program's report says `net_out("<host:port>")` only if the program writes the literal.
- time: a `Clock` handed in. The library has no clock of its own, so a keep-alive and a backoff are driven by the caller's time.
- no files, no processes, no foreign code, no randomness (a client id is supplied, or derived from a caller-provided seed: **choice**,
  so the library needs no `/dev/urandom`).

## 4. Execution model

**Choice: a state machine, not a thread and not a callback.** The caller owns the socket and the event loop (cancho-mqtt, cancho-pg
and cancho-web all use a `Poller`); the library owns the protocol:

```
client.step(state, input_bytes, now_ms, out) -> (state, events, wants)
```

- `input_bytes`: what the caller read from the socket (possibly a partial packet; the library buffers up to the bound).
- `out`: a caller-owned buffer the library appends packets to; the caller writes it to the socket.
- `events`: a bounded list of values the caller reads: `Connected`, `Published(topic, payload, qos, retain)`, `Acked(packet_id)`,
  `Subscribed(filters, granted)`, `Refused(rule)`, `Closed`.
- `wants`: when the library next needs `step` called (the keep-alive or retry deadline), so the loop's poll timeout is derived, not
  guessed.

Why: the PoC's ingest runs in one loop with its HTTP listener and its PostgreSQL pool; a library that blocked or spawned would not
compose (cancho-pg's `docs/nonblocking.md` is the measured reason for the pool being a state machine). **Open (probe 1):** the exact
types `step` can take at the pinned compiler (a `res struct` state passed by value, as `cancho-web`'s stores are).

The reconnect is part of the machine: after `Closed`, `step` with the caller's `now_ms` yields a `wants.reconnect_at` per a backoff
(base, factor, ceiling, all bounded and defaulted; no jitter in v1 because the library has no randomness, **choice**: the caller may add
its own).

## 5. Memory and bounds

Every bound is a field of a `Config` with a compiled-in default and a hard ceiling, and exceeding one is a rule, never a trap:

| bound | default (**choice**, to be fixed by probe 2) | refusal |
|---|---|---|
| max packet size in | 16 KiB | `client.packet-too-large` |
| max topic length | 256 | `client.topic-too-long` |
| in-flight QoS 1 publishes | 16 | `client.window-full` (the caller retries after an `Acked`) |
| held (unacknowledged QoS 1) bytes | 64 KiB | `client.queue-full` *(corrected in slice 3: it is the unacknowledged messages that are kept, not a queue of unsent ones; a publish needs a connected machine)* |
| subscriptions per call | 16 | `client.too-many-filters` |

The state is a fixed-size structure sized from the `Config` at construction, in the style of the broker (which prints its own
`memory_bytes`): the library exposes `memory_bytes(config)` so a program can print it before connecting. **Open:** the formula, a
measured table (probe 2).

## 6. Rules

Every refusal has a tag `client.<name>`. Initial catalogue (each gets a fixture, and a test that the fixtures equal the catalogue, as
cancho-mqtt does with `mqtt rules`):

| rule | when |
|---|---|
| `client.malformed` | a packet from the broker breaks the framing or a field's rule |
| `client.unexpected-packet` | a packet that is not valid in this state (a PUBLISH before CONNACK) |
| `client.connack-refused` | the broker answered CONNACK with a non-zero code (the code is in the event) |
| `client.packet-too-large`, `client.topic-too-long`, `client.window-full`, `client.queue-full`, `client.too-many-filters` | section 5 |
| `client.bad-topic` | a topic name with a wildcard, or an empty one, on publish; a filter that is not valid on subscribe |
| `client.qos2-unsupported` | section 1 |
| `client.bad-packet-id` | a packet id of 0, or outside 1 to 65535, where one is required *(added by slice 1: the codec needed it)* |
| `client.bad-argument` | an encoder argument that breaks a rule: a QoS outside 0 and 1, a password with no user name, an empty client id without a clean session, a keep-alive outside 0 to 65535 *(added by slice 1)* |
| `client.keepalive-timeout` | no PINGRESP or any packet within the keep-alive plus a grace |
| `client.suback-failure` | the broker granted 0x80 for a filter |

**No input reaches a panic:** the decoders are total (a bounds check before every read, a negative code on failure), as in
cancho-mqtt's `wire.cho` (`docs/design.md` §1 there). The gate (section 9, gate 2) runs every prefix and every one-byte deletion of the
corpus, as cancho-ui does for its front end.

## 7. The codec: reuse the broker's, or write the inverse?

The broker's `mqtt.wire` decodes client-to-server packets and encodes server-to-client ones; this library needs the inverse. Options:

1. **Import `mqtt.wire` as a package** from cancho-mqtt (needs a published store; the broker does not publish one today: **open**, ask
   cancho-mqtt).
2. **Write the inverse here** and prove it against the broker's, by differential: whatever this library encodes, the broker's decoder
   accepts, and whatever the broker's encoder writes, this library's decoder accepts.

**Recommendation (choice): 2.** It keeps the library's pin independent of the broker's compiler (the bundle already builds three
compilers) and gives the differential an independent implementation to disagree with. The cost is duplicated byte layout code; the gate
below makes a disagreement a red build.

## 8. Packaging

A published package store (`.cancho-vcs`), like `cancho-pg` and `cancho-schema`: consumers `cancho vcs lock` / `fetch` it by commit, and
a CI check (`tests/stores.sh`, as cancho-pg has) fails when the committed store is not the store of the sources. The compiler revision
is part of the contract (a store records no hash of the `std` it was published against). **Open:** the compiler pin: the one
cancho-web pins (`a4572ea`), because that is the first consumer.

## 9. Gates (fixed here, each shown failing with a variant)

1. **Round trip.** Every packet this library encodes, the pinned broker's `wire` decodes with the same fields; every packet the broker
   encodes, this library decodes. Variant: an encoder that sets a reserved flag.
2. **Totality.** Every prefix and every one-byte deletion of a corpus (the broker's conformance fixtures plus this library's own)
   answers a code and never traps. Variant: a decoder with one bounds check removed.
3. **Against two brokers.** The examples `pub`/`sub` pass against the pinned cancho-mqtt and against Mosquitto, retained, will, and
   QoS 1 included. Variant: an off-by-one packet id.
4. **The caller's row.** A program that uses the library has a report with no `fs`, no `proc`, no `ffi`, and only the `net_out` the
   program's own literal names. Variant: a library function that reads a file.
5. **Rules.** The fixtures equal the catalogue (section 6). Variant: a rule with no fixture.
6. **Bounds.** Each section 5 bound is reached by a test and answers its rule. Variant: a bound that traps.
7. **Mutants.** Each guard in the decoders and the state machine has a mutant that a test kills, or a written reason it does not.
8. **Lines.** No file over 2,000 lines.

## 10. Probes to run before the interfaces are final

1. At the pinned compiler: what `step` can look like (state by value, caller-owned buffers, a bounded events list); does a `res struct`
   with several buffers pass through a loop, as `platform/` does with its stores.
   *Answered (slice 2):* yes, with a different shape than the sketch of section 4. There is no single `step`: a `pub res struct Client` is
   threaded by value through `open`, `feed`, `publish`, `subscribe`, `unsubscribe`, `tick` and `disconnect`, each answering the machine, the
   caller's `out` buffer and a code or a count. A `res` field cannot be read out of a value, so each function reads what it needs inside a
   `borrow` and takes the struct apart with a destructuring `let` to rebuild it (the same shape as `platform/`'s stores). `connect` is a
   builtin name, so the function is `open`.
2. The memory formula: measure the state at several `Config`s; fix the defaults of section 5 from that.
3. How a program reads a partial packet from a non-blocking connection at this pin (`cancho-pg`'s pool is the worked example).
4. What cancho-mqtt's conformance fixtures offer to import for gate 2, and whether they can run unchanged.
   *Answered in part (slice 1):* `mqtt.wire` itself compiles with the compiler this repository pins (`a4572ea`, the broker pins a newer one)
   and its own 10 tests pass there: `cancho test src/wire.cho tests/wire_test.cho --std` in a cancho-mqtt checkout. That is what made a
   differential against the real decoder possible without the broker's compiler. The broker's conformance fixtures (Python, over sockets)
   were not looked at; they belong to gate 3.
5. Whether Mosquitto's behaviour on a will, a retained message and a duplicate client id differs from the broker's in ways the client
   must tolerate (`docs/side-by-side.md` in cancho-mqtt records what the broker and Mosquitto both did).

## 11. Slices

(1) the codec and its gates 1 and 2, no state machine **(built: `src/codec.cho`)**; (2) the state machine: connect, publish QoS 0,
subscribe, ping, with `pub`/`sub` **(built: `src/client.cho`, `examples/`; see section 14)**;
(3) QoS 1 and the window **(built; see section 15)**; (4) will and retained **(built; see section 16)**; (5) reconnect and backoff **(built; see the end of section 17)**; (6) the package store and its check; (7) the platform's
ingest and simulator (in cancho-industrial, not here).

## 12. Open questions for the owner

1. The compiler pin: cancho-web's (`a4572ea`) or the broker's newer one (after the pin bump, cancho-industrial#3)?
2. QoS 2 publishing: wanted for the PoC, or later?
3. Is a `connect` helper in the library acceptable (it takes the caller's `Net`), or must the caller always hand in a connected stream?

## 13. What slice 1 built, and what it did not

Built: `src/codec.cho` (module `mqttc.codec`), the packets of section 1 in both directions; `tests/codec_test.cho` (packets written as hex, so
they do not depend on the encoder; a sweep of every prefix, every one-byte deletion and 16 one-byte changes per position of 8 valid packets, then 4,000
random buffers; 3,000 random argument sets for the encoders); `tests/broker_test.cho` (gate 1, both directions, against cancho-mqtt's
`src/wire.cho` at the commit in `.github/workflows/ci.yml`); `scripts/mutants.py` (gate 7, 12 variants) and `scripts/lines.py` (gate 8).

Not built, and not claimed: the state machine (`client.step`, section 4); the bounds of section 5 beyond the codec's own (`max_filters` is 16,
the 16-bit string limit, the remaining-length limit); the rules `client.keepalive-timeout`, `client.suback-failure`, `client.window-full`,
`client.queue-full`, `client.topic-too-long` (they belong to the machine); gate 3 (against two brokers), gate 4 (the caller's authority row; a
library has none until an example program uses it) and gate 6 beyond the codec; the package store of section 8.

Found while building it: a failed `test.assert_eq` ends the test the way a trap does (`killed by signal 4`), so a wrong expectation in a test
looks like a crash of the code under test; read the assertion before suspecting the codec. `a/` is a valid topic filter (an empty last
level), which the first version of a test got wrong.

## 14. What slice 2 built, and what it did not

Built: `src/client.cho` (module `mqttc.client`): `new`, `open` (CONNECT), `feed` (bytes in; events out; a PUBACK appended for an incoming
QoS 1 message), `publish` (QoS 0), `subscribe`, `unsubscribe`, `tick` (a PINGREQ at the keep-alive, the broker declared silent after half a
keep-alive of grace, at least a second), `disconnect`, `inbox`/`clear_inbox`. `examples/pub.cho` and `examples/sub.cho` with `examples/pump.cho`
(the socket half, kept out of the library). Tests: `tests/client_test.cho` (11, driving the machine with packets written as hex, including a
packet fed in fragments, a full event table, the keep-alive clock, eight broker refusals, and a sweep of 300 random machines of 12 random
steps each); `scripts/e2e.sh` (the examples against a real cancho-mqtt: `sub` on `plant/#` printed the two messages published under it and
not the one published elsewhere, and the broker logged no refusal); `scripts/mutants.py` now has 21 variants of the codec and the machine,
all killed, and 1 equivalent variant written down with its reason.

Choices made, not in the sketch above: any packet from the broker clears an outstanding ping (not only PINGRESP); events are `[kind, a, b, c,
d, e]` in a caller-owned table, and when the table fills the rest of the input stays inside the machine until `feed` is called again with no
bytes; received topics and payloads are copied into an `inbox` the events point into.

Not built, and not claimed: QoS 1 publishing, its window and its retries (slice 3: `publish` with QoS 1 answers `client.bad-argument`); will
and retained handling beyond what CONNECT and PUBLISH already carry (slice 4); reconnect and backoff (slice 5); the package store (slice 6);
Mosquitto as the second broker of gate 3 (it is not installed in the environment this was built in); gate 4; the memory formula of section 5.

**Corrected in place.** Section 5 said the state is "a fixed-size structure sized from the `Config` at construction". What is built is two
growable buffers: `rx`, bounded by `max_packet` (a header that declares more is refused before its body is read), and `inbox`, which grows
with every received message until the caller calls `clear_inbox`. The examples clear it after every `feed`; a caller that does not can make
it grow without bound. A cap on the inbox, and `memory_bytes`, are the open items of section 5.

Found while building it: the examples' reads block, so the keep-alive cannot fire while they wait; they set no keep-alive. A program with a
loop of its own (a `Poller`, as the platform's ingest will have) calls `tick` and waits at most what it answers.

## 15. What slice 3 built, and what it did not

Built, in `src/client.cho`:

- `publish` at QoS 1 answers the packet id (1 to 65535) and holds the packet until its PUBACK. A packet id skips any id a held message still uses
  (2.3.1), including when the ids wrap. Refusals: `client.window-full` (default window 16, `set_window` 1 to 256), `client.queue-full` (the held
  bytes would pass 65,536), `client.qos2-unsupported`, `client.not-connected`.
- A PUBACK frees the held message it names and is reported as `ev_acked` with `b` = 1; one that names nothing held is reported with `b` = 0 and ignored.
- `inflight` says how many are held. `resend` writes every held message again with DUP set, in the order first sent.
- Sessions: `open` with a clean session discards what was held (3.1.2.4); a CONNACK that says session present 0 discards it too (3.2.2.2); a kept
  session keeps it.
- `examples/pub` takes a QoS; at 1 it waits for the broker's PUBACK before it disconnects.

**Corrected in place.** The sketch for this slice said "QoS 1 and the window ... retries". MQTT 3.1.1 (4.4) allows a client to send an
unacknowledged PUBLISH again only after the connection was re-established; resending on a timer over a live connection is not allowed. So there is no
retry timer. The held messages and `resend` are the mechanism; calling `resend` after a reconnect with a kept session is the reconnect policy of slice 5.

Run here (the tests need no broker; the end-to-end run needs one):

- `tests/client_test.cho`: 16 tests (5 new): the QoS 1 bytes and ids, PUBACK freeing and the stray PUBACK, the window and the held-bytes bound (eight 8,000-byte
  messages fit, the ninth does not), `resend` with DUP, the three session cases, and 65,535 ids with one held under id 1 (the next id is 2). The random
  sweep now publishes at QoS 1 and feeds PUBACKs.
- `scripts/e2e.sh`: against a real cancho-mqtt, `pub` at QoS 1 returned after the PUBACK, and `sub` printed the message.
- `scripts/mutants.py`: 8 new variants of the machine (a PUBACK that does not free, the window ignored, the bound ignored, no DUP on resend, a clean session
  that keeps what was held, a lost session that keeps it, a stray PUBACK counted as matched, an id that may take a held one), all killed.

Not built: QoS 2 (a received QoS 2 PUBLISH is still refused); an automatic resend after a reconnect (slice 5); persistence of the held messages across a
restart of the program (they live in the machine); the memory figure of section 5. The held bytes are bounded now; the inbox still is not
(section 14).

## 16. What slice 4 built, and what it did not

**A finding first.** The sketch for this slice listed "will and retained handling" as new code. It is not: the library already carried both, from
slice 1 (`put_connect` takes the will and its QoS and retain flag; `put_publish` takes `retain`; an incoming PUBLISH reports `qos + 4 * retain` in
`ev_message`) and slice 2 (`open` and `publish` pass them through). What was missing was every check that they work in the machine and against a
real broker, and a way to use them from the examples. The slice is that, and no library code changed.

Built:

- `tests/client_test.cho`: 18 tests (2 new). `test_will_rides_in_connect`: six refusals (will QoS 2, QoS 3, a retain flag of 2, a wildcard topic, a
  message without a topic, a retain flag without a topic) each leave the machine closed and write nothing; then the exact CONNECT bytes for a QoS 1
  retained will (connect flags `0x2E`) and for an empty message at QoS 0. `test_retain_flag_both_ways`: the first byte of PUBLISH at QoS 0 and 1 with
  and without retain, a retain flag of 2 or -1 refused with nothing written, an empty retained payload (the way to clear one, 3.3.1-10), and an
  incoming retained and live PUBLISH reported as 4 and 0.
- `examples/pub` takes a retain argument; `examples/sub` ends a retained message's line with ` [retained]`; new `examples/will` connects with a
  will and ends either by dropping the socket or by sending DISCONNECT.
- `scripts/e2e.sh`, against a real cancho-mqtt: a live subscriber sees a retained message unmarked and a late one sees it marked; an empty retained
  message clears it; a will is published when the socket drops, is not published after DISCONNECT, and a retained will is kept for a late
  subscriber. The run took about 9 s, mostly its own waits.
- `scripts/mutants.py`: 4 new variants of the machine (the will not sent, its retain flag not sent, the retain flag of PUBLISH not sent, an
  incoming retained message reported as live), all killed, each by the unit tests and by the end-to-end run.

Not built, and not claimed: will and retained behaviour against a second broker (Mosquitto is not installed here; section 9 still lists it as
gate 3's other half); a will at QoS 1 end to end (the unit test covers its bytes; the example sends QoS 0); the broker's limits on a will's size
and on the retained table (the broker's `limit.will-size` and `limit.retained` refusals are not provoked by any test here); reconnect and backoff
(slice 5).

## 17. Slice 5: reconnect and backoff (design, written before the code)

**Corrected in place.** Section 4 said the reconnect is part of the machine and that `step` yields a `wants.reconnect_at`. The machine as built
(sections 13 to 16) has no `step`; the caller owns the socket, the loop and the clock, and the machine already hands back the time to the next
`tick`. Putting a retry schedule inside it would add two fields to `Client` for a value the caller needs only while it has no connection, when
there is no machine activity to hang it on. **Choice:** the schedule is a pure function and the caller keeps its two counters.

Library, in `src/client.cho`:

- `lost(c)`: the caller says the connection is gone (end of stream, a failed read or write, or `tick` answering `e_keepalive`). The machine becomes
  closed without writing a DISCONNECT; the held messages, the packet ids and the inbox stay, because a kept session may still need them. A
  half-read packet stays until `open` drops it (one place, so no second clear to test around). Answers the machine. Total: on a machine that is already closed it changes nothing.
- `open` drops any half-read packet left from the previous connection (a CONNACK must not be parsed after the tail of an old packet).
- `backoff_ms(base, ceiling, failures)`: `base` times 2 to the power `failures`, never above `ceiling`; no overflow for any `failures`.
  `base` 1 to 60,000, `ceiling` from `base` to 3,600,000, `failures` 0 or more; anything else is `client.bad-argument`. No jitter (the library has
  no randomness, section 4); a caller that wants it adds its own to the answer.
- `resend` stays the caller's explicit step and is **not** made automatic: after `ev_connected` with the session kept (`a` = 1) and `inflight`
  above 0, the caller calls it. Reason: `feed` answers events, and a library that wrote a burst of DUP packets inside `feed` would hide the
  largest write the machine makes from the loop that has to send it; one named call is easier to bound and to test.

Reconnect policy (the caller's, shown by the example): `failures` counts attempts since the last CONNACK 0; a refused or failed attempt adds 1; an
accepted CONNACK sets it to 0; the next attempt is `backoff_ms(base, ceiling, failures)` after the failure. A CONNACK refusal that no retry can
fix (bad protocol level, identifier, bad credentials: return codes 1, 4 and 5) is not retried by the example; 2 and 3 are.

Example: `examples/watch`, a subscriber that survives its broker. It dials, opens with a persistent session, subscribes, prints messages,
and when the connection ends waits `backoff_ms` and does it again. The example has no sleep (cancho has no builtin, and `Poller` as a sleep is
untried, cancho's `docs/atomics.md` section 6.1), so the wait spins on `clock_ms`; the example is not for production and says so.

Gates to run, each shown failing:

1. Unit: `lost` keeps the held messages and the ids; a half-read packet before `lost` does not break the next connection; `backoff_ms` doubles,
   caps, never overflows (failures up to 100,000), refuses the bad arguments; a kept session resends after `lost`, `open`, CONNACK 1 with the
   bytes of slice 3.
2. End to end with a real cancho-mqtt: `watch` is started before any broker exists and connects once one does; it prints a message, the broker
   is killed and started again, and it prints the next one. (The delays themselves are not observed from outside; they are unit-tested.)
3. Mutants of the machine and of `backoff_ms` (no cap, linear instead of doubling, off by one, a negative failure count accepted, `lost` that leaves
   the machine open, `open` that keeps half-read bytes), all killed.

Not in this slice, said now so it is not claimed later: a resend against a real broker that dropped a PUBACK (no way found to provoke the loss
without a second program that sits between client and broker); jitter; a total retry limit.

**Built (slice 5).** As designed, with these differences found on the way:

- `examples/watch` writes to standard output, which cancho's `Io` buffers fully when it is not a terminal, so a `watch` killed by a signal prints
  nothing. The end-to-end run therefore lets `watch` exit by itself (count 2) and reads its output afterwards. Each message is published retained, so
  the run does not depend on the timing of the subscribe.
- Mutant `lost` that clears the half-read packet **and** `open` that clears it left two survivors (each hid the other). The clear now lives in
  `open` only.
- Tests: `tests/client_test.cho` has 20 (2 new): `lost` keeps the session and `open` drops half a packet, then `resend` writes the held message
  again with DUP and the next new message takes the next id; `backoff_ms` doubles, caps, never overflows (failures up to 2,000,000,000) and refuses
  the five bad arguments.
- End to end (`scripts/e2e.sh`, about 16 s in all): `watch` started with no broker connects when one appears, prints a retained message, survives
  the broker being killed and started again, and prints the second. The run took 15.7 s here.
- Mutants: 6 new variants, all killed (the four of `backoff_ms` and the two of `lost` and `open`).

Not shown: the resend against a real broker that dropped a PUBACK; `watch` leaves the sleep as a spin on the clock.

## 18. Slice 6: the package store (design, then what was built)

**Decision.** Two published stores, like `cancho-pg`'s: `.cancho-vcs` holds `mqttc.codec` (`src/codec.cho`, requiring nothing) and `.cancho-vcs-client` holds `mqttc.client` (`src/client.cho`, requiring the
names it calls of the codec's store, which it records by path relative to itself, so the two are committed side by side). A consumer does `cancho vcs lock --store S -o f NAME...` for the names it calls and
`cancho vcs fetch --lock f --store S -o dir`, then builds with the fetched files. The compiler is the one `cancho.toml` pins (`a4572ea`, cancho-web's, the first consumer): a store records no hash of the
`std` it was published against, so the pin is part of the contract (section 8, now closed).

**The names a store requires are read from the source** (`codec.NAME` in `src/client.cho`), not written down: a list kept by hand drifts from the code it describes.

**Gates, fixed before the stores were written:**

1. `tests/stores.sh`: publish afresh into a scratch directory and require the committed stores equal it (`write` makes them equal). Variant: a source changed and the stores not rewritten.
2. `tests/consume.sh EXAMPLE`: lock the names an example calls, fetch, build from the fetched files and not from `src/`, and require the same authority report as the source build (gate 4 of section 9: a `net_out`
   and nothing else) and the same answer with no arguments. Variants: a source file of a store deleted; one byte of it changed; the client's store losing its source.
3. `tests/consume.sh --out DIR` then `E2E_BIN=DIR scripts/e2e.sh`: the whole end-to-end run (QoS 0 and 1, retained, will, a watcher that outlives its broker) with the four programs built from the fetched stores.

**What it found / said plainly.** A store holds one source file (`sources/`, all the published functions) and one file per published function (`ops/`) beside a manifest: 74 files and 68,378 bytes for the codec's, 48 files and 69,553 bytes for the client's, committed.
`stores.sh` uses `cp -R`, not `rsync` (cancho-pg's uses `rsync`, which a stock machine may lack). The stale-store variant is caught only by `stores.sh`, and the deleted and altered ones only (also)
by `consume.sh`: `stores.sh` compares the committed bytes with a fresh publication, `consume.sh` shows the committed stores can be used. A store that is stale but consistent passes `consume.sh`; that is
what gate 1 is for.

Measured here: `stores.sh` equal for both stores; `consume.sh` for `pub`, `sub`, `will` and `watch` (report equal, usage answer equal, exit 2); `scripts/e2e.sh` with the programs built from the stores passes
exactly as with the programs built from the sources; four store variants killed.
