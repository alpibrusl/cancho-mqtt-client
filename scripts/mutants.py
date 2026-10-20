#!/usr/bin/env python3
"""Every gate must be able to fail (design section 9, gates 1, 2, 3 and 7): apply one deliberate break to src/codec.cho at a time and require
that the tests (the codec's own, the state machine's, the differential against cancho-mqtt's `mqtt.wire`) fail. With BROKER set, the
end-to-end run against a real broker (scripts/e2e.sh) also counts, and must itself fail for some variants.

    CANCHO=/path/to/cancho [BROKER=/path/to/mqtt] python3 scripts/mutants.py     # run every variant; exit 1 if one survives
    python3 scripts/mutants.py --list

`../cancho-mqtt` must be a checkout of cancho-mqtt (design section 9, gate 1).
"""
import shutil
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANCHO = os.environ.get("CANCHO", "cancho")
BROKER = (ROOT / ".." / "cancho-mqtt" / "src" / "wire.cho").resolve()

# name: (what the variant is, text to find exactly once, its replacement) in src/codec.cho; CLIENT_MUTANTS are the same for src/client.cho
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

CLIENT_MUTANTS = {
    "client-no-puback-for-qos1": ("an incoming QoS 1 message is not acknowledged", "                                        if t[5] == 1 {", "                                        if t[5] == 7 {"),
    "client-connack-first-rule-removed": ("a PUBLISH before CONNACK is accepted", "                    if st == 1 && k != 2 {", "                    if st == 7 && k != 2 {"),
    "client-second-connack-accepted": ("a second CONNACK is accepted", "                    if st == 2 && k == 2 {", "                    if st == 7 && k == 2 {"),
    "client-alive-not-noticed": ("a packet from the broker does not clear the outstanding ping", "                    ping = 0 - 1;\n", "                    ping = ping;\n"),
    "client-grace-ignored": ("the keep-alive grace is zero: the broker is declared silent at once", "    if keepalive_ms / 2 < 1000 {\n        return 1000;\n    }\n    return keepalive_ms / 2;", "    return 0;"),
    "client-pid-not-advanced": ("every SUBSCRIBE reuses one packet id", "next_pid: bump(next_pid) }, appended, pid);", "next_pid: next_pid }, appended, pid);"),
    "client-message-offsets-wrong": ("the payload offset of a message points at the topic", "ne = emit(events, ne, ev_message(), at, t[1], at + t[1], t[4], t[5] + 4 * t[6]);", "ne = emit(events, ne, ev_message(), at, t[1], at, t[4], t[5] + 4 * t[6]);"),
    "client-ping-never-sent": ("the keep-alive never sends a PINGREQ", "    let due = last_sent + keepalive_ms;\n    if now >= due {", "    let due = last_sent + keepalive_ms;\n    if now >= due + 1000000000 {"),
    "client-publish-before-connack": ("publish is allowed before CONNACK", "    if st0 != 2 {\n        return (c, out, codec.e_state());\n    }\n    if qos != 0 {", "    if st0 != 2 && st0 != 1 {\n        return (c, out, codec.e_state());\n    }\n    if qos != 0 {"),
}

# Variants that cannot be killed because they change no behaviour, each with the reason (they are run and must survive, so a reason
# that stops being true is a red build).
EXPLAINED = {
    "client-closed-takes-input": ("a closed machine appends the bytes it is given", "    if state != 0 {\n        received = buffer.append(heap, received, data);\n    }", "    received = buffer.append(heap, received, data);",
                                  "the loop does not run for a closed machine and the bytes are dropped afterwards: the guard only saves a copy"),
}


def run(source_text, client_text=None):
    with tempfile.TemporaryDirectory() as d:
        codec = pathlib.Path(d) / "codec.cho"
        codec.write_text(source_text)
        client = pathlib.Path(d) / "client.cho"
        client.write_text(client_text if client_text is not None else (ROOT / "src" / "client.cho").read_text())
        failed = []
        suites = ([codec, ROOT / "tests" / "codec_test.cho"], [BROKER, codec, ROOT / "tests" / "broker_test.cho"],
                  [codec, client, ROOT / "tests" / "client_test.cho"])
        for sources in suites:
            r = subprocess.run([CANCHO, "test", *map(str, sources), "--std"], capture_output=True, text=True)
            if r.returncode != 0:
                failed.append(sources[-1].name)
        if os.environ.get("BROKER"):
            # The whole tree in a scratch directory with the broken codec, so the examples are built from it.
            tree = pathlib.Path(d) / "tree"
            shutil.copytree(ROOT, tree, ignore=shutil.ignore_patterns(".git", "build"))
            (tree / "src" / "codec.cho").write_text(source_text)
            (tree / "src" / "client.cho").write_text(client.read_text())
            r = subprocess.run(["bash", str(tree / "scripts" / "e2e.sh"), "18890"], capture_output=True, text=True)
            if r.returncode != 0:
                failed.append("e2e")
        return failed


def main():
    if "--list" in sys.argv:
        for k, (what, _, _) in list(MUTANTS.items()) + list(CLIENT_MUTANTS.items()):
            print(f"{k}: {what}")
        return 0
    base = (ROOT / "src" / "codec.cho").read_text()
    if run(base):
        print("the unmodified codec does not pass its own tests; fix that first")
        return 2
    survivors = []
    base_client = (ROOT / "src" / "client.cho").read_text()
    everything = [(n, w, o, nw, False) for n, (w, o, nw) in MUTANTS.items()] + [(n, w, o, nw, True) for n, (w, o, nw) in CLIENT_MUTANTS.items()]
    for name, what, old, new, in_client in everything:
        text = base_client if in_client else base
        if text.count(old) != 1:
            print(f"BAD   {name}: the text to replace occurs {text.count(old)} times")
            return 2
        failed = run(base, text.replace(old, new)) if in_client else run(base.replace(old, new))
        if failed:
            print(f"killed {name} (by {', '.join(failed)})")
        else:
            print(f"SURVIVED {name}: {what}")
            survivors.append(name)
    for name, (what, old, new, reason) in EXPLAINED.items():
        if base_client.count(old) != 1:
            print(f"BAD   {name}: the text to replace occurs {base_client.count(old)} times")
            return 2
        if run(base, base_client.replace(old, new)):
            print(f"KILLED {name}, which was written down as equivalent ({reason}): update EXPLAINED")
            return 1
        print(f"explained {name}: {reason}")
    print(f"{len(everything) - len(survivors)} of {len(everything)} killed, {len(EXPLAINED)} explained")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
