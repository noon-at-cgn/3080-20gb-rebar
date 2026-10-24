/* Memtest-style pattern check over DEVICE_LOCAL|HOST_VISIBLE Vulkan memory (the BAR1-backed type).
 *
 * Usage: vk_bar_verify DDDD:BB:DD.F CHUNK_MIB LIMIT_MIB SEED [PARENT_BDF]
 * Prints one JSON object on stdout; stage markers ("stage <name> <seconds>") go to stderr so a
 * wrapper that kills a stalled run still knows where it stopped. Run it only through vk_bar_verify.py,
 * which refuses unless the card is drained and idle and sets LIMIT_MIB to free VRAM minus a reserve.
 *
 * No Vulkan SDK needed: the few types used are declared below (Vulkan ABI) and libvulkan.so.1 is
 * loaded with dlopen. Build: gcc -O2 -o vk_bar_verify vk_bar_verify.c -ldl
 *
 * Chunks of CHUNK_MIB are allocated from the DEVICE_LOCAL|HOST_VISIBLE type until LIMIT_MIB is reached;
 * a failed allocation is retried at half the size down to 1 MiB, then the run stops. Per chunk, in order:
 *   A  the CPU writes pattern A through the mapping (streaming stores); the GPU copies the chunk into a
 *      HOST_VISIBLE|HOST_CACHED buffer (ordinary host memory) and every word is compared;
 *   B  the CPU puts pattern B in that host buffer and the GPU copies it into the chunk (a GPU write);
 *      the CPU reads back 4 KiB per 64 MiB window plus the chunk's last 4 KiB through the mapping
 *      (MOVNTDQA; plain reads of write-combined memory are uncached and slow).
 * After the last chunk every chunk is copied back by the GPU once more and fully compared with B, so a
 * later chunk that aliased onto an earlier one shows as mismatches there.
 * Word w of chunk c is mix64(seed ^ c<<40 ^ block<<9 ^ word), block = w/512 (4 KiB), word = w%512; mix64
 * is a bijection, so every word in the run carries a distinct value. Offsets are bytes from the start of
 * the first chunk, counting chunks in allocation order (Vulkan exposes no physical address).
 * New kernel-log lines are read from /dev/kmsg (root): Xid for this card / any card, and AER lines
 * naming this card or PARENT_BDF. The run stops at the first new Xid on any card. */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef int32_t VkResult;
typedef uint32_t VkFlags;
typedef uint64_t VkDeviceSize;
typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef struct VkDevice_T *VkDevice;
typedef struct VkQueue_T *VkQueue;
typedef struct VkCommandBuffer_T *VkCommandBuffer;
typedef uint64_t VkDeviceMemory, VkBuffer, VkCommandPool, VkFence;
typedef void (*PFN_void)(void);
typedef PFN_void (*PFN_getProc)(VkInstance, const char *);

typedef struct { int32_t sType; const void *pNext; const char *app; uint32_t appVer; const char *eng;
                 uint32_t engVer; uint32_t apiVersion; } VkApplicationInfo;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; const VkApplicationInfo *app;
                 uint32_t nLayers; const char *const *layers; uint32_t nExt; const char *const *ext; } VkInstanceCreateInfo;
typedef struct { int32_t sType; void *pNext; uint32_t domain, bus, device, function; } VkPciBusInfo;
typedef struct { int32_t sType; void *pNext;
                 union { struct { uint32_t apiVersion, driverVersion, vendorID, deviceID; int32_t type;
                                  char name[256]; } p;
                         uint64_t raw[512]; } props; } VkPhysicalDeviceProperties2;
typedef struct { VkFlags flags; uint32_t heap; } VkMemoryType;
typedef struct { VkDeviceSize size; VkFlags flags; } VkMemoryHeap;
typedef struct { uint32_t nTypes; VkMemoryType types[32]; uint32_t nHeaps; VkMemoryHeap heaps[16]; } VkMemProps;
typedef struct { int32_t sType; void *pNext; VkMemProps p; } VkMemProps2;
typedef struct { int32_t sType; void *pNext; VkDeviceSize budget[16]; VkDeviceSize usage[16]; } VkMemBudget;
typedef struct { VkFlags flags; uint32_t count, tsBits, w, h, d; } VkQueueFamilyProperties;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; uint32_t family, count;
                 const float *prio; } VkDeviceQueueCreateInfo;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; uint32_t nQueues; const VkDeviceQueueCreateInfo *queues;
                 uint32_t nLayers; const char *const *layers; uint32_t nExt; const char *const *ext;
                 const void *features; } VkDeviceCreateInfo;
