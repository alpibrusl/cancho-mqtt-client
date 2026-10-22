#!/bin/sh
# The two package stores of this repository, published afresh from the sources (docs/design.md sections 8 and 18):
#
#   .cancho-vcs         mqttc.codec   src/codec.cho, requiring nothing
#   .cancho-vcs-client  mqttc.client  src/client.cho, requiring the names it calls of the codec's store
#
#   sh tests/stores.sh          publish into a fresh directory and compare each store with the committed one (CI runs this)
#   sh tests/stores.sh write    publish, and make the committed stores those (after a change to a source, or of the compiler)
#
# The client's store records the codec's by its path relative to itself, so the two are published side by side, as they are committed. The names it
# requires are the ones src/client.cho writes as `codec.NAME`: read from the source here, so the list cannot drift from it. CANCHO names the compiler.
set -eu
cd "$(dirname "$0")/.."
LEX=${CANCHO:-cancho}
OUT=$(mktemp -d)
# keep the published stores for a look when a check fails
echo "publishing into $OUT" >&2

NAMES=$(grep -o 'codec\.[a-z_0-9]*' src/client.cho | sed 's/codec\.//' | sort -u | tr '\n' ' ')
$LEX vcs publish --std --store "$OUT/.cancho-vcs" src/codec.cho >/dev/null
$LEX vcs lock --store "$OUT/.cancho-vcs" -o "$OUT/client-codec.lock" $NAMES >/dev/null
$LEX vcs publish --std --store "$OUT/.cancho-vcs-client" --requires "$OUT/client-codec.lock:$OUT/.cancho-vcs" src/client.cho >/dev/null

if [ "${1:-check}" = write ]; then
    for s in .cancho-vcs .cancho-vcs-client; do
        rm -rf "$s"
        cp -R "$OUT/$s" "$s"
    done
    echo "written" >&2
    exit 0
fi
status=0
for s in .cancho-vcs .cancho-vcs-client; do
    if diff -r "$OUT/$s" "$s"; then
        echo "$s: the store of the source" >&2
    else
        echo "$s: NOT the store of the source (sh tests/stores.sh write)" >&2
        status=1
    fi
done
exit $status
