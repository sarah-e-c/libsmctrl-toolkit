FROM nvidia/cuda:12.9.0-devel-ubuntu22.04

LABEL org.opencontainers.image.title="libsmctrl-toolkit" \
      org.opencontainers.image.description="libsmctrl (blackwell branch) + maskmaster + nvdebug, prebuilt, for downstream GPU TPC-masking images" \
      org.opencontainers.image.source="https://github.com/sarah-e-c/libsmctrl-toolkit" \
      org.opencontainers.image.licenses="NOASSERTION"

RUN apt-get update && apt-get install -y --no-install-recommends \
        git gcc make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# libsmctrl fork (github.com/sarah-e-c/libsmctrl, branch "blackwell") carries the
# Blackwell QMDV05_00 TPC-masking patch on top of upstream rtsrv.cs.unc.edu/libsmctrl.
RUN git clone --branch blackwell https://github.com/sarah-e-c/libsmctrl.git /opt/libsmctrl \
    && make -C /opt/libsmctrl libsmctrl.so

# maskmaster, built with hardware discovery enabled against the libsmctrl above.
RUN git clone https://github.com/sarah-e-c/maskmaster.git /opt/maskmaster \
    && make -C /opt/maskmaster/c clean \
    && make -C /opt/maskmaster/c libmaskmaster.so DISCOVERY=1 SMCTRL_DIR=/opt/libsmctrl

ENV LD_LIBRARY_PATH=/opt/maskmaster/c:/opt/libsmctrl

# nvdebug source only -- NOT built here. It's a kbuild out-of-tree kernel
# module and must be compiled against the exact kernel it will be insmod'd
# into, so a .ko built in the image would only load on a host with the
# identical kernel version. Instead it's built at container start, against
# whatever kernel headers the host bind-mounts in. See docker-entrypoint.sh.
#
# Cloned from a personal mirror (github.com/sarah-e-c/nvdebug), branch
# "ecrts25-ae" -- the canonical host, rtsrv.cs.unc.edu, is UNC-network-only
# and unreachable from GitHub Actions/most outside hosts. ecrts25-ae carries
# newer kernel-compat fixes than master (up through Linux 6.15).
RUN git clone --branch ecrts25-ae https://github.com/sarah-e-c/nvdebug.git /opt/nvdebug

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
