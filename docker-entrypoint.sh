#!/bin/sh
set -e

# Build and load nvdebug against the *host's* running kernel before handing off
# to the downstream image's CMD. This only works because the container shares
# the host kernel: insmod here loads the module into the host, not a sandboxed
# copy. Requires --privileged (for CAP_SYS_MODULE) and the host's kernel
# headers bind-mounted in, e.g.:
#
#   docker run --privileged --pid=host --gpus all \
#       -v /lib/modules:/lib/modules:ro \
#       -v /usr/src:/usr/src:ro \
#       ...
#
# If nvdebug is already loaded on the host (common when several containers
# share one host), or the headers aren't mounted, this step is skipped.
if [ -d "/proc/gpu0" ] || grep -q '^nvdebug ' /proc/modules 2>/dev/null; then
    echo "docker-entrypoint: nvdebug already loaded on host, skipping" >&2
elif [ -d "/lib/modules/$(uname -r)/build" ]; then
    echo "docker-entrypoint: building nvdebug for kernel $(uname -r)" >&2
    make -C /opt/nvdebug clean
    make -C /opt/nvdebug
    insmod /opt/nvdebug/nvdebug.ko
else
    echo "docker-entrypoint: WARNING no kernel build tree for $(uname -r) at" \
         "/lib/modules/$(uname -r)/build -- mount the host's /lib/modules and" \
         "/usr/src, or insmod nvdebug on the host before starting this" \
         "container. Continuing without it." >&2
fi

exec "$@"
