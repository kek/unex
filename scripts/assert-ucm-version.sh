#!/usr/bin/env bash
# Assert that every UCM version in play agrees with .ucm-version.
#
# Why this script exists: the UCM release number necessarily appears in more
# than one place. Docker cannot read a file to resolve an ARG default, and a
# GitHub Actions `run:` block needs the number to build a download URL. That
# duplication once produced a three-way straddle -- the Dockerfile pinned
# 1.2.0, CI installed 1.1.1, and the developer's machine ran 1.3.0 -- with
# nothing anywhere comparing them.
#
# It matters because a compiled Unison bundle (.uc) refuses to run on a UCM
# other than the one that built it: "I can't run this compiled program since it
# works with a different version of Unison than the one you're running." The
# symptom is not a version warning, it is a ten-second accept timeout per
# dispatcher pool worker followed by :dispatcher_not_started on every service
# call. So "works in dev" must not be able to mean anything different from
# "works in CI" or "works in production".
#
# .ucm-version is the single authority. This script turns any disagreement with
# it into a loud failure at build time.
#
# Usage:
#   scripts/assert-ucm-version.sh                      # binary on PATH vs file
#   scripts/assert-ucm-version.sh 1.3.0                # also check a declared value (Docker ARG)
#   scripts/assert-ucm-version.sh --bundle path.uc     # also check a compiled bundle's header
#
# Checks, any of which fails the run:
#   1. a declared version (argument) differs from .ucm-version
#   2. the `ucm` binary on PATH reports a different release than .ucm-version
#   3. --bundle's embedded version differs from .ucm-version
set -euo pipefail

bundle=""
declared=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) bundle="${2:?--bundle needs a path}"; shift 2 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) declared="$1"; shift ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
pin_file="$script_dir/../.ucm-version"

if [ ! -f "$pin_file" ]; then
  echo "UCM VERSION STRADDLE: .ucm-version not found (looked in $pin_file)" >&2
  exit 1
fi

pinned="$(tr -d '[:space:]' < "$pin_file")"

if [ -z "$pinned" ]; then
  echo "UCM VERSION STRADDLE: .ucm-version is empty" >&2
  exit 1
fi

# Pull a bare X.Y.Z out of whatever form a version arrives in.
release_number() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

fail=0

# --- 1. A declared version (e.g. the Dockerfile's ARG default) --------------
if [ -n "$declared" ]; then
  declared_number="$(release_number "$declared")"
  if [ "$declared_number" != "$pinned" ]; then
    echo "UCM VERSION STRADDLE: declared version '$declared' != .ucm-version '$pinned'" >&2
    echo "  .ucm-version is authoritative. Update the declaration to match it." >&2
    fail=1
  fi
fi

# --- 2. The binary that will actually build and run the bundle --------------
if command -v ucm >/dev/null 2>&1; then
  installed_raw="$(ucm --version 2>&1 || true)"
  installed="$(release_number "$installed_raw")"
  if [ -z "$installed" ]; then
    echo "UCM VERSION STRADDLE: could not parse a version out of \`ucm --version\`: $installed_raw" >&2
    fail=1
  elif [ "$installed" != "$pinned" ]; then
    echo "UCM VERSION STRADDLE: installed ucm is $installed but .ucm-version pins $pinned" >&2
    echo "  A .uc bundle built by one refuses to run on the other." >&2
    fail=1
  fi
else
  echo "UCM VERSION STRADDLE: no \`ucm\` on PATH to check against .ucm-version ($pinned)" >&2
  fail=1
fi

# --- 3. A compiled bundle's own header -------------------------------------
# A .uc file starts with a big-endian u32 length followed by that many bytes of
# version text, so the release number is a printable string in the first bytes.
# This is the invariant that actually bites at runtime, checked against the
# artefact rather than against another copy of the number.
if [ -n "$bundle" ]; then
  if [ ! -f "$bundle" ]; then
    echo "UCM VERSION STRADDLE: --bundle $bundle does not exist" >&2
    fail=1
  else
    bundle_raw="$(head -c 256 "$bundle" | LC_ALL=C grep -oaE 'release/[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    bundle_number="$(release_number "${bundle_raw:-}")"
    if [ -z "$bundle_number" ]; then
      echo "UCM VERSION STRADDLE: could not read a UCM version out of $bundle" >&2
      fail=1
    elif [ "$bundle_number" != "$pinned" ]; then
      echo "UCM VERSION STRADDLE: $bundle was built by UCM $bundle_number but .ucm-version pins $pinned" >&2
      echo "  This bundle would fail at run.compiled with a different-version error." >&2
      fail=1
    fi
  fi
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "UCM version OK: everything in play agrees on $pinned"
