/* VRAM pattern check through the CUDA driver API, as a control for the BAR1 aperture tests.
 *
 * Usage: cuda_memcheck DDDD:BB:DD.F PERCENT_OF_FREE CHUNK_MIB
 * Allocates CHUNK_MIB device buffers up to PERCENT_OF_FREE of free VRAM, writes a unique per-word
 * pattern (global word index * golden ratio ^ seed) into every chunk with cuMemcpyHtoD from pinned
 * host memory, then reads every chunk back with cuMemcpyDtoH and compares. All writes finish before
 * the first read, so aliasing between chunks shows up as mismatches. The copies are DMA through the
 * copy engines, not CPU loads/stores through BAR1, so a failure here points at the memory and a pass
 * here with a failure in the aperture test points at the aperture. No kernels, no Vulkan.
 *
 * No CUDA toolkit needed: the few driver-API entry points used are declared below and
 * libcuda.so.1 is loaded with dlopen. Build: gcc -O2 -o cuda_memcheck cuda_memcheck.c -ldl
 * Prints one JSON object on stdout; stage markers ("stage <name> <seconds>") go to stderr. */
#include <ctype.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

typedef int CUresult;
typedef int CUdevice;
typedef struct CUctx_st *CUcontext;
typedef unsigned long long CUdeviceptr;

static double t_start;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void stage(const char *s) {
    fprintf(stderr, "stage %s %.3f\n", s, now() - t_start);
    fflush(stderr);
}

#define FAIL(...) do { printf("{\"error\":\""); printf(__VA_ARGS__); printf("\"}\n"); return 1; } while (0)
#define LOAD(var, type, name) __typeof__(type) var = (type)dlsym(lib, name); if (!var) FAIL("missing %s", name)
#define MAXCHUNKS 4096
#define SEED 0x5A5A5A5A00000000ull

static void fill(uint64_t *p, size_t words, uint64_t base) {
    for (size_t i = 0; i < words; i++) p[i] = ((base + i) * 0x9E3779B97F4A7C15ull) ^ SEED;
}

static uint64_t check(const uint64_t *p, size_t words, uint64_t base, uint64_t *first) {
    uint64_t bad = 0;
    for (size_t i = 0; i < words; i++)
        if (p[i] != (((base + i) * 0x9E3779B97F4A7C15ull) ^ SEED)) {
            if (*first == ~0ull) *first = (base + i) * 8;
            bad++;
        }
    return bad;
}

