# Example downstream image: a small SGEMM benchmark that exercises
# maskmaster/libsmctrl TPC masking, built FROM the base image in this repo.
#
# Build (from the repo root, after building/pulling the base image):
#   docker build -t smctrl-tester-example -f tester/Dockerfile tester
#
# Run (needs the same nvdebug/kernel-header setup as the base image, see the
# top-level README's "Runtime requirement" section):
#   docker run --gpus all --privileged --pid=host \
#       -v /lib/modules:/lib/modules:ro \
#       -v /usr/src:/usr/src:ro \
#       smctrl-tester-example
#
# ARG BASE_IMAGE lets you point at a local build (libsmctrl-toolkit) or the
# published GHCR image without editing this file:
#   docker build --build-arg BASE_IMAGE=ghcr.io/sarah-e-c/libsmctrl-toolkit:latest ...
ARG BASE_IMAGE=ghcr.io/sarah-e-c/libsmctrl-toolkit:latest
FROM ${BASE_IMAGE}

WORKDIR /opt/tester
COPY . .

ARG SM_ARCH=native
RUN make clean && make SM_ARCH=${SM_ARCH}

# The base image's ENTRYPOINT builds/loads nvdebug against the host kernel
# before exec'ing this CMD.
CMD ["/opt/tester/bench"]
