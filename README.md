# cancho-mqtt-client

An MQTT 3.1.1 client library for [cancho](https://github.com/alpibrusl/cancho), written in cancho: connect, publish, subscribe, will,
QoS 0 and 1, and a reconnect with a bounded backoff. The other half of [cancho-mqtt](https://github.com/alpibrusl/cancho-mqtt): a cancho
program can publish and subscribe without an external client.

**Status: slices 1 to 3 built: the packet codec and the client state machine (connect, QoS 0 and QoS 1 publish with a window and held messages, subscribe, ping, disconnect), with two example programs run against a real cancho-mqtt. Will/retain handling, reconnect and the package store are not built.** The plan is [docs/design.md](docs/design.md), written before the code; its gates are fixed
there and each is shown failing against a deliberately broken variant (`scripts/mutants.py`). The first user is the ingest and simulator of the PoC
platform in [cancho-industrial](https://github.com/alpibrusl/cancho-industrial) (issue #7).

**What it is not:** a broker (that is cancho-mqtt), an MQTT 5 client, a TLS client yet (the broker has no TLS either), or a program. The
ingest and the simulator are programs of the platform, not of this repository.

[EUPL-1.2](LICENSE).

## Run the gates

You need the compiler at the commit `cancho.toml` names, and a checkout of cancho-mqtt beside this one (the other implementation of the byte
layout; CI uses the commit cancho-industrial pins). Then:

```sh
cancho test src/codec.cho tests/codec_test.cho --std                          # the codec's own tests
cancho test ../cancho-mqtt/src/wire.cho src/codec.cho tests/broker_test.cho --std   # gate 1, against the broker's decoder and encoder
BROKER=/path/to/mqtt CANCHO=$(which cancho) python3 scripts/mutants.py                            # gate 7: every variant must be killed
cancho test src/codec.cho src/client.cho tests/client_test.cho --std          # the state machine
BROKER=/path/to/mqtt scripts/e2e.sh                                       # gate 3, the examples against a real broker
cancho fmt --check src tests examples && python3 scripts/lines.py
```
