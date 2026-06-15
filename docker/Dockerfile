FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    autoconf pkg-config hdf5-tools libhdf5-openmpi-dev openmpi-bin python3.10 \
    python-dev-is-python3 make bison flex python3-docutils libjansson-dev git \
    build-essential && \
    rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/ovis-hpc/ovis.git /ovis && \
    cd /ovis && ./autogen.sh && mkdir build && cd build && \
    ../configure --prefix=/ovis/build && \
    make -j"$(nproc)" && make install

ENV PATH=/ovis/build/sbin:/ovis/build/bin:$PATH
ENV LD_LIBRARY_PATH=/ovis/build/lib
ENV LDMSD_PLUGIN_LIBPATH=/ovis/build/lib/ovis-ldms
ENV ZAP_LIBPATH=/ovis/build/lib/ovis-ldms