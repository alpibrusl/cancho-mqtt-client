#!/usr/bin/env python3
"""Every gate must be able to fail (design section 9, gates 1, 2 and 7): apply one deliberate break to src/codec.cho at a time and require
that the tests (the codec's own and the differential against cancho-mqtt's `mqtt.wire`) fail.

    CANCHO=/path/to/cancho python3 scripts/mutants.py             # run every variant; exit 1 if one survives
    python3 scripts/mutants.py --list

`../cancho-mqtt` must be a checkout of cancho-mqtt (design section 9, gate 1).
"""
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANCHO = os.environ.get("CANCHO", "cancho")
BROKER = (ROOT / ".." / "cancho-mqtt" / "src" / "wire.cho").resolve()

# name: (what the variant is, text to find exactly once, its replacement)
MUTANTS = {
    "subscribe-without-required-flag": ("SUBSCRIBE written without the reserved flag bit 2 (3.8.1)", "var first = 162;\n    if with_qos {\n        first = 130;", "var first = 160;\n    if with_qos {\n        first = 128;"),
    "puback-packet-id-off-by-one": ("PUBACK carries pid + 1", "    out[at + 1] = byte_of(2);\n    return put16(out, at + 2, pid);", "    out[at + 1] = byte_of(2);\n    return put16(out, at + 2, pid + 1);"),
    "publish-dup-bit-dropped": ("PUBLISH never sets DUP", "    if dup == 1 {\n        first = first + 8;\n    }", "    if dup == 2 {\n        first = first + 8;\n    }"),
    "length-edge-wrong": ("a remaining length of 127 takes two bytes", "    if n < 128 {\n        return 1;\n    }", "    if n < 127 {\n        return 1;\n    }"),
    "decoder-bounds-check-removed": ("decode_publish no longer checks the topic fits the packet", "    p = p + 2;\n    if p + tl > end {\n        return e_malformed();\n    }\n    // A broker's topic", "    p = p + 2;\n    // A broker's topic"),
    "connack-reserved-bits-accepted": ("a CONNACK with reserved acknowledge bits is accepted", "if ack > 1 || code > 5 {", "if code > 5 {"),
    "wildcard-allowed-in-publish-name": ("a publish name may hold a wildcard", "    if len(name) == 0 || len(name) > string_limit() || has_wildcard(name) {\n        return false;", "    if len(name) == 0 || len(name) > string_limit() {\n        return false;"),
    "hash-not-last-allowed": ("a filter may have # before the last level", "if c == 35 && (n != 1 || !at_end) {", "if c == 35 && n != 1 {"),
    "qos2-publish-accepted": ("a QoS 2 PUBLISH is not refused", "    if qos == 2 {\n        return e_qos2();\n    }\n    // [MQTT-3.3.1-2]", "    // [MQTT-3.3.1-2]"),
    "connect-flags-user-bit": ("CONNECT forgets the user name flag", "        flags_byte = flags_byte + 128;", "        flags_byte = flags_byte + 0;"),
    "suback-reserved-code-accepted": ("a SUBACK return code of 3 is accepted", "if c != 0 && c != 1 && c != 2 && c != 128 {", "if c != 0 && c != 1 && c != 2 && c != 3 && c != 128 {"),
    "keepalive-range-unchecked": ("a keep-alive over 65535 is written", "    if keepalive < 0 || keepalive > 65535 {\n        return e_argument();\n    }", "    if keepalive < 0 {\n        return e_argument();\n    }"),
}


def run(source_text):
    with tempfile.TemporaryDirectory() as d:
        codec = pathlib.Path(d) / "codec.cho"
        codec.write_text(source_text)
        failed = []
        for sources in ([codec, ROOT / "tests" / "codec_test.cho"], [BROKER, codec, ROOT / "tests" / "broker_test.cho"]):
            r = subprocess.run([CANCHO, "test", *map(str, sources), "--std"], capture_output=True, text=True)
            if r.returncode != 0:
                failed.append(sources[-1].name)
        return failed


def main():
    if "--list" in sys.argv:
        for k, (what, _, _) in MUTANTS.items():
            print(f"{k}: {what}")
        return 0
    base = (ROOT / "src" / "codec.cho").read_text()
    if run(base):
        print("the unmodified codec does not pass its own tests; fix that first")
        return 2
    survivors = []
    for name, (what, old, new) in MUTANTS.items():
        if base.count(old) != 1:
            print(f"BAD   {name}: the text to replace occurs {base.count(old)} times")
            return 2
        failed = run(base.replace(old, new))
        if failed:
            print(f"killed {name} (by {', '.join(failed)})")
        else:
            print(f"SURVIVED {name}: {what}")
            survivors.append(name)
    print(f"{len(MUTANTS) - len(survivors)} of {len(MUTANTS)} killed")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
