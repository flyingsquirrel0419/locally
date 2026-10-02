#!/bin/bash
# CI linux test runner with hang forensics. Runs `swift test` with
# line-buffered output (so the last started test is always visible in the
# log even when stdout is a pipe), and if the run exceeds a soft deadline,
# dumps a full-thread backtrace of the test process before failing.
# Permanent diagnostics, not a gate weakening: the step still fails on any
# test failure or hang.
set -u
cd "$(dirname "$0")/.."

SOFT_LIMIT_SECONDS="${CI_TEST_SOFT_LIMIT:-1200}"  # 20 min; suite takes ~3 min

apt-get update -qq && apt-get install -y --no-install-recommends gdb > /dev/null 2>&1 || true

rm -f test.log test.exit
( set -o pipefail
  stdbuf -oL -eL swift test -j 2 2>&1 | tee test.log
  echo "$?" > test.exit ) &
runner_pid=$!

# Wait up to the soft limit, then capture diagnostics.
waited=0
while kill -0 "$runner_pid" 2>/dev/null && [ "$waited" -lt "$SOFT_LIMIT_SECONDS" ]; do
  sleep 10
  waited=$((waited + 10))
done

if kill -0 "$runner_pid" 2>/dev/null; then
  echo "::error::swift test exceeded ${SOFT_LIMIT_SECONDS}s; capturing hang forensics"
  {
    echo "### Linux test hang forensics"
    echo '```'
    echo "Last test activity (line-buffered, so accurate):"
    grep -E "Test Case .* (started|passed|failed)" test.log | tail -5 || true
    echo
    echo "Process tree:"
    ps -ef --forest | grep -E "swift|xctest" | grep -v grep || true
    echo
    test_pid=$(pgrep -f "LocallyPackageTests.xctest" | head -1)
    if [ -n "$test_pid" ]; then
      echo "Full thread backtrace of test process (pid $test_pid):"
      gdb -p "$test_pid" -batch -ex "thread apply all bt" 2>&1 || true
    else
      echo "No LocallyPackageTests.xctest process found; dumping swift test driver:"
      driver_pid=$(pgrep -f "swift test" | head -1)
      [ -n "$driver_pid" ] && gdb -p "$driver_pid" -batch -ex "thread apply all bt" 2>&1 || true
    fi
    echo '```'
  } | tee /dev/stderr >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  pkill -9 -f "LocallyPackageTests.xctest" 2>/dev/null || true
  kill -9 "$runner_pid" 2>/dev/null || true
  exit 1
fi

wait "$runner_pid" 2>/dev/null || true
[ -f test.exit ] || { echo "::error::test.exit missing; runner died abnormally"; exit 1; }
exit "$(cat test.exit)"
