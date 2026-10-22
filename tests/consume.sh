#!/bin/sh
# A consumer of the committed stores (docs/design.md section 18): lock the names an example program calls, fetch them, and build the program from what was fetched
# and not from src/. The built program must have the report of the one built from the sources (gate 4: a net_out and nothing else) and answer its usage the same way.
#
#   sh tests/consume.sh [example]        default: pub
#   sh tests/consume.sh --out DIR        every example (pub, sub, will, watch), each checked as above, the binaries left in DIR for scripts/e2e.sh (E2E_BIN=DIR)
set -eu
cd "$(dirname "$0")/.."
LEX=${CANCHO:-cancho}
if [ "${1:-}" = "--out" ]; then
    mkdir -p "$2"
    for e in pub sub will watch; do KEEP="$2" sh "$0" "$e"; done
    exit 0
fi
EX=${1:-pub}
OUT=$(mktemp -d)
names() {  # names MODULE FILE...  the NAMEs written as MODULE.NAME in the files
    m=$1; shift
    cat "$@" | grep -o "$m"'\.[a-z_0-9][a-z_0-9]*' | sed "s/^$m\.//" | sort -u | tr '\n' ' '
}
CODEC=$(names codec examples/"$EX".cho examples/pump.cho)
CLIENT=$(names client examples/"$EX".cho examples/pump.cho)
# a name that is only a module (the import line) is not a function
CODEC=$(for n in $CODEC; do [ "$n" = "codec" ] || echo "$n"; done | tr '\n' ' ')
mkdir -p "$OUT/deps"
if [ -n "$CODEC" ]; then
    $LEX vcs lock --store .cancho-vcs -o "$OUT/codec.lock" $CODEC >/dev/null
    $LEX vcs fetch --lock "$OUT/codec.lock" --store .cancho-vcs -o "$OUT/deps" >/dev/null
fi
$LEX vcs lock --store .cancho-vcs-client -o "$OUT/client.lock" $CLIENT >/dev/null
$LEX vcs fetch --lock "$OUT/client.lock" --store .cancho-vcs-client -o "$OUT/deps" >/dev/null
$LEX build --std examples/"$EX".cho examples/pump.cho "$OUT"/deps/*.cho -o "$OUT/$EX" >/dev/null
$LEX authority --std examples/"$EX".cho examples/pump.cho "$OUT"/deps/*.cho | sed '/^provably pure/,$d' > "$OUT/fetched.txt"
$LEX authority --std examples/"$EX".cho examples/pump.cho src/codec.cho src/client.cho | sed '/^provably pure/,$d' > "$OUT/source.txt"
diff "$OUT/fetched.txt" "$OUT/source.txt" || { echo "consume: the report of $EX built from the stores differs from the one built from the sources" >&2; exit 1; }
"$OUT/$EX" > "$OUT/fetched.out" 2>&1 || fetched=$?
$LEX build --std examples/"$EX".cho examples/pump.cho src/codec.cho src/client.cho -o "$OUT/$EX.src" >/dev/null
"$OUT/$EX.src" > "$OUT/source.out" 2>&1 || source=$?
[ "${fetched:-0}" = "${source:-0}" ] && diff "$OUT/fetched.out" "$OUT/source.out" >/dev/null || { echo "consume: $EX from the stores answers differently with no arguments" >&2; exit 1; }
[ -z "${KEEP:-}" ] || cp "$OUT/$EX" "$KEEP/$EX"
echo "consume: $EX built from the fetched stores has the report of the one built from the sources, and answers alike (exit ${fetched:-0})" >&2
