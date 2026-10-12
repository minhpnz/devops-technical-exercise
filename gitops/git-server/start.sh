#!/bin/sh
# The repository lives in an emptyDir: this server is a relay, not the source of
# truth. If the pod restarts it comes back empty and `make gitops-push` reseeds
# it; Flux keeps serving its last fetched revision in the meantime.
set -eu
repo=/srv/git/greeter.git
if [ ! -d "$repo" ]; then
  git init -q --bare -b main "$repo"
  # allow anonymous push over HTTP (local exercise only)
  git -C "$repo" config http.receivepack true
fi
exec lighttpd -D -f /etc/lighttpd/git.conf
