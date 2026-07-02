CUDA_PATH   ?= /usr/local/cuda-12.9
NVCC         = $(CUDA_PATH)/bin/nvcc
MM_DIR      ?= /opt/maskmaster/c
SM_DIR      ?= /opt/libsmctrl

# -arch=native requires CUDA >= 11.6; override with e.g. SM_ARCH=sm_86 for
# older GPUs, or sm_120 for Blackwell/RTX 50-series.
SM_ARCH ?= native
CFLAGS  = -O2 -arch=$(SM_ARCH) -allow-unsupported-compiler \
          -I$(CUDA_PATH)/targets/x86_64-linux/include \
          -I$(MM_DIR) -I$(SM_DIR)
LDFLAGS = -L$(MM_DIR) -lmaskmaster -L$(SM_DIR) -lsmctrl -lcuda \
          -Xlinker -rpath -Xlinker $(MM_DIR) \
          -Xlinker -rpath -Xlinker $(SM_DIR)

bench: bench.cu
	$(NVCC) $(CFLAGS) $< -o $@ $(LDFLAGS)

clean:
	rm -f bench results.csv
