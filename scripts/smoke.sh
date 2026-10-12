#!/usr/bin/env bash
# Hits each environment from the host and checks greeting + version.
set -u
fail=0
check() { # env port
  body=$(curl -fsS --max-time 5 "http://127.0.0.1:$2/") || { echo "FAIL $1: no response on :$2"; fail=1; return; }
  ver=$(curl -fsS --max-time 5 "http://127.0.0.1:$2/version")
  echo "ok   $1 :$2 version=$ver  $body"
}
check dev 30080
check prod 30081
exit "$fail"
