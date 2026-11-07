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

// Number of Metal devices, or 0 when Metal is unavailable.
int nvgmtl_device_count(void);

// Opaque context (+1 owned). NULL when no device, bad size, or no buffer.
void *nvgmtl_create(int w, int h);
void nvgmtl_destroy(void *ctx);

// Compile the MSL `fill_solid` kernel from source. 0 on success,
// negative error code otherwise.
int nvgmtl_build_solid(void *ctx, const char *src, int len);

// Fill the whole buffer with straight (non-premultiplied) RGBA floats.
void nvgmtl_fill_solid(void *ctx, float r, float g, float b, float a);

// Copy w*h*4 bytes into dst (must be large enough). No-op on NULL.
void nvgmtl_readback(void *ctx, unsigned char *dst);

// Device name into dst (NUL-terminated, truncated to cap). Returns length.
int nvgmtl_device_name(void *ctx, char *dst, int cap);

#ifdef __cplusplus
}
#endif

#endif
