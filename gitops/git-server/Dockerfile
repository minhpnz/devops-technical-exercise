# In-cluster git server for the GitOps extension: git's own smart-HTTP CGI
# behind lighttpd. Local-only - no auth, anyone who can reach it can push.
FROM alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
# Pinned to upstream version, not package release (-rN): Alpine replaces -r0
# with -r1 in place on a rebuild, and an exact pin would then stop building.
# The base digest fixes the repository snapshot this was tested against.
RUN apk add --no-cache git~2.52 git-daemon~2.52 lighttpd~1.4.85
COPY lighttpd.conf /etc/lighttpd/git.conf
COPY start.sh /start.sh
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/start.sh"]
