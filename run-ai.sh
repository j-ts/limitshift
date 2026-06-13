#!/usr/bin/env bash
# DEPRECATED forwarder. run-ai.sh was renamed to limitshift.sh.
# This stub forwards all arguments to limitshift.sh and preserves its exit code.
# It will be removed in the next release — use limitshift.sh directly.
echo "run-ai.sh is deprecated; use limitshift.sh" >&2
exec "$(dirname "$0")/limitshift.sh" "$@"