typedef struct { int32_t sType; const void *pNext; VkDeviceSize size; uint32_t type; } VkMemoryAllocateInfo;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; VkDeviceSize size; VkFlags usage; int32_t sharing;
                 uint32_t nFamilies; const uint32_t *families; } VkBufferCreateInfo;
typedef struct { VkDeviceSize size, alignment; uint32_t typeBits; } VkMemoryRequirements;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; uint32_t family; } VkCommandPoolCreateInfo;
typedef struct { int32_t sType; const void *pNext; VkCommandPool pool; int32_t level; uint32_t count; } VkCommandBufferAllocateInfo;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; const void *inherit; } VkCommandBufferBeginInfo;
typedef struct { VkDeviceSize src, dst, size; } VkBufferCopy;
typedef struct { int32_t sType; const void *pNext; uint32_t nWait; const void *wait; const VkFlags *waitStages;
                 uint32_t nCmd; const VkCommandBuffer *cmds; uint32_t nSignal; const void *signal; } VkSubmitInfo;
typedef struct { int32_t sType; const void *pNext; VkFlags flags; } VkFenceCreateInfo;
typedef struct { int32_t sType; const void *pNext; VkFlags src, dst; } VkMemoryBarrier;

enum { ST_APP = 0, ST_INSTANCE = 1, ST_QUEUE = 2, ST_DEVICE = 3, ST_SUBMIT = 4, ST_ALLOC = 5, ST_FENCE = 8,
       ST_BUFFER = 12, ST_CMD_POOL = 39, ST_CMD_ALLOC = 40, ST_CMD_BEGIN = 42, ST_MEM_BARRIER = 46,
       ST_PROPS2 = 1000059001, ST_MEMPROPS2 = 1000059006, ST_PCI_BUS_INFO = 1000212000, ST_MEM_BUDGET = 1000237000 };
enum { DEVICE_LOCAL = 1, HOST_VISIBLE = 2, HOST_COHERENT = 4, HOST_CACHED = 8, HEAP_DEVICE_LOCAL = 1 };
enum { USAGE_SRC_DST = 3, POOL_RESET_CMD = 2, BEGIN_ONE_TIME = 1, STAGE_TRANSFER = 0x1000, STAGE_HOST = 0x4000,
       ACCESS_TRANSFER_WRITE = 0x1000, ACCESS_HOST_READ = 0x2000, VK_TIMEOUT_R = 2 };

#define MIB (1ull << 20)
#define WORDS_PER_BLOCK 512 /* 4 KiB */
#define SAMPLE_WINDOW (64 * MIB)
#define FENCE_TIMEOUT_NS 30000000000ull
#define MAX_CHUNKS 256
#define NOT_RUN INT32_MIN

static double t_start;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void stage(const char *fmt, int i) {
    fprintf(stderr, "stage ");
    fprintf(stderr, fmt, i);
    fprintf(stderr, " %.3f\n", now() - t_start);
    fflush(stderr);
}

static inline uint64_t mix64(uint64_t z) { /* splitmix64 finalizer: a bijection on 64-bit values */
    z += 0x9E3779B97F4A7C15ull;
    z = (z ^ z >> 30) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ z >> 27) * 0x94D049BB133111EBull;
    return z ^ z >> 31;
}

static inline uint64_t pat(uint64_t seed, uint64_t chunk, uint64_t w) {
    uint64_t block = w / WORDS_PER_BLOCK, word = w % WORDS_PER_BLOCK;
    return mix64(seed ^ chunk << 40 ^ block << 9 ^ word);
}

/* Streaming loads from write-combined memory; n is a multiple of 64, both pointers 16-aligned. */
__attribute__((target("sse4.1"))) static void nt_read(void *dst, const void *src, size_t n) {
    __m128i *d = dst, *s = (__m128i *)src;
    for (size_t i = 0; i < n / 16; i += 4) {
        __m128i a = _mm_stream_load_si128(s + i), b = _mm_stream_load_si128(s + i + 1);
        __m128i c = _mm_stream_load_si128(s + i + 2), e = _mm_stream_load_si128(s + i + 3);
        _mm_store_si128(d + i, a);
        _mm_store_si128(d + i + 1, b);
        _mm_store_si128(d + i + 2, c);
        _mm_store_si128(d + i + 3, e);
    }
}

typedef struct { uint64_t bytes, bad, first, end; } Tally; /* first = ~0 when clean; end = highest offset + 1 */

