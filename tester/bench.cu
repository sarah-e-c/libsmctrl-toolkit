#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <cuda_runtime.h>

#include "maskmaster.h"
#include "libsmctrl.h"

#define MAT_M   4096
#define MAT_K   4096
#define MAT_N   4096
#define TILE    32
#define REPS    10
#define MAX_N   20

#define CUDA_CHECK(call) do { \
    cudaError_t _e = (call); \
    if (_e != cudaSuccess) { \
        fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(_e)); \
        exit(1); \
    } \
} while(0)

__global__ void matmul_kernel(const float* A, const float* B, float* C, int M, int K, int N) {
    __shared__ float As[TILE][TILE];
    __shared__ float Bs[TILE][TILE];

    int row = blockIdx.y * TILE + threadIdx.y;
    int col = blockIdx.x * TILE + threadIdx.x;
    float sum = 0.0f;

    for (int t = 0; t < (K + TILE - 1) / TILE; t++) {
        int aCol = t * TILE + threadIdx.x;
        int bRow = t * TILE + threadIdx.y;
        As[threadIdx.y][threadIdx.x] = (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;
        Bs[threadIdx.y][threadIdx.x] = (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;
        __syncthreads();

        for (int k = 0; k < TILE; k++)
            sum += As[threadIdx.y][k] * Bs[k][threadIdx.x];
        __syncthreads();
    }

    if (row < M && col < N)
        C[row * N + col] = sum;
}

__global__ void fill_kernel(float* data, int n, float base) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
        data[i] = base + (float)(i & 0xF) * 0.01f;
}

int main(int argc, char** argv) {
    int dev = 0;
    const char* outfile = "results.csv";
    bool scan_mode = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-scan") == 0) scan_mode = true;
        else if (i == 1 && !scan_mode) dev     = atoi(argv[i]);
        else if (i == 2 && !scan_mode) outfile = argv[i];
    }

    mm_topology_t topo;
    int err = mm_discover(dev, &topo);
    if (err) {
        fprintf(stderr, "mm_discover failed (err=%d) — is the nvdebug module loaded?\n", err);
        return 1;
    }
    fprintf(stderr, "Topology: %u GPCs, %u TPCs, fingerprint=%s\n",
            topo.num_gpcs, topo.num_tpcs, topo.fingerprint);

    uint32_t max_n = (topo.num_tpcs < MAX_N) ? topo.num_tpcs : MAX_N;

    float *dA, *dB, *dC;
    CUDA_CHECK(cudaMalloc(&dA, (size_t)MAT_M * MAT_K * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&dB, (size_t)MAT_K * MAT_N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&dC, (size_t)MAT_M * MAT_N * sizeof(float)));

    int threads = 256;
    fill_kernel<<<(MAT_M * MAT_K + threads - 1) / threads, threads>>>(dA, MAT_M * MAT_K, 1.0f);
    fill_kernel<<<(MAT_K * MAT_N + threads - 1) / threads, threads>>>(dB, MAT_K * MAT_N, 2.0f);
    CUDA_CHECK(cudaMemset(dC, 0, (size_t)MAT_M * MAT_N * sizeof(float)));
    CUDA_CHECK(cudaDeviceSynchronize());

    cudaStream_t stream;
    CUDA_CHECK(cudaStreamCreate(&stream));
    cudaEvent_t eStart, eStop;
    CUDA_CHECK(cudaEventCreate(&eStart));
    CUDA_CHECK(cudaEventCreate(&eStop));

    dim3 block(TILE, TILE);
    dim3 grid((MAT_N + TILE - 1) / TILE, (MAT_M + TILE - 1) / TILE);

    /* Init callback; warmup with all TPCs to prime caches and clocks */
    libsmctrl_set_global_mask(0);
    for (int r = 0; r < REPS; r++)
        matmul_kernel<<<grid, block, 0, stream>>>(dA, dB, dC, MAT_M, MAT_K, MAT_N);
    CUDA_CHECK(cudaStreamSynchronize(stream));

    if (scan_mode) {
        /* Scan the safe zero-region (0x100..0x200) of the old-callback TMD for
         * the Blackwell SM mask field.  Uses half-disabled mask (~2× slowdown
         * on a hit) so we can detect it without the destructive 41-disabled mask
         * that caused GPU faults when written to control-word offsets. */
        uint32_t half = topo.num_tpcs / 2;
        uint64_t scan_mask = mm_pack(&topo, topo.num_tpcs - half);
        fprintf(stderr, "Scan: mask=0x%016" PRIx64 " (%u/%u TPCs disabled, expect ~%.0fx slowdown)\n",
                scan_mask, half, topo.num_tpcs, (double)topo.num_tpcs / (topo.num_tpcs - half));
        fprintf(stderr, "offset_lo  runtime_ms\n");
        /* Scan the known-safe zero region (0x100..0x200).
         * Skip 0x17C (upper_ptr hits +0x180 which is a live host pointer in the dump)
         * and 0x180/0x184 themselves.  The v2 callback now also ORs bit-31 into
         * word 0 (Hopper-style enable bit) so if the mask field is here we'll see it. */
        for (int lo = 0x100; lo <= 0x200; lo += 4) {
            if (lo == 0x17c || lo == 0x180 || lo == 0x184) continue;
            libsmctrl_set_scan_offset(lo);
            libsmctrl_set_global_mask(scan_mask);
            float total = 0.0f;
            for (int r = 0; r < 3; r++) {
                CUDA_CHECK(cudaEventRecord(eStart, stream));
                matmul_kernel<<<grid, block, 0, stream>>>(dA, dB, dC, MAT_M, MAT_K, MAT_N);
                CUDA_CHECK(cudaEventRecord(eStop, stream));
                CUDA_CHECK(cudaEventSynchronize(eStop));
                float ms;
                CUDA_CHECK(cudaEventElapsedTime(&ms, eStart, eStop));
                total += ms;
            }
            fprintf(stderr, "0x%03x       %.2f\n", lo, total / 3);
        }
        libsmctrl_set_scan_offset(-1);
        libsmctrl_set_global_mask(0);
    } else {
        FILE* f = fopen(outfile, "w");
        if (!f) {
            fprintf(stderr, "Cannot open %s for writing\n", outfile);
            return 1;
        }
        fprintf(f, "strategy,n_tpcs,mask_hex,runtime_ms\n");

        for (uint32_t n = 1; n <= max_n; n++) {
            uint64_t mask = mm_pack(&topo, n);
            libsmctrl_set_global_mask(mask);

            float total_ms = 0.0f;
            for (int r = 0; r < REPS; r++) {
                CUDA_CHECK(cudaEventRecord(eStart, stream));
                matmul_kernel<<<grid, block, 0, stream>>>(dA, dB, dC, MAT_M, MAT_K, MAT_N);
                CUDA_CHECK(cudaEventRecord(eStop, stream));
                CUDA_CHECK(cudaEventSynchronize(eStop));
                float ms;
                CUDA_CHECK(cudaEventElapsedTime(&ms, eStart, eStop));
                total_ms += ms;
            }
            float avg_ms = total_ms / REPS;
            fprintf(f, "pack,%u,0x%016" PRIx64 ",%.4f\n", n, mask, avg_ms);
            fprintf(stderr, "  n=%2u  mask=0x%016" PRIx64 "  avg=%.4f ms\n", n, mask, avg_ms);
        }

        libsmctrl_set_global_mask(0);
        fclose(f);
        fprintf(stderr, "Results written to %s\n", outfile);
    }

    cudaEventDestroy(eStart);
    cudaEventDestroy(eStop);
    cudaStreamDestroy(stream);
    cudaFree(dA);
    cudaFree(dB);
    cudaFree(dC);
    return 0;
}
