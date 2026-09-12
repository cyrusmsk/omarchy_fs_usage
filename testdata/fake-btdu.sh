#!/bin/sh
# Test double for btdu (see README): replays a canned JSON export so the
# whole scan pipeline (worker, polling, parse, render) runs without root.
# The fixture is chosen by the advanced flags the app passes:
#   -x / --expert          -> expert.json (exclusive/shared metrics)
#   --export-seen-as       -> expert-seenas.json (+ seenAs shared paths)
#   otherwise              -> basic.json
# Usage: FSU_FAKE_BTDU=$PWD/testdata/fake-btdu.sh ./omarchy_fs_usage
out=""
prev=""
expert=0
seen=0
for a in "$@"; do
	case "$prev" in
		-o) out="$a" ;;
	esac
	case "$a" in
		-o) prev="-o" ;;
		--export=*) out="${a#--export=}"; prev="" ;;
		-x|--expert) expert=1; prev="" ;;
		--export-seen-as) seen=1; prev="" ;;
		*) prev="" ;;
	esac
done
if [ -z "$out" ]; then
	echo "fake-btdu: no export path in args: $*" >&2
	exit 2
fi
sleep 1
base=$(dirname "$0")
if [ "$seen" = 1 ]; then
	cp "$base/expert-seenas.json" "$out"
elif [ "$expert" = 1 ]; then
	cp "$base/expert.json" "$out"
else
	cp "$base/basic.json" "$out"
fi
echo "fake btdu: sampled 200000 points, wrote $out"
