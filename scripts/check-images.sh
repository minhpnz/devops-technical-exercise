#!/usr/bin/env bash
# Every image `make up` pulls must be pinned by digest and must exist for both
# linux/amd64 and linux/arm64 - a reviewer on Apple silicon pulls the arm64
# half of each index. The list is extracted from the files that use the
# images, not maintained by hand.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
list=$(mktemp)

{
  awk '/^FROM/ {for (i=2;i<=NF;i++) if ($i ~ /@sha256:/) print $i}' Dockerfile
  awk '/image: / {print $2}' kind/cluster.yaml
  # tooling images pinned in the Makefile (promtool)
  grep -hoE '[a-z0-9./_-]+(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}' Makefile
} | sort -u > "$list"

fail=0
while read -r ref; do
  case "$ref" in *@sha256:*) ;; *) echo "FAIL not digest-pinned: $ref"; fail=1; continue;; esac
  plats=$(docker buildx imagetools inspect "$ref" 2>/dev/null | awk '/Platform:/ {print $2}')
  missing=""
  for p in linux/amd64 linux/arm64; do
    echo "$plats" | grep -q "^$p" || missing="$missing $p"
  done
  if [ -n "$missing" ]; then echo "FAIL $ref missing:$missing"; fail=1; else echo "ok   $ref"; fi
done < "$list"
rm -f "$list"
exit "$fail"