/* p holds words [w0, w0+n) of chunk `chunk`, which starts at byte offset `base`. */
static void check(Tally *t, const uint64_t *p, uint64_t seed, uint64_t chunk, uint64_t w0, uint64_t n, uint64_t base) {
    for (uint64_t i = 0; i < n; i++)
        if (p[i] != pat(seed, chunk, w0 + i)) {
            if (t->first == ~0ull) t->first = base + (w0 + i) * 8;
            t->bad++;
        }
    t->bytes += n * 8;
    if (base + (w0 + n) * 8 > t->end) t->end = base + (w0 + n) * 8;
}

static void add(Tally *sum, const Tally *t) {
    sum->bytes += t->bytes;
    sum->bad += t->bad;
    if (t->first < sum->first) sum->first = t->first;
    if (t->end > sum->end) sum->end = t->end;
}

static void print_tally(const char *key, const Tally *t) {
    printf(",\"%s\":{\"bytes_verified\":%llu,\"mismatched_words\":%llu,\"first_bad_offset\":", key,
           (unsigned long long)t->bytes, (unsigned long long)t->bad);
    if (t->first == ~0ull) printf("null"); else printf("%llu", (unsigned long long)t->first);
    printf(",\"highest_offset\":");
    if (t->end) printf("%llu}", (unsigned long long)t->end - 1); else printf("null}");
}

static void print_r(const char *key, int r) {
    if (r == NOT_RUN) printf(",\"%s\":null", key); else printf(",\"%s\":%d", key, r);
}

/* ---- kernel log: new records since start, read without blocking from /dev/kmsg */
typedef struct { unsigned xid, xid_any, aer; } Ev;
static int kfd = -1;
static Ev ev;
static char xid_tag[40], bdf_s[16], parent_s[16];

static Ev kmsg_poll(void) {
    char b[8192];
    while (kfd >= 0) {
        ssize_t n = read(kfd, b, sizeof b - 1);
        if (n < 0 && errno == EPIPE) continue; /* records overwritten before we read them */
        if (n <= 0) break;
        b[n] = 0;
        char *msg = strchr(b, ';');
        msg = msg ? msg + 1 : b;
        if (strstr(msg, "NVRM: Xid")) { ev.xid_any++; if (strstr(msg, xid_tag)) ev.xid++; }
        if (strstr(msg, "AER") && (strstr(msg, bdf_s) || (*parent_s && strstr(msg, parent_s)))) ev.aer++;
    }
    return ev;
}

static void print_ev(const char *key, Ev e) {
    printf(",\"%s\":{\"xid\":%u,\"xid_any\":%u,\"aer\":%u}", key, e.xid, e.xid_any, e.aer);
}

/* ---- device functions used after setup */
static struct {
    VkResult (*createBuffer)(VkDevice, const VkBufferCreateInfo *, const void *, VkBuffer *);
    void (*destroyBuffer)(VkDevice, VkBuffer, const void *);
    void (*bufferReqs)(VkDevice, VkBuffer, VkMemoryRequirements *);
    VkResult (*bindBuffer)(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize);
    VkResult (*allocMem)(VkDevice, const VkMemoryAllocateInfo *, const void *, VkDeviceMemory *);
    void (*freeMem)(VkDevice, VkDeviceMemory, const void *);
    VkResult (*mapMem)(VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, void **);
    void (*unmapMem)(VkDevice, VkDeviceMemory);
    VkResult (*resetCmd)(VkCommandBuffer, VkFlags);
    VkResult (*beginCmd)(VkCommandBuffer, const VkCommandBufferBeginInfo *);
    VkResult (*endCmd)(VkCommandBuffer);
    void (*cmdCopy)(VkCommandBuffer, VkBuffer, VkBuffer, uint32_t, const VkBufferCopy *);
    void (*cmdBarrier)(VkCommandBuffer, VkFlags, VkFlags, VkFlags, uint32_t, const VkMemoryBarrier *, uint32_t,
                       const void *, uint32_t, const void *);
    VkResult (*resetFences)(VkDevice, uint32_t, const VkFence *);
    VkResult (*waitFences)(VkDevice, uint32_t, const VkFence *, uint32_t, uint64_t);
    VkResult (*submit)(VkQueue, uint32_t, const VkSubmitInfo *, VkFence);
} vk;
static VkDevice vd;
static VkQueue queue;
static VkCommandBuffer cmd;
static VkFence fence;

