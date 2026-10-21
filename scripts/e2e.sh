#!/bin/bash
# Gate 3, the cancho-mqtt half (design section 9): the example programs against a real broker.
#
#   BROKER=/path/to/mqtt CANCHO=/path/to/cancho scripts/e2e.sh [port]
#
# `sub` subscribes to plant/#; `pub` publishes three messages under plant/ (two at QoS 0, one at QoS 1, which waits for the broker's PUBACK)
# and one elsewhere; `sub` must print the three and exit 0, and the broker must have logged no refusal. Then slice 4: a retained message
# reaches a late subscriber marked retained and a live one unmarked, an empty retained message clears it, a will is published when the
# socket drops without DISCONNECT (and kept when retained) and is not published after DISCONNECT. Then slice 5: `watch` outlives its broker.
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
timeout 20 build/sub 127.0.0.1 "$port" 'plant/#' 3 >"$out" 2>&1 &
sub=$!
sleep 0.5
build/pub 127.0.0.1 "$port" other/topic ignored || { echo "FAIL pub 1 exit $?"; fail=1; }
build/pub 127.0.0.1 "$port" plant/line1/temp 21.5 || { echo "FAIL pub 2 exit $?"; fail=1; }
build/pub 127.0.0.1 "$port" plant/line2/temp 19 || { echo "FAIL pub 3 exit $?"; fail=1; }
build/pub 127.0.0.1 "$port" plant/line3/temp 7 acked 1 || { echo "FAIL pub 4 (QoS 1) exit $?"; fail=1; }
wait $sub; code=$?
[ "$code" = 0 ] || { echo "FAIL sub exit $code"; fail=1; }
printf 'plant/line1/temp 21.5\nplant/line2/temp 19\nplant/line3/temp 7\n' | diff - "$out" >/dev/null || { echo "FAIL sub printed:"; cat "$out"; fail=1; }
# Retained: a live subscriber sees the message unmarked; a late one sees it marked.
timeout 20 build/sub 127.0.0.1 "$port" 'ret/#' 1 >"$out" 2>&1 &
sub=$!
sleep 0.5
build/pub 127.0.0.1 "$port" ret/temp 5 pub 0 1 || { echo "FAIL pub retained exit $?"; fail=1; }
wait $sub
[ "$(cat "$out")" = "ret/temp 5" ] || { echo "FAIL live subscriber saw: $(cat "$out")"; fail=1; }
timeout 10 build/sub 127.0.0.1 "$port" 'ret/#' 1 >"$out" 2>&1 || { echo "FAIL late sub exit $?"; fail=1; }
[ "$(cat "$out")" = "ret/temp 5 [retained]" ] || { echo "FAIL late subscriber saw: $(cat "$out")"; fail=1; }
# An empty retained payload clears it: a later subscriber gets nothing (the timeout ends it).
build/pub 127.0.0.1 "$port" ret/temp '' pub 0 1 || { echo "FAIL pub clear exit $?"; fail=1; }
timeout 2 build/sub 127.0.0.1 "$port" 'ret/#' 1 >"$out" 2>&1
[ "$?" = 124 ] && [ ! -s "$out" ] || { echo "FAIL a cleared retained message still arrived: $(cat "$out")"; fail=1; }
# Will: dropped socket publishes it; DISCONNECT does not; a retained will is kept for a late subscriber.
timeout 20 build/sub 127.0.0.1 "$port" 'will/#' 1 >"$out" 2>&1 &
sub=$!
sleep 0.5
build/will 127.0.0.1 "$port" will/line1 offline 0 drop || { echo "FAIL will drop exit $?"; fail=1; }
wait $sub
[ "$(cat "$out")" = "will/line1 offline" ] || { echo "FAIL the will was not published: $(cat "$out")"; fail=1; }
timeout 3 build/sub 127.0.0.1 "$port" 'will/#' 1 >"$out" 2>&1 &
sub=$!
sleep 0.5
build/will 127.0.0.1 "$port" will/line2 offline 0 bye || { echo "FAIL will bye exit $?"; fail=1; }
wait $sub
[ ! -s "$out" ] || { echo "FAIL a will was published after DISCONNECT: $(cat "$out")"; fail=1; }
build/will 127.0.0.1 "$port" will/line3 offline 1 drop || { echo "FAIL will retained exit $?"; fail=1; }
sleep 0.5
timeout 10 build/sub 127.0.0.1 "$port" 'will/line3' 1 >"$out" 2>&1 || { echo "FAIL late sub of the will exit $?"; fail=1; }
[ "$(cat "$out")" = "will/line3 offline [retained]" ] || { echo "FAIL the retained will: $(cat "$out")"; fail=1; }
# Slice 5: a watcher started before its broker exists connects once there is one, and again after the broker is killed and started anew.
# Each message is retained, so it reaches the watcher whenever it is subscribed; the watcher exits by itself after two. (The program's output
# is block-buffered into a file, so it is read only after it exits.)
port2=$((port + 1))
wlog=$(mktemp); wout=$(mktemp)
timeout 60 build/watch 127.0.0.1 "$port2" 'wa/#' 2 200 1000 >"$wout" 2>&1 &
watcher=$!
sleep 1.2
"$BROKER" serve --port "$port2" >"$wlog" 2>&1 &
wbroker=$!
for i in $(seq 1 50); do grep -q listening "$wlog" && break; sleep 0.1; done
build/pub 127.0.0.1 "$port2" wa/one one pub 0 1 || { echo "FAIL pub wa/one exit $?"; fail=1; }
sleep 2.5
kill $wbroker 2>/dev/null; wait $wbroker 2>/dev/null
sleep 1.5
"$BROKER" serve --port "$port2" >>"$wlog" 2>&1 &
wbroker=$!
for i in $(seq 1 50); do [ "$(grep -c listening "$wlog")" = 2 ] && break; sleep 0.1; done
build/pub 127.0.0.1 "$port2" wa/two two pub 0 1 || { echo "FAIL pub wa/two exit $?"; fail=1; }
wait $watcher; code=$?
kill $wbroker 2>/dev/null; wait $wbroker 2>/dev/null
[ "$code" = 0 ] || { echo "FAIL watch exit $code"; fail=1; }
printf 'wa/one one [retained]\nwa/two two [retained]\n' | diff - "$wout" >/dev/null || { echo "FAIL the watcher printed: $(cat "$wout")"; fail=1; }
rm -f "$wlog" "$wout"
refusals=$(grep -c '"type":"refusal"' "$log")
[ "$refusals" = 0 ] || { echo "FAIL the broker logged $refusals refusals"; fail=1; }
[ "$fail" = 0 ] && echo "e2e: ok (three messages through the broker, one of them acknowledged at QoS 1; retained, cleared and will behave; a watcher outlives its broker; none refused)"
exit $fail
