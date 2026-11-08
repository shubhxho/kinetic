#!/usr/bin/env bash
# Build KineticCore with g++ (or $CXX) and run the standalone benchmark.
#
# Usage:
#   ./Scripts/bench-core.sh                  # --check --seconds 1
#   ./Scripts/bench-core.sh --seconds 2
#   ./Scripts/bench-core.sh --serial --check
#   ./Scripts/bench-core.sh --json --check --seconds 1
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/.build/kinetic-core-bench"
mkdir -p "$root/.build"

if [[ -z "${CXX:-}" ]]; then
  if command -v g++ >/dev/null 2>&1; then
    CXX=g++
  elif command -v clang++ >/dev/null 2>&1; then
    CXX=clang++
  else
    echo "bench-core.sh: need g++ or clang++" >&2
    exit 1
  fi
fi

echo "compiling KineticCore with $CXX -O2 ..."
"$CXX" -std=c++20 -O2 -DNDEBUG -pthread \
  -Wall -Wextra -Wno-unused-parameter \
  -I "$root/Sources/KineticCore/include" \
  -I "$root/Sources/KineticCore/src" \
  "$root"/Sources/KineticCore/src/*.cpp \
  "$root/Tests/KineticCoreBench/bench.cpp" \
  -o "$out"

if [[ $# -eq 0 ]]; then
  set -- --check --seconds 1
fi

echo "running $out $*"
"$out" "$@"