/* GPU copies size bytes src -> dst and waits; the barrier makes the result visible to host reads. */
static VkResult gpu_copy(VkBuffer src, VkBuffer dst, VkDeviceSize size) {
    VkCommandBufferBeginInfo bi = {ST_CMD_BEGIN, 0, BEGIN_ONE_TIME, 0};
    VkBufferCopy region = {0, 0, size};
    VkMemoryBarrier mb = {ST_MEM_BARRIER, 0, ACCESS_TRANSFER_WRITE, ACCESS_HOST_READ};
    VkSubmitInfo si = {ST_SUBMIT, 0, 0, 0, 0, 1, &cmd, 0, 0};
    VkResult r;
    if ((r = vk.resetCmd(cmd, 0)) || (r = vk.beginCmd(cmd, &bi))) return r;
    vk.cmdCopy(cmd, src, dst, 1, &region);
    vk.cmdBarrier(cmd, STAGE_TRANSFER, STAGE_HOST, 0, 1, &mb, 0, 0, 0, 0);
    if ((r = vk.endCmd(cmd)) || (r = vk.resetFences(vd, 1, &fence)) || (r = vk.submit(queue, 1, &si, fence))) return r;
    return vk.waitFences(vd, 1, &fence, 1, FENCE_TIMEOUT_NS);
}

typedef struct {
    uint64_t off, size;
    int alloc_r, bind_r, map_r, copy_a_r, copy_b_r, copy_final_r;
    long long usage_mib, budget_mib;
    Tally a, sparse, fin;
    Ev before, after;
    double secs;
    VkBuffer buf;
    VkDeviceMemory mem;
    void *map;
} Chunk;

#define FAIL(...) do { printf("{\"error\":\""); printf(__VA_ARGS__); printf("\"}\n"); return 1; } while (0)
#define LOAD(var, type, inst, name) __typeof__(type) var = (type)gip(inst, name); if (!var) FAIL("missing %s", name)
#define LOADV(field, name) vk.field = (__typeof__(vk.field))gip(inst, name); if (!vk.field) FAIL("missing %s", name)

