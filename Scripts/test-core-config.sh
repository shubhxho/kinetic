#!/usr/bin/env bash
# Regression: kinetic-core-bench config precedence and invalid values.
#
# Flags beat environment variables, which beat compiled defaults.
# Invalid --seconds exits 2. Invalid KINETIC_BENCH_SECONDS is ignored.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/.build/kinetic-core-bench"

if [[ ! -x "$bin" ]]; then
  "$root/Scripts/bench-core.sh" --config >/dev/null
fi

pass=0
fail=0

check() {
  local name="$1"
  local expect_exit="$2"
  local grep_pat="$3"
  shift 3
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expect_exit" ]]; then
    echo "FAIL  $name  exit $rc (want $expect_exit)"
    echo "$out"
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$grep_pat" ]] && ! grep -Eq -- "$grep_pat" <<<"$out"; then
    echo "FAIL  $name  missing /$grep_pat/"
    echo "$out"
    fail=$((fail + 1))
    return
  fi
  echo "PASS  $name"
  pass=$((pass + 1))
}

# Isolate from the caller environment.
run() {
  env -u KINETIC_SERIAL -u KINETIC_BENCH_SECONDS -u KINETIC_DURATION \
     -u KINETIC_PORT -u KINETIC_RATE "$@"
}

echo "KineticCore config regressions"
echo

check "defaults" 0 \
  'seconds[[:space:]]+1\.0[[:space:]]+default' \
  run "$bin" --config

check "env seconds and serial" 0 \
  'seconds[[:space:]]+2\.0[[:space:]]+KINETIC_BENCH_SECONDS' \
  env -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_SERIAL=1 KINETIC_BENCH_SECONDS=2 "$bin" --config

check "empty KINETIC_SERIAL is present" 0 \
  'serial[[:space:]]+on[[:space:]]+KINETIC_SERIAL' \
  env -u KINETIC_BENCH_SECONDS -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_SERIAL= "$bin" --config

check "flag beats env seconds" 0 \
  'seconds[[:space:]]+3\.0[[:space:]]+--seconds' \
  env -u KINETIC_SERIAL -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_BENCH_SECONDS=9 "$bin" --config --seconds 3

check "flag serial beats default with env seconds" 0 \
  'serial[[:space:]]+on[[:space:]]+--serial' \
  env -u KINETIC_SERIAL -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_BENCH_SECONDS=2 "$bin" --config --serial

check "invalid env seconds ignored" 0 \
  'seconds[[:space:]]+1\.0[[:space:]]+default' \
  env -u KINETIC_SERIAL -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_BENCH_SECONDS=abc "$bin" --config

check "zero env seconds ignored" 0 \
  'seconds[[:space:]]+1\.0[[:space:]]+default' \
  env -u KINETIC_SERIAL -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_BENCH_SECONDS=0 "$bin" --config

check "negative env seconds ignored" 0 \
  'seconds[[:space:]]+1\.0[[:space:]]+default' \
  env -u KINETIC_SERIAL -u KINETIC_DURATION -u KINETIC_PORT -u KINETIC_RATE \
      KINETIC_BENCH_SECONDS=-1 "$bin" --config

check "invalid --seconds exits 2" 2 \
  'invalid --seconds' \
  run "$bin" --seconds 0 --config

check "negative --seconds exits 2" 2 \
  'invalid --seconds' \
  run "$bin" --seconds -1 --config

check "non-numeric --seconds exits 2" 2 \
  'invalid --seconds' \
  run "$bin" --seconds abc --config

check "missing --seconds value exits 2" 2 \
  '--seconds needs a positive number' \
  run "$bin" --seconds --config

check "unknown flag exits 2" 2 \
  'unknown flag: --bogus' \
  run "$bin" --bogus

check "--config does not run scenes" 0 \
  'kinetic-core-bench configuration' \
  run "$bin" --config --check

if grep -q 'all checks passed' <<<"$(run "$bin" --config --check 2>&1)"; then
  echo "FAIL  --config --check must dump knobs, not run --check"
  fail=$((fail + 1))
else
  echo "PASS  --config --check dumps without running scenes"
  pass=$((pass + 1))
fi

echo
if [[ "$fail" -ne 0 ]]; then
  echo "$fail failed, $pass passed"
  exit 1
fi
echo "all config checks passed ($pass)"
