#!/usr/bin/env bash
# Compile and run the documented C ABI resting-ball example.
# This is the Linux-runnable counterpart of docs/src/api/c.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/Tests/KineticCExample/resting-ball.c"
out="$root/.build/kinetic-c-example"
mkdir -p "$root/.build"

if [[ -z "${CXX:-}" ]]; then
  if command -v g++ >/dev/null 2>&1; then
    CXX=g++
  elif command -v clang++ >/dev/null 2>&1; then
    CXX=clang++
  else
    echo "run-c-example.sh: need g++ or clang++" >&2
    exit 1
  fi
fi

echo "compiling C ABI example with $CXX ..."
obj="$root/.build/kinetic-c-example-obj"
rm -rf "$obj"
mkdir -p "$obj"
(
  cd "$obj"
  "$CXX" -std=c++20 -O2 -DNDEBUG -pthread \
    -Wall -Wextra -Wno-unused-parameter \
    -I "$root/Sources/KineticCore/include" \
    -I "$root/Sources/KineticCore/src" \
    -c "$root"/Sources/KineticCore/src/*.cpp
  "$CXX" -x c -std=c11 -O2 -DNDEBUG \
    -Wall -Wextra -Wno-unused-parameter \
    -I "$root/Sources/KineticCore/include" \
    -c "$src" -o resting-ball.o
  "$CXX" -pthread ./*.o -o "$out"
)

echo "running $out"
output="$("$out")"
echo "$output"

height="$(printf '%s\n' "$output" | awk '/resting height:/ { print $3 }')"
python3 - "$height" <<'PY'
import sys
height = float(sys.argv[1])
# Speculative contacts rest on the surface. 0.2 m radius, dropped from 1 m.
if abs(height - 0.2) > 1e-5:
    print(f"FAIL  resting height {height:.9f} m, expected 0.200000 m", file=sys.stderr)
    sys.exit(1)
print("PASS  resting height")
PY