int main(int argc, char **argv) {
    t_start = now();
    if (argc != 4) FAIL("usage: cuda_memcheck BDF PERCENT_OF_FREE CHUNK_MIB");
    int pct = atoi(argv[2]);
    size_t chunk = (size_t)strtoull(argv[3], 0, 10) << 20;
    if (pct < 1 || pct > 98 || !chunk) FAIL("need 1 <= PERCENT <= 98 and CHUNK_MIB > 0");

    void *lib = dlopen("libcuda.so.1", RTLD_NOW);
    if (!lib) FAIL("dlopen libcuda.so.1 failed");
    LOAD(cuInit, CUresult (*)(unsigned), "cuInit");
    LOAD(cuDeviceGetCount, CUresult (*)(int *), "cuDeviceGetCount");
    LOAD(cuDeviceGet, CUresult (*)(CUdevice *, int), "cuDeviceGet");
    LOAD(cuDeviceGetPCIBusId, CUresult (*)(char *, int, CUdevice), "cuDeviceGetPCIBusId");
    LOAD(cuCtxCreate, CUresult (*)(CUcontext *, unsigned, CUdevice), "cuCtxCreate_v2");
    LOAD(cuCtxDestroy, CUresult (*)(CUcontext), "cuCtxDestroy_v2");
    LOAD(cuMemGetInfo, CUresult (*)(size_t *, size_t *), "cuMemGetInfo_v2");
    LOAD(cuMemAlloc, CUresult (*)(CUdeviceptr *, size_t), "cuMemAlloc_v2");
    LOAD(cuMemFree, CUresult (*)(CUdeviceptr), "cuMemFree_v2");
    LOAD(cuMemAllocHost, CUresult (*)(void **, size_t), "cuMemAllocHost_v2");
    LOAD(cuMemFreeHost, CUresult (*)(void *), "cuMemFreeHost");
    LOAD(cuMemcpyHtoD, CUresult (*)(CUdeviceptr, const void *, size_t), "cuMemcpyHtoD_v2");
    LOAD(cuMemcpyDtoH, CUresult (*)(void *, CUdeviceptr, size_t), "cuMemcpyDtoH_v2");

    stage("init");
    CUresult r = cuInit(0);
    if (r) FAIL("cuInit %d", r);
    int n = 0;
    cuDeviceGetCount(&n);
    CUdevice dev = -1;
    for (int i = 0; i < n && dev < 0; i++) {
        CUdevice d;
        char bus[32] = "";
        cuDeviceGet(&d, i);
        cuDeviceGetPCIBusId(bus, sizeof bus, d);
        if (!strcasecmp(bus, argv[1])) dev = d;
    }
    if (dev < 0) FAIL("no CUDA device at %s", argv[1]);
    CUcontext ctx;
    if ((r = cuCtxCreate(&ctx, 0, dev))) FAIL("cuCtxCreate %d", r);

    size_t freeb = 0, total = 0;
    cuMemGetInfo(&freeb, &total);
    size_t target = freeb / 100 * pct;
    CUdeviceptr *bufs = calloc(MAXCHUNKS, sizeof *bufs);
    size_t nchunks = 0;
    CUresult alloc_stop = 0;
    stage("alloc");
    while ((nchunks + 1) * chunk <= target && nchunks < MAXCHUNKS) {
        if ((alloc_stop = cuMemAlloc(&bufs[nchunks], chunk))) break;
        nchunks++;
    }
    void *host = 0;
    if ((r = cuMemAllocHost(&host, chunk))) {
        for (size_t i = 0; i < nchunks; i++) cuMemFree(bufs[i]);
        cuCtxDestroy(ctx);
        FAIL("cuMemAllocHost %d", r);
    }
    size_t words = chunk / 8;
    uint64_t bad = 0, first = ~0ull;
    CUresult copy_err = 0;
    double tw = 0, tr = 0;

    stage("write");
    for (size_t c = 0; c < nchunks && !copy_err; c++) {
        fill(host, words, (uint64_t)c * words);
        double t0 = now();
        copy_err = cuMemcpyHtoD(bufs[c], host, chunk);
        tw += now() - t0;
    }
    stage("verify");
    for (size_t c = 0; c < nchunks && !copy_err; c++) {
        memset(host, 0, chunk);
        double t0 = now();
        copy_err = cuMemcpyDtoH(host, bufs[c], chunk);
        tr += now() - t0;
        if (!copy_err) bad += check(host, words, (uint64_t)c * words, &first);
    }
    stage("free");
    cuMemFreeHost(host);
    for (size_t i = 0; i < nchunks; i++) cuMemFree(bufs[i]);
    cuCtxDestroy(ctx);
    free(bufs);

    double gib = (double)nchunks * chunk / (1ull << 30);
    printf("{\"free_mib\":%zu,\"total_mib\":%zu,\"percent\":%d,\"chunk_mib\":%zu,\"chunks\":%zu,"
           "\"tested_mib\":%zu,\"tested_fraction_of_free\":%.3f,\"alloc_stop_result\":%d,\"copy_error\":%d,"
           "\"htod_gbps\":%.3f,\"dtoh_gbps\":%.3f,\"mismatched_words\":%llu",
           freeb >> 20, total >> 20, pct, chunk >> 20, nchunks, (nchunks * chunk) >> 20,
           freeb ? (double)(nchunks * chunk) / freeb : 0.0, alloc_stop, copy_err,
           tw > 0 ? gib * 1.073741824 / tw : 0.0, tr > 0 ? gib * 1.073741824 / tr : 0.0,
           (unsigned long long)bad);
    if (bad) printf(",\"first_bad_offset\":%llu", (unsigned long long)first);
    printf(",\"verdict\":%s,\"elapsed_s\":%.3f}\n", !bad && !copy_err && nchunks ? "true" : "false",
           now() - t_start);
    stage("done");
    return 0;
}
