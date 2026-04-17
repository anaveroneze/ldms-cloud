#!/usr/bin/env bash 
export DEBIAN_FRONTEND=noninteractive 
sudo apt-get update

sudo apt-get install -y \
  autoconf \
  pkg-config \
  hdf5-tools \
  libhdf5-openmpi-dev \
  openmpi-bin \
  python3.10 \
  python-dev-is-python3 \
  make \
  bison \
  flex \
  python3-docutils \
  libjansson-dev \
  git \
  build-essential
  
cd "$HOME"
git clone https://github.com/ovis-hpc/ovis.git
cd "$HOME/ovis"
./autogen.sh
mkdir -p build
cd build
../configure --prefix="$HOME/ovis/build"
make -j"$(nproc)"
make install

cat > "$HOME/set-ldms-env.sh" <<'EOENV'
#!/bin/sh
export LDMS_INSTALL_PATH=${HOME}/ovis/build
export PATH=$LDMS_INSTALL_PATH/sbin:$LDMS_INSTALL_PATH/bin:$PATH
export LD_LIBRARY_PATH=$LDMS_INSTALL_PATH/lib:${LD_LIBRARY_PATH:-}
export LDMSD_PLUGIN_LIBPATH=$LDMS_INSTALL_PATH/lib/ovis-ldms
export ZAP_LIBPATH=$LDMS_INSTALL_PATH/lib/ovis-ldms
EOENV

chmod +x "$HOME/set-ldms-env.sh"

if ! grep -qxF 'source ~/set-ldms-env.sh' "$HOME/.bashrc"; then
  echo 'source ~/set-ldms-env.sh' >> "$HOME/.bashrc"
fi

. "$HOME/set-ldms-env.sh"
which ldmsd 