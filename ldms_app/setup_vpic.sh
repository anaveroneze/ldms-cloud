#!/usr/bin/env bash
# Build VPIC and compile the benchmark deck. Runs on the compute node,
# dispatched by build_vpic.sh.
#
# No 'set -e': every step that matters is checked explicitly so the failing
# stage is named in the SSM output.
#
# Usage: setup_vpic.sh [--deck-only]
#   --deck-only  re-patch and recompile just the input deck (~30 s), skipping
#                the library build. Needed because num_step is baked into the
#                deck at COMPILE time, so changing the run length is a recompile.

export DEBIAN_FRONTEND=noninteractive

DECK_ONLY=false
[ "${1:-}" = "--deck-only" ] && DECK_ONLY=true

# Deck parameters. Defaults give ~6.55 M macroparticles (~0.7 GB) on a 2D grid.
NX="${NX:-256}"
NY="${NY:-256}"
NZ="${NZ:-1}"
NPPC="${NPPC:-100}"
NUM_STEP="${NUM_STEP:-200}"

VPIC_DIR="$HOME/vpic"
DECK="$HOME/harris_bench.cxx"

echo "=== VPIC setup (deck-only: $DECK_ONLY) ==="
echo "nx=$NX ny=$NY nz=$NZ nppc=$NPPC num_step=$NUM_STEP"

if ! $DECK_ONLY; then
  # 1. Build dependencies.
  #    Use apt's cmake (3.22 on 22.04). Do NOT install cmake from pip/snap/Kitware:
  #    VPIC declares cmake_minimum_required(VERSION 3.1) and CMake 4.x removed
  #    compatibility with < 3.5, which hard-fails configure.
  sudo apt-get update && sudo apt-get install -y \
    build-essential cmake git libopenmpi-dev openmpi-bin
  [ $? -eq 0 ] || { echo "ERROR: apt-get install failed"; exit 1; }

  # 2. Clone and build the VPIC library.
  #    Using lanl/vpic (the legacy version): its only dependencies are a C++11
  #    compiler and MPI. The Kokkos version (lanl/vpic-kokkos) needs Kokkos and
  #    has a documented OpenMP deck-linking bug.
  #    The 'devel' branch auto-enables -fno-strict-aliasing for GCC; it is passed
  #    explicitly below anyway, because the deck compile needs it too.
  [ -d "$VPIC_DIR" ] || git clone https://github.com/lanl/vpic.git "$VPIC_DIR"
  cd "$VPIC_DIR" || { echo "ERROR: cannot enter $VPIC_DIR"; exit 1; }
  git checkout devel
  mkdir -p build && cd build

  # Two non-obvious flag choices:
  #  -O3 must be in CMAKE_CXX_FLAGS, not left to CMAKE_BUILD_TYPE=Release. VPIC's
  #  CMakeLists appends only the Debug and RelWithDebInfo flag sets to the flags
  #  used to compile the input deck, never CMAKE_CXX_FLAGS_RELEASE, so a plain
  #  Release build would compile the deck at -O0.
  #  USE_V4_SSE is the only vector option safe without -march: v4_sse.h uses
  #  baseline SSE1/SSE2 intrinsics, and the build system adds no -march anywhere.
  cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_PTHREADS=ON \
    -DUSE_V4_SSE=ON \
    -DCMAKE_C_FLAGS="-O3 -rdynamic -fno-strict-aliasing" \
    -DCMAKE_CXX_FLAGS="-O3 -rdynamic -fno-strict-aliasing" \
    .. || { echo "ERROR: cmake configure failed"; exit 1; }

  make -j"$(nproc)" || { echo "ERROR: VPIC library build failed"; exit 1; }
  [ -x "$VPIC_DIR/build/bin/vpic" ] || { echo "ERROR: bin/vpic was not generated"; exit 1; }
fi

# 3. Patch the harris deck.
#    VPIC input decks are C++ that gets #include'd into deck/main.cc, not config
#    files, so the parameters are edited in source and compiled in. Three edits:
#      - scale the grid and particles-per-cell to fill the instance
#      - pin num_step to a literal (the deck derives it from the physics, which
#        gives ~484 steps -> a few seconds of work)
#      - zero every binary dump interval. Unmodified, this deck writes ~1 GB per
#        run and the benchmark would measure EBS instead of VPIC. The deck's own
#        should_dump() guard tests 'interval > 0', so 0 disables cleanly.
#    energies_interval is deliberately left alone: it is rank-0 text only and is
#    a cheap correctness signal.
cp "$VPIC_DIR/sample/harris" "$DECK" || { echo "ERROR: sample/harris not found"; exit 1; }

sed -i -E \
  -e "s/(double nx[[:space:]]*=[[:space:]]*)[0-9.]+/\1${NX}/" \
  -e "s/(double ny[[:space:]]*=[[:space:]]*)[0-9.]+/\1${NY}/" \
  -e "s/(double nz[[:space:]]*=[[:space:]]*)[0-9.]+/\1${NZ}/" \
  -e "s/(double nppc[[:space:]]*=[[:space:]]*)[0-9.]+/\1${NPPC}/" \
  -e "s|num_step[[:space:]]*=[[:space:]]*int\(0\.2\*taui/\(wci\*dt\)\);|num_step = ${NUM_STEP};|" \
  -e "s/(global->(fields|ehydro|ihydro|eparticle|iparticle|restart)_interval[[:space:]]*=[[:space:]]*)[^;]+;/\10;/" \
  "$DECK"

# Verify every substitution. A silently unpatched deck would run the wrong
# benchmark and fill the disk, so fail loudly instead.
check() {
  grep -qE "$1" "$DECK" || { echo "ERROR: deck patch failed for $2"; exit 1; }
}
check "double nx[[:space:]]*=[[:space:]]*${NX}[^0-9.]"     "nx"
check "double ny[[:space:]]*=[[:space:]]*${NY}[^0-9.]"     "ny"
check "double nz[[:space:]]*=[[:space:]]*${NZ}[^0-9.]"     "nz"
check "double nppc[[:space:]]*=[[:space:]]*${NPPC}[^0-9.]" "nppc"
check "num_step = ${NUM_STEP};"                            "num_step"

N_ZEROED=$(grep -cE 'global->(fields|ehydro|ihydro|eparticle|iparticle|restart)_interval[[:space:]]*=[[:space:]]*0;' "$DECK")
[ "$N_ZEROED" -eq 6 ] || {
  echo "ERROR: expected 6 zeroed dump intervals, found $N_ZEROED"
  grep -n '_interval' "$DECK"
  exit 1
}
echo "Deck patched and verified: $DECK"

# 4. Compile the deck.
#    bin/vpic is a generated shell script, not a compiler driver: it strips the
#    .cxx suffix and writes <name>.Linux into the CURRENT directory. It also bakes
#    -Wl,-rpath,<build-dir> and the source dir into the command, so ~/vpic and
#    ~/vpic/build must not be moved or deleted after a deck is compiled.
cd "$VPIC_DIR/build" || exit 1
./bin/vpic "$DECK" || { echo "ERROR: deck compile failed"; exit 1; }
[ -x "$VPIC_DIR/build/harris_bench.Linux" ] || { echo "ERROR: harris_bench.Linux was not produced"; exit 1; }

echo
echo "=== Done ==="
ls -l "$VPIC_DIR/build/harris_bench.Linux"
mpirun --version | head -1
