#!/usr/bin/env bash
# Build OVIS/LDMS from source. Runs on every node, dispatched by start_cluster.sh.
# No 'set -e': autogen.sh returns a benign non-zero.
export DEBIAN_FRONTEND=noninteractive

# 1. Install dependencies
# sudo's env_reset drops DEBIAN_FRONTEND, so it has to be set on the sudo line
# itself, otherwise debconf noisily falls back through its frontends.
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  autoconf pkg-config hdf5-tools libhdf5-openmpi-dev openmpi-bin python3.10 \
  python-dev-is-python3 make bison flex python3-docutils libjansson-dev git \
  build-essential awscli

# 2. Clone and build OVIS/LDMS
[ -d "$HOME/ovis" ] || git clone https://github.com/ovis-hpc/ovis.git "$HOME/ovis"
cd "$HOME/ovis" && ./autogen.sh
mkdir -p build && cd build
../configure --prefix="$PWD"
make -j"$(nproc)"
make install

# 3. Write the environment file (for interactive use; sourced from .bashrc)
cat > "$HOME/set-ldms-env.sh" <<'EOENV'
export LDMS_INSTALL_PATH="$HOME/ovis/build"
export PATH="$LDMS_INSTALL_PATH/sbin:$LDMS_INSTALL_PATH/bin:$PATH"
export LD_LIBRARY_PATH="$LDMS_INSTALL_PATH/lib:${LD_LIBRARY_PATH:-}"
export LDMSD_PLUGIN_LIBPATH="$LDMS_INSTALL_PATH/lib/ovis-ldms"
export ZAP_LIBPATH="$LDMS_INSTALL_PATH/lib/ovis-ldms"
EOENV

# 4. Source it from .bashrc and verify the build
grep -qxF 'source ~/set-ldms-env.sh' "$HOME/.bashrc" || echo 'source ~/set-ldms-env.sh' >> "$HOME/.bashrc"
source "$HOME/set-ldms-env.sh" && which ldmsd

# 5. Confirm the three sampler plugins this experiment needs were built
echo "=== Sampler plugins available ==="
ls "$HOME/ovis/build/lib/ovis-ldms/" | grep -E 'meminfo|vmstat|procstat' || \
  echo "WARNING: one or more of meminfo/vmstat/procstat is missing"
