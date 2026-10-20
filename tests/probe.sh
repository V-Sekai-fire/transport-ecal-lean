#!/bin/sh
# One sub/pub pair per registration kind, 50 messages, killed after 40 s if it hangs.
cd "$(dirname "$0")/.."
for reg in shm udp; do
	echo "== registration $reg"
	ECALLEAN_REGISTRATION=$reg .lake/build/bin/ecallean sub 50 & sp=$!
	ECALLEAN_REGISTRATION=$reg .lake/build/bin/ecallean pub 50 & pp=$!
	( sleep 40; kill $sp $pp 2>/dev/null ) & dog=$!
	wait $pp; echo "pub exit $?"
	wait $sp; echo "sub exit $?"
	kill $dog 2>/dev/null
done 2>&1 | grep -v yaml
