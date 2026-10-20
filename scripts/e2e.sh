#!/bin/bash
# Gate 3, the cancho-mqtt half (design section 9): the example programs against a real broker.
#
#   BROKER=/path/to/mqtt CANCHO=/path/to/cancho scripts/e2e.sh [port]
#
# `sub` subscribes to plant/#; `pub` publishes two messages under plant/ and one elsewhere; `sub` must print the two and exit 0, and the
# broker must have logged no refusal.
set -u
here=$(cd "$(dirname "${0}")/.." && pwd)
BROKER=${BROKER:?BROKER is the mqtt binary}
CANCHO=${CANCHO:-cancho}
port=${1:-18830}
cd "$here"
"$CANCHO" build >/dev/null || { echo "FAIL build"; exit 1; }
log=$(mktemp); out=$(mktemp)
"$BROKER" serve --port "$port" >"$log" 2>&1 &
broker=$!
trap 'kill $broker 2>/dev/null; rm -f "$log" "$out"' EXIT
for i in $(seq 1 50); do grep -q listening "$log" && break; sleep 0.1; done
fail=0
timeout 20 build/sub 127.0.0.1 "$port" 'plant/#' 2 >"$out" 2>&1 &
sub=$!
sleep 0.5
build/pub 127.0.0.1 "$port" other/topic ignored || { echo "FAIL pub 1 exit $?"; fail=1; }
build/pub 127.0.0.1 "$port" plant/line1/temp 21.5 || { echo "FAIL pub 2 exit $?"; fail=1; }
build/pub 127.0.0.1 "$port" plant/line2/temp 19 || { echo "FAIL pub 3 exit $?"; fail=1; }
wait $sub; code=$?
[ "$code" = 0 ] || { echo "FAIL sub exit $code"; fail=1; }
printf 'plant/line1/temp 21.5\nplant/line2/temp 19\n' | diff - "$out" >/dev/null || { echo "FAIL sub printed:"; cat "$out"; fail=1; }
refusals=$(grep -c '"type":"refusal"' "$log")
[ "$refusals" = 0 ] || { echo "FAIL the broker logged $refusals refusals"; fail=1; }
[ "$fail" = 0 ] && echo "e2e: ok (two messages through the broker, none refused)"
exit $fail
