# cancho-mqtt-client

An MQTT 3.1.1 client library for [cancho](https://github.com/alpibrusl/cancho), written in cancho: connect, publish, subscribe, will,
QoS 0 and 1, and a reconnect with a bounded backoff. The other half of [cancho-mqtt](https://github.com/alpibrusl/cancho-mqtt): a cancho
program can publish and subscribe without an external client.

**Status: design only. Nothing is built.** The plan is [docs/design.md](docs/design.md), written before the code; its gates are fixed
there and each must be shown failing against a deliberately broken variant. The first user is the ingest and simulator of the PoC
platform in [cancho-industrial](https://github.com/alpibrusl/cancho-industrial) (issue #7).

**What it is not:** a broker (that is cancho-mqtt), an MQTT 5 client, a TLS client yet (the broker has no TLS either), or a program. The
ingest and the simulator are programs of the platform, not of this repository.

[EUPL-1.2](LICENSE).
