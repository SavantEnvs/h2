#!/usr/bin/env bash
#
# h2/mayhem/build.sh — build upstream's own cargo-fuzz targets (fuzz/fuzz_targets/*.rs, package
# h2-oss-fuzz: fuzz_client, fuzz_hpack, fuzz_e2e) as sanitized libFuzzer binaries, then precompile
# the crate's own `cargo test` suite for mayhem/test.sh to run.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. This first
# (online) build populates the cargo registry under $CARGO_HOME (pinned, $HOME-independent —
# see the Dockerfile). Do NOT pass --offline here; the rlenv runtime exports
# CARGO_NET_OFFLINE=true for the re-run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Upstream ships its own fuzz/ crate (3 targets: fuzz_client, fuzz_hpack, fuzz_e2e) — the actual
# OSS-Fuzz integration (h2-oss-fuzz). It builds cleanly under nightly as-is, so use it directly;
# nothing additive needed here.
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# ASan on by default; an explicitly EMPTY $SANITIZER_FLAGS disables it (build contract parity —
# $SANITIZER_FLAGS itself is a set of clang flags rustc can't consume directly, so translate its
# on/off intent instead of passing it through verbatim).
RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""
# DWARF <= 3 debug info for triage (SPEC §6.2 item 10) — threaded via RUST_DEBUG_FLAGS.
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers"
# libfuzzer-sys's build.rs, by default, compiles libFuzzer's own C++ sources from source via the
# `cc` crate at build time — that build ignores CFLAGS/CXXFLAGS (cc::Build's own flags win) and
# links in DWARF-5 CUs from the base image's clang, which -Zdwarf-version=3 (a rustc-only flag)
# never touches. Point it at the base's prebuilt libFuzzer runtime instead (the same one the C/C++
# side gets via $LIB_FUZZING_ENGINE) — it ships with NO debug info at all, so it contributes zero
# DWARF-5 CUs, and libfuzzer-sys skips its own from-source compile entirely.
export CUSTOM_LIBFUZZER_PATH=/usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.fuzzer-x86_64.a

# rustc's prebuilt sanitizer runtimes (compiler-rt) ship DWARF-5 CUs — strip their debug info
# BEFORE linking, not after: the linker COPIES the relevant debug sections into the final binary
# at link time, so stripping the source .a afterward does nothing for a binary already linked
# against it. Idempotent: stripping an already-stripped archive is a no-op.
find "$RUSTUP_HOME"/toolchains/*/lib/rustlib/"$TRIPLE"/lib \
  -name 'librustc-*_rt.*.a' -exec objcopy --strip-debug {} \; 2>/dev/null || true

echo "=== cargo fuzz build (image default nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
for t in "${FUZZ_TARGETS[@]}"; do ls -la "/mayhem/$t"; done

echo "=== precompile the crate's own test suite (hermetic, normal non-sanitized flags) ==="
RUSTFLAGS="" cargo test --lib --no-run --no-fail-fast --jobs "$MAYHEM_JOBS"
