// 简单的 GPU 负载生成器：持续做浮点运算，把利用率顶到接近 100%。
// 用法: ./gpu_burn <持续秒数>
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

__global__ void burn(float *x, long n, int iters) {
    long i = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        float v = x[i];
        for (int k = 0; k < iters; k++) {
            v = v * 1.0000001f + 0.9999999f;
            v = sinf(v) + cosf(v);
        }
        x[i] = v;
    }
}

int main(int argc, char **argv) {
    double seconds = (argc > 1) ? atof(argv[1]) : 180.0;
    long n = 1L << 24;  // 16M floats ≈ 64MB，占显存很小
    float *d = NULL;
    if (cudaMalloc(&d, n * sizeof(float)) != cudaSuccess) {
        fprintf(stderr, "cudaMalloc 失败\n");
        return 1;
    }
    cudaMemset(d, 0, n * sizeof(float));
    int threads = 256;
    int blocks = (int)((n + threads - 1) / threads);
    time_t start = time(NULL);
    while (difftime(time(NULL), start) < seconds) {
        for (int r = 0; r < 40; r++) burn<<<blocks, threads>>>(d, n, 2000);
        cudaDeviceSynchronize();
    }
    cudaFree(d);
    return 0;
}
