# cancho-mqtt-client: design

> **Status: slice 1 built (the codec); the state machine is not.** Claims are read from a named file, measured (with the command), or
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
| queued outgoing bytes while disconnected | 64 KiB | `client.queue-full` |
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

(1) the codec and its gates 1 and 2, no state machine **(built: `src/codec.cho`, 11 tests of its own, 5 against the broker's `mqtt.wire`, 12
mutants all killed; see below)**; (2) the state machine: connect, publish QoS 0, subscribe, ping, with `pub`/`sub`;
(3) QoS 1 and the window; (4) will and retained; (5) reconnect and backoff; (6) the package store and its check; (7) the platform's
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