int main(int argc, char **argv) {
    t_start = now();
    if (argc != 5 && argc != 6) FAIL("usage: vk_bar_verify BDF CHUNK_MIB LIMIT_MIB SEED [PARENT_BDF]");
    unsigned dom, bus, dev, fn;
    if (sscanf(argv[1], "%x:%x:%x.%x", &dom, &bus, &dev, &fn) != 4) FAIL("bad bdf");
    VkDeviceSize chunk_max = strtoull(argv[2], 0, 10) * MIB, limit = strtoull(argv[3], 0, 10) * MIB;
    uint64_t seed_a = strtoull(argv[4], 0, 0), seed_b = mix64(seed_a ^ 0xB0B0B0B0B0B0B0B0ull);
    if (!chunk_max || !limit) FAIL("need CHUNK_MIB > 0 and LIMIT_MIB > 0");
    if (seed_b == seed_a) seed_b ^= 1;
    snprintf(bdf_s, sizeof bdf_s, "%04x:%02x:%02x.%x", dom, bus, dev, fn);
    snprintf(xid_tag, sizeof xid_tag, "Xid (PCI:%04x:%02x:%02x)", dom, bus, dev);
    if (argc == 6) snprintf(parent_s, sizeof parent_s, "%s", argv[5]);
    if ((kfd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK)) >= 0) lseek(kfd, 0, SEEK_END);

    void *lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!lib) FAIL("dlopen libvulkan.so.1 failed");
    PFN_getProc gip = (PFN_getProc)dlsym(lib, "vkGetInstanceProcAddr");
    if (!gip) FAIL("no vkGetInstanceProcAddr");

    stage("instance", 0);
    LOAD(createInstance, VkResult (*)(const VkInstanceCreateInfo *, const void *, VkInstance *), 0, "vkCreateInstance");
    VkApplicationInfo app = {ST_APP, 0, "vk_bar_verify", 1, 0, 0, (1u << 22) | (1u << 12)}; /* 1.1 */
    VkInstanceCreateInfo ici = {ST_INSTANCE, 0, 0, &app, 0, 0, 0, 0};
    VkInstance inst;
    VkResult r = createInstance(&ici, 0, &inst);
    if (r) FAIL("vkCreateInstance %d", r);

    LOAD(enumPhys, VkResult (*)(VkInstance, uint32_t *, VkPhysicalDevice *), inst, "vkEnumeratePhysicalDevices");
    LOAD(getProps2, void (*)(VkPhysicalDevice, VkPhysicalDeviceProperties2 *), inst, "vkGetPhysicalDeviceProperties2");
    LOAD(getMem2, void (*)(VkPhysicalDevice, VkMemProps2 *), inst, "vkGetPhysicalDeviceMemoryProperties2");
    LOAD(getQueues, void (*)(VkPhysicalDevice, uint32_t *, VkQueueFamilyProperties *), inst,
         "vkGetPhysicalDeviceQueueFamilyProperties");
    LOAD(createDevice, VkResult (*)(VkPhysicalDevice, const VkDeviceCreateInfo *, const void *, VkDevice *), inst,
         "vkCreateDevice");
    LOAD(getQueue, void (*)(VkDevice, uint32_t, uint32_t, VkQueue *), inst, "vkGetDeviceQueue");
    LOAD(createPool, VkResult (*)(VkDevice, const VkCommandPoolCreateInfo *, const void *, VkCommandPool *), inst,
         "vkCreateCommandPool");
    LOAD(allocCmd, VkResult (*)(VkDevice, const VkCommandBufferAllocateInfo *, VkCommandBuffer *), inst,
         "vkAllocateCommandBuffers");
    LOAD(createFence, VkResult (*)(VkDevice, const VkFenceCreateInfo *, const void *, VkFence *), inst, "vkCreateFence");
    LOAD(destroyFence, void (*)(VkDevice, VkFence, const void *), inst, "vkDestroyFence");
    LOAD(destroyPool, void (*)(VkDevice, VkCommandPool, const void *), inst, "vkDestroyCommandPool");
    LOAD(destroyDevice, void (*)(VkDevice, const void *), inst, "vkDestroyDevice");
    LOAD(destroyInstance, void (*)(VkInstance, const void *), inst, "vkDestroyInstance");
    LOADV(createBuffer, "vkCreateBuffer");
    LOADV(destroyBuffer, "vkDestroyBuffer");
    LOADV(bufferReqs, "vkGetBufferMemoryRequirements");
    LOADV(bindBuffer, "vkBindBufferMemory");
    LOADV(allocMem, "vkAllocateMemory");
    LOADV(freeMem, "vkFreeMemory");
    LOADV(mapMem, "vkMapMemory");
    LOADV(unmapMem, "vkUnmapMemory");
    LOADV(resetCmd, "vkResetCommandBuffer");
    LOADV(beginCmd, "vkBeginCommandBuffer");
    LOADV(endCmd, "vkEndCommandBuffer");
    LOADV(cmdCopy, "vkCmdCopyBuffer");
    LOADV(cmdBarrier, "vkCmdPipelineBarrier");
    LOADV(resetFences, "vkResetFences");
    LOADV(waitFences, "vkWaitForFences");
    LOADV(submit, "vkQueueSubmit");

    uint32_t n = 16;
    VkPhysicalDevice phys[16], pd = 0;
    enumPhys(inst, &n, phys);
    char name[256] = "";
    for (uint32_t i = 0; i < n && !pd; i++) {
        VkPciBusInfo pci = {ST_PCI_BUS_INFO, 0, 0, 0, 0, 0};
        VkPhysicalDeviceProperties2 p2;
        memset(&p2, 0, sizeof p2);
        p2.sType = ST_PROPS2;
        p2.pNext = &pci;
        getProps2(phys[i], &p2);
        if (pci.domain == dom && pci.bus == bus && pci.device == dev && pci.function == fn) {
            pd = phys[i];
            memcpy(name, p2.props.p.name, 255);
        }
    }
    if (!pd) { destroyInstance(inst, 0); FAIL("no Vulkan device at %s", argv[1]); }

    VkMemBudget bud = {ST_MEM_BUDGET, 0, {0}, {0}};
    VkMemProps2 mp2 = {ST_MEMPROPS2, &bud, {0}};
    getMem2(pd, &mp2);
    VkMemProps mp = mp2.p;
    int type = -1;
    for (uint32_t i = 0; i < mp.nTypes; i++) {
        VkFlags f = mp.types[i].flags;
        if ((f & (DEVICE_LOCAL | HOST_VISIBLE)) == (DEVICE_LOCAL | HOST_VISIBLE) &&
            (type < 0 || ((f & HOST_COHERENT) && !(mp.types[type].flags & HOST_COHERENT))))
            type = (int)i;
    }
    if (type < 0) { destroyInstance(inst, 0); FAIL("no DEVICE_LOCAL|HOST_VISIBLE memory type"); }
    if (!(mp.types[type].flags & HOST_COHERENT)) { destroyInstance(inst, 0); FAIL("DEVICE_LOCAL|HOST_VISIBLE type not coherent"); }
    uint32_t heap = mp.types[type].heap;

    stage("device", 0);
    uint32_t nq = 16, family = UINT32_MAX;
    VkQueueFamilyProperties qf[16];
    getQueues(pd, &nq, qf);
    for (uint32_t i = 0; i < nq && family == UINT32_MAX; i++)
        if (qf[i].flags & 7) family = i; /* graphics, compute or transfer: all support copies */
    if (family == UINT32_MAX) { destroyInstance(inst, 0); FAIL("no queue family with transfer"); }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {ST_QUEUE, 0, 0, family, 1, &prio};
    VkDeviceCreateInfo dci = {ST_DEVICE, 0, 0, 1, &qci, 0, 0, 0, 0, 0};
    if ((r = createDevice(pd, &dci, 0, &vd))) { destroyInstance(inst, 0); FAIL("vkCreateDevice %d", r); }
    getQueue(vd, family, 0, &queue);
    VkCommandPoolCreateInfo poolci = {ST_CMD_POOL, 0, POOL_RESET_CMD, family};
    VkCommandPool pool;
    if ((r = createPool(vd, &poolci, 0, &pool))) FAIL("vkCreateCommandPool %d", r);
    VkCommandBufferAllocateInfo cai = {ST_CMD_ALLOC, 0, pool, 0, 1};
    if ((r = allocCmd(vd, &cai, &cmd))) FAIL("vkAllocateCommandBuffers %d", r);
    VkFenceCreateInfo fci = {ST_FENCE, 0, 0};
    if ((r = createFence(vd, &fci, 0, &fence))) FAIL("vkCreateFence %d", r);

    /* Readback/staging buffer in ordinary host memory: HOST_VISIBLE|HOST_COHERENT, preferably cached and
     * not device-local. Every chunk's GPU copy goes through it. */
    VkBufferCreateInfo bci = {ST_BUFFER, 0, 0, chunk_max, USAGE_SRC_DST, 0, 0, 0};
    VkBuffer hbuf;
    VkMemoryRequirements req;
    if ((r = vk.createBuffer(vd, &bci, 0, &hbuf))) FAIL("vkCreateBuffer host %d", r);
    vk.bufferReqs(vd, hbuf, &req);
    int htype = -1, hscore = -1;
    for (uint32_t i = 0; i < mp.nTypes; i++) {
        VkFlags f = mp.types[i].flags;
        int s = !(f & DEVICE_LOCAL) * 2 + !!(f & HOST_CACHED);
        if (req.typeBits >> i & 1 && (f & (HOST_VISIBLE | HOST_COHERENT)) == (HOST_VISIBLE | HOST_COHERENT) && s > hscore)
            htype = (int)i, hscore = s;
    }
    if (htype < 0) FAIL("no HOST_VISIBLE|HOST_COHERENT type for the readback buffer");
    VkMemoryAllocateInfo hai = {ST_ALLOC, 0, req.size, (uint32_t)htype};
    VkDeviceMemory hmem;
    uint64_t *host = 0;
    if ((r = vk.allocMem(vd, &hai, 0, &hmem))) FAIL("readback alloc %llu MiB: %d", (unsigned long long)(chunk_max >> 20), r);
    if ((r = vk.bindBuffer(vd, hbuf, hmem, 0))) FAIL("readback bind %d", r);
    if ((r = vk.mapMem(vd, hmem, 0, chunk_max, 0, (void **)&host))) FAIL("readback map %d", r);

    printf("{\"name\":\"%s\",\"memory_type\":%d,\"type_flags\":\"0x%04x\",\"heap\":%u,\"heap_device_local\":%s,"
           "\"heap_mib\":%llu,\"readback_type\":%d,\"readback_flags\":\"0x%04x\",\"chunk_mib\":%llu,\"limit_mib\":%llu,"
           "\"seed\":\"0x%016llx\",\"sample\":\"4 KiB per %llu MiB + last 4 KiB per chunk\",\"kmsg\":%s",
           name, type, mp.types[type].flags, heap, mp.heaps[heap].flags & HEAP_DEVICE_LOCAL ? "true" : "false",
           (unsigned long long)(mp.heaps[heap].size >> 20), htype, mp.types[htype].flags,
           (unsigned long long)(chunk_max >> 20), (unsigned long long)(limit >> 20), (unsigned long long)seed_a,
           SAMPLE_WINDOW >> 20, kfd >= 0 ? "true" : "false");

    static Chunk ch[MAX_CHUNKS];
    static uint64_t tmp[WORDS_PER_BLOCK] __attribute__((aligned(64)));
    int nc = 0, gpu_fail = 0;
    uint64_t total = 0, cur = chunk_max;
    const char *stop = "limit";
    double t0 = now();
    Ev ev0 = kmsg_poll();
    while (total < limit) {
        if (nc == MAX_CHUNKS) { stop = "max_chunks"; break; }
        Chunk *c = &ch[nc];
        c->off = total;
        c->size = cur < limit - total ? cur : (limit - total) / MIB * MIB;
        if (!c->size) break;
        c->bind_r = c->map_r = c->copy_a_r = c->copy_b_r = c->copy_final_r = NOT_RUN;
        c->a.first = c->sparse.first = c->fin.first = ~0ull;
        c->before = kmsg_poll();
        t0 = now();
        stage("c%d.alloc", nc);
        bci.size = c->size;
        if ((r = vk.createBuffer(vd, &bci, 0, &c->buf))) FAIL("vkCreateBuffer chunk %d: %d", nc, r);
        vk.bufferReqs(vd, c->buf, &req);
        VkMemoryAllocateInfo mai = {ST_ALLOC, 0, req.size, (uint32_t)type};
        c->alloc_r = req.typeBits >> type & 1 ? vk.allocMem(vd, &mai, 0, &c->mem) : -1;
        nc++;
        if (c->alloc_r) {
            vk.destroyBuffer(vd, c->buf, 0);
            c->buf = c->mem = 0;
            c->after = kmsg_poll();
            if (c->size <= MIB) { stop = "alloc_failed"; break; }
            cur = c->size / 2 / MIB * MIB; /* retry smaller */
            continue;
        }
        mp2.pNext = &bud;
        getMem2(pd, &mp2);
        c->usage_mib = (long long)(bud.usage[heap] >> 20);
        c->budget_mib = (long long)(bud.budget[heap] >> 20);
        if ((c->bind_r = vk.bindBuffer(vd, c->buf, c->mem, 0)) ||
            (c->map_r = vk.mapMem(vd, c->mem, 0, c->size, 0, &c->map))) {
            c->after = kmsg_poll();
            stop = c->bind_r ? "bind_failed" : "map_failed";
            break;
        }
        total += c->size;
        uint64_t words = c->size / 8, *m = c->map;

        stage("c%d.fill_a", nc - 1);
        for (uint64_t w = 0; w < words; w++) _mm_stream_si64((long long *)&m[w], (long long)pat(seed_a, nc - 1, w));
        _mm_sfence();
        stage("c%d.copy_a", nc - 1);
        if ((c->copy_a_r = gpu_copy(c->buf, hbuf, c->size))) { gpu_fail = c->copy_a_r; stop = "gpu_copy"; break; }
        stage("c%d.verify_a", nc - 1);
        check(&c->a, host, seed_a, nc - 1, 0, words, c->off);

        stage("c%d.gpu_write_b", nc - 1);
        for (uint64_t w = 0; w < words; w++) host[w] = pat(seed_b, nc - 1, w);
        if ((c->copy_b_r = gpu_copy(hbuf, c->buf, c->size))) { gpu_fail = c->copy_b_r; stop = "gpu_copy"; break; }
        stage("c%d.sparse_b", nc - 1);
        uint64_t blocks = words / WORDS_PER_BLOCK;
        for (uint64_t w0 = 0; w0 < c->size; w0 += SAMPLE_WINDOW) {
            uint64_t span = (c->size - w0 < SAMPLE_WINDOW ? c->size - w0 : SAMPLE_WINDOW) / 4096;
            uint64_t blk = w0 / 4096 + mix64(seed_b ^ (uint64_t)nc << 48 ^ w0) % span;
            nt_read(tmp, m + blk * WORDS_PER_BLOCK, 4096);
            check(&c->sparse, tmp, seed_b, nc - 1, blk * WORDS_PER_BLOCK, WORDS_PER_BLOCK, c->off);
        }
        nt_read(tmp, m + (blocks - 1) * WORDS_PER_BLOCK, 4096);
        check(&c->sparse, tmp, seed_b, nc - 1, (blocks - 1) * WORDS_PER_BLOCK, WORDS_PER_BLOCK, c->off);
        c->secs = now() - t0;
        c->after = kmsg_poll();
        if (c->after.xid_any > c->before.xid_any) { stop = "xid"; break; }
    }
    if (nc) { /* the last chunk may have ended in a break */
        ch[nc - 1].secs = now() - t0;
        ch[nc - 1].after = kmsg_poll();
    }

    /* Final pass: every chunk still holds B unless a later chunk overwrote it. */
    if (!gpu_fail && strcmp(stop, "xid"))
        for (int i = 0; i < nc; i++) {
            Chunk *c = &ch[i];
            if (!c->map || c->copy_b_r) continue;
            stage("final%d", i);
            Ev e = kmsg_poll();
            if ((c->copy_final_r = gpu_copy(c->buf, hbuf, c->size))) { gpu_fail = c->copy_final_r; stop = "gpu_copy"; break; }
            check(&c->fin, host, seed_b, i, 0, c->size / 8, c->off);
            if (kmsg_poll().xid_any > e.xid_any) { stop = "xid"; break; }
        }

    Tally ta = {0, 0, ~0ull, 0}, ts = ta, tf = ta;
    printf(",\"chunks\":[");
    for (int i = 0; i < nc; i++) {
        Chunk *c = &ch[i];
        printf("%s{\"i\":%d,\"offset\":%llu,\"size_mib\":%llu,\"type\":%d,\"heap\":%u", i ? "," : "", i,
               (unsigned long long)c->off, (unsigned long long)(c->size >> 20), type, heap);
        print_r("alloc_result", c->alloc_r);
        print_r("bind_result", c->bind_r);
        print_r("map_result", c->map_r);
        if (!c->alloc_r) printf(",\"heap_usage_mib\":%lld,\"heap_budget_mib\":%lld", c->usage_mib, c->budget_mib);
        print_r("copy_a_result", c->copy_a_r);
        print_r("copy_b_result", c->copy_b_r);
        print_r("copy_final_result", c->copy_final_r);
        if (c->a.bytes) print_tally("verify_a", &c->a);
        if (c->sparse.bytes) print_tally("sparse_b", &c->sparse);
        if (c->fin.bytes) print_tally("final_b", &c->fin);
        print_ev("kmsg_before", c->before);
        print_ev("kmsg_after", c->after);
        printf(",\"seconds\":%.3f}", c->secs);
        add(&ta, &c->a);
        add(&ts, &c->sparse);
        add(&tf, &c->fin);
    }
    printf("]");
    print_tally("verify_a", &ta);
    print_tally("sparse_b", &ts);
    print_tally("final_b", &tf);
    uint64_t bad = ta.bad + ts.bad + tf.bad;
    Ev ev1 = kmsg_poll();
    printf(",\"allocated_mib\":%llu,\"bytes_verified\":%llu,\"mismatched_words\":%llu,\"highest_offset\":",
           (unsigned long long)(total >> 20), (unsigned long long)ta.bytes, (unsigned long long)bad);
    if (ta.end) printf("%llu", (unsigned long long)ta.end - 1); else printf("null");
    printf(",\"stop_reason\":\"%s\"", stop);
    if (gpu_fail) printf(",\"gpu_copy_result\":%d", gpu_fail);
    print_ev("kmsg_new", (Ev){ev1.xid - ev0.xid, ev1.xid_any - ev0.xid_any, ev1.aer - ev0.aer});
    int clean = !bad && total && !gpu_fail && (!strcmp(stop, "limit") || !strcmp(stop, "alloc_failed"));
    printf(",\"verdict\":%s", clean ? "true" : "false");
    fflush(stdout);
    if (gpu_fail == VK_TIMEOUT_R) { /* copy still pending on the GPU: freeing its memory is unsafe */
        printf(",\"teardown\":\"skipped\",\"elapsed_s\":%.3f}\n", now() - t_start);
        return 0;
    }

    stage("teardown", 0);
    for (int i = 0; i < nc; i++) {
        if (ch[i].map) vk.unmapMem(vd, ch[i].mem);
        if (ch[i].buf) vk.destroyBuffer(vd, ch[i].buf, 0);
        if (ch[i].mem) vk.freeMem(vd, ch[i].mem, 0);
    }
    vk.unmapMem(vd, hmem);
    vk.destroyBuffer(vd, hbuf, 0);
    vk.freeMem(vd, hmem, 0);
    destroyFence(vd, fence, 0);
    destroyPool(vd, pool, 0);
    destroyDevice(vd, 0);
    destroyInstance(inst, 0);
    printf(",\"elapsed_s\":%.3f}\n", now() - t_start);
    stage("done", 0);
    return 0;
}
