// Minimal Metal bridge with a plain C ABI (MRC, no ARC assumptions).
//
// Device selection uses MTLCopyAllDevices()[0]: MTLCreateSystemDefaultDevice
// returns nil on some discrete-GPU configurations where enumeration works.
// GPU writes land in a Shared MTLBuffer (compute path); render-target
// texture writes are not used here (see nvg/metal.nim notes).
#ifndef NVG_METAL_BRIDGE_H
#define NVG_METAL_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Pipeline slots (index into the context's pipeline table).
#define NVGMTL_SLOTS 12

// Buffer slots: 0 = pixels (RGBA8 bytes), 1 = aux (float32 coverage).
#define NVGMTL_NBUFS 2

// Number of Metal devices, or 0 when Metal is unavailable.
int nvgmtl_device_count(void);

// Opaque context (+1 owned). NULL when no device, bad size, or no buffer.
void *nvgmtl_create(int w, int h);
void nvgmtl_destroy(void *ctx);

// Compile `name` from MSL `src` into `slot` (0..SLOTS-1). 0 on success,
// negative error code otherwise.
int nvgmtl_build(void *ctx, int slot, const char *src, int srclen,
  const char *name, int namelen);

// Dispatch `slot` over w*h threads; `params` (paramslen bytes, may be
// NULL with 0) is visible as buffer(1), dims as buffer(2).
void nvgmtl_fill(void *ctx, int slot, const void *params, int paramslen);

// Create/replace the pattern texture from straight RGBA8 bytes
// (Shared storage, CPU-uploaded; GPU texture reads are the tested
// path, GPU texture writes are not used). 0 on success.
int nvgmtl_pattern(void *ctx, const unsigned char *px, int w, int h);

// Copy a full w*h*4-byte image into buffer `slot` (0 pixels, 1 aux).
// No-op on NULL or bad slot.
void nvgmtl_upload(void *ctx, int slot, const unsigned char *src);

// Copy buffer `slot` out into dst (must hold w*h*4 bytes).
// No-op on NULL or bad slot.
void nvgmtl_readback(void *ctx, int slot, unsigned char *dst);

// Device name into dst (NUL-terminated, truncated to cap). Returns length.
int nvgmtl_device_name(void *ctx, char *dst, int cap);

#ifdef __cplusplus
}
#endif

#endif
