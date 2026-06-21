#!/usr/bin/env bash
# Run the host-free agtermCore unit tests (no Xcode, no libghostty, no Metal).
set -euo pipefail
cd "$(dirname "$0")/../agtermCore"
swift test
