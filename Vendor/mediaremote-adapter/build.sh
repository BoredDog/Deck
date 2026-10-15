#!/bin/zsh
# Builds MediaRemoteAdapter.framework (BSD-3, ungive/mediaremote-adapter, commit in UPSTREAM_COMMIT)
# into Vendor/mediaremote-adapter/build/. Deck runs it via /usr/bin/perl bin/mediaremote-adapter.pl.
# Needs cmake (brew install cmake). No network.
set -euo pipefail
cd "$(dirname "$0")"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build --target MediaRemoteAdapter >/dev/null
echo "Built $(pwd)/build/MediaRemoteAdapter.framework"
