#!/usr/bin/env bash
#
# mayhem/test.sh — run the `h2` crate's own `cargo test --lib` suite (already precompiled by
# mayhem/build.sh with matching flags, so this re-invocation just RUNS — cargo recognizes the
# build is current and doesn't recompile). exit 0 = pass. Emits a CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# MUST match build.sh's precompile invocation exactly (RUSTFLAGS="" cargo test --lib --no-run
# --no-fail-fast) so cargo sees the build as current and only RUNS — no recompile here.
out="$(RUSTFLAGS="" cargo test --lib --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"
rc=$?
echo "$out"

# cargo test emits one "test result: ok|FAILED. P passed; F failed; ... " line per test binary
# (the `h2` crate has one lib test binary). Sum across all such lines in case of multiple.
passed=0; failed=0; skipped=0
while read -r p f s; do
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + s))
done < <(echo "$out" | grep -oE '[0-9]+ passed; [0-9]+ failed;.*[0-9]+ ignored' \
            | sed -E 's/([0-9]+) passed; ([0-9]+) failed;.*?([0-9]+) ignored/\1 \2 \3/')

if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "test.sh: could not parse any 'cargo test' result line — treating as a hard failure" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then
  # non-zero exit but we didn't see a failed-count in the parsed summary (e.g. build/panic before
  # any test ran) — don't silently report success.
  failed=1
fi

emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
