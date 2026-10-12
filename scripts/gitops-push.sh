#!/usr/bin/env bash
# Pushes this repository's committed HEAD to main on the in-cluster git server
# (force: the in-cluster repo is a relay of this one, never edited in place
# except by drill-gitops.sh, whose commits this deliberately overwrites).
# Uncommitted changes are not deployed - that's the point.
set -u
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
git_forward_start || exit 1
trap git_forward_stop EXIT
git push --force --quiet "$GIT_URL" HEAD:refs/heads/main || exit 1
echo "pushed $(git rev-parse --short HEAD) to in-cluster main"
flux_poke
