#!/usr/bin/env bash
# Fail if any tracked file names a private host, network or estate path.
set -euo pipefail
pattern='thesim\.family|hyperion-[0-9]|sphinx-[0-9]|mac-mini|lamia|consul|bucky|192\.168\.|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.|~/Workspace|/home/jaryl|/Users/jaryl|homelab-ops|Bartley Ridge|\bCove\b'
if git ls-files -z | grep -zv '^scripts/scrub-check.sh$' | xargs -0 -r grep -n -I -E "$pattern"; then
  echo "::error::private names or addresses found (see above)"
  exit 1
fi
echo "scrub check: clean"
