#!/bin/sh
# Two-process checks for ecallean. Each case runs a subscriber and a publisher as separate
# processes. The two control cases must FAIL; the script fails if either passes.
set -u
cd "$(dirname "$0")/.."
BIN=.lake/build/bin/ecallean
N=${N:-5000}
FRAMES=${FRAMES:-300}
status=0

pair() { # sub-mode pub-mode n [pub args...]
	smode=$1; pmode=$2; n=$3; shift 3
	$BIN "$smode" "$n" & spid=$!
	$BIN "$pmode" "$n" "$@" & ppid=$!
	# A hung pair is a failure, not a wait: kill both after 120 s.
	( sleep 120; kill $spid $ppid 2>/dev/null ) & dog=$!
	wait $ppid; pst=$?
	wait $spid; sst=$?
	kill $dog 2>/dev/null
	[ $pst -eq 0 ] && [ $sst -eq 0 ]
}

echo "== eCAL $($BIN version)"
echo "== messages: $N, sizes 16..60015 bytes, written and read in place"
if pair sub pub "$N"; then echo "PASS messages"; else echo "FAIL messages"; status=1; fi

echo "== control: message 777 never sent; the subscriber must fail"
if pair sub pub "$N" --skip 777 2>&1; then echo "FAIL control passed: a lost message goes unseen"; status=1
else echo "PASS control failed as it must"; fi

echo "== control: message 777 changed after its checksum; the subscriber must fail"
if pair sub pub "$N" --corrupt 777 2>&1; then echo "FAIL control passed: a changed message goes unseen"; status=1
else echo "PASS control failed as it must"; fi

echo "== frames: $FRAMES of 3840x2160 RGBA, one message each"
out=$(pair fsub fpub "$FRAMES" 2>&1); fst=$?
echo "$out"
sub_fnv=$(echo "$out" | sed -n 's/^OK fsub.*last frame fnv //p')
pub_fnv=$(echo "$out" | sed -n 's/^OK fpub.*last frame fnv //p')
if [ $fst -eq 0 ] && [ -n "$sub_fnv" ] && [ "$sub_fnv" = "$pub_fnv" ]; then echo "PASS frames (last frame identical: $sub_fnv)"
else echo "FAIL frames"; status=1; fi

echo "== baseline: the same frames through a pipe (what Godot to interactor-cineform uses today)"
if cc -O2 -o .lake/pipe4k tests/pipe4k.c 2>/dev/null; then .lake/pipe4k w "$FRAMES" | .lake/pipe4k r "$FRAMES"; fi

exit $status
