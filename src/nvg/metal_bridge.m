// See metal_bridge.h. Manual retain/release (MRC): this file must also
// work when the host build does not enable ARC.
// NOTE: Nim only tracks this file's mtime for rebuilds, not the header's;
// touch this file after changing metal_bridge.h (e.g. NVGMTL_SLOTS).
// Slot count: keep in sync with MSlot* in nvg/metal.nim (14 slots).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "metal_bridge.h"
#include <string.h>

@interface NvgMtlCtx : NSObject {
@public
  id<MTLDevice> dev;
  id<MTLCommandQueue> queue;
  id<MTLComputePipelineState> pipes[NVGMTL_SLOTS];
  id<MTLBuffer> bufs[NVGMTL_NBUFS];
  id<MTLTexture> pat;
  int w;
  int h;
}
@end

@implementation NvgMtlCtx
@end

int nvgmtl_device_count(void) {
  @autoreleasepool {
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    return (int)[all count];
  }
}

void *nvgmtl_create(int w, int h) {
  @autoreleasepool {
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    if ([all count] == 0 || w <= 0 || h <= 0) return NULL;
    NvgMtlCtx *c = [[NvgMtlCtx alloc] init];
    c->dev = [[all objectAtIndex:0] retain];
    c->queue = [[c->dev newCommandQueue] retain];
    for (int i = 0; i < NVGMTL_SLOTS; i++) c->pipes[i] = nil;
    for (int i = 0; i < NVGMTL_NBUFS; i++) c->bufs[i] = nil;
    c->pat = nil;
    for (int i = 0; i < NVGMTL_NBUFS; i++) {
      c->bufs[i] = [[c->dev newBufferWithLength:(NSUInteger)(w * h * 4)
                                        options:MTLResourceStorageModeShared] retain];
      if (c->bufs[i] == nil) {
        [c release];
        return NULL;
      }
    }
    c->w = w;
    c->h = h;
    return (void *)c;
  }
}

void nvgmtl_destroy(void *p) {
  if (p == NULL) return;
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    [c->dev release];
    [c->queue release];
    for (int i = 0; i < NVGMTL_SLOTS; i++) [c->pipes[i] release];
    for (int i = 0; i < NVGMTL_NBUFS; i++) [c->bufs[i] release];
    [c->pat release];
    [c release];
  }
}

int nvgmtl_build(void *p, int slot, const char *src, int srclen,
    const char *name, int namelen) {
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    if (c == NULL || slot < 0 || slot >= NVGMTL_SLOTS) return -1;
    if (src == NULL || srclen <= 0 || name == NULL || namelen <= 0)
      return -1;
    NSString *s = [[NSString alloc] initWithBytes:src
                                           length:(NSUInteger)srclen
                                         encoding:NSUTF8StringEncoding];
    if (s == nil) return -2;
    NSString *n =
        [[NSString alloc] initWithBytes:name length:(NSUInteger)namelen
                               encoding:NSUTF8StringEncoding];
    if (n == nil) {
      [s release];
      return -2;
    }
    NSError *err = nil;
    id<MTLLibrary> lib = [c->dev newLibraryWithSource:s options:nil error:&err];
    [s release];
    if (lib == nil) return -3;
    id<MTLFunction> fn = [lib newFunctionWithName:n];
    [n release];
    [lib release];
    if (fn == nil) return -4;
    id<MTLComputePipelineState> ps =
        [c->dev newComputePipelineStateWithFunction:fn error:&err];
    [fn release];
    if (ps == nil) return -5;
    [c->pipes[slot] release];
    c->pipes[slot] = [ps retain];
    [ps release];
    return 0;
  }
}

void nvgmtl_fill(void *p, int slot, const void *params, int paramslen) {
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    if (c == NULL || slot < 0 || slot >= NVGMTL_SLOTS) return;
    if (c->pipes[slot] == nil) return;
    uint32_t dims[2] = {(uint32_t)c->w, (uint32_t)c->h};
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:c->pipes[slot]];
    [ce setBuffer:c->bufs[0] offset:0 atIndex:0];
    if (params != NULL && paramslen > 0)
      [ce setBytes:params length:(NSUInteger)paramslen atIndex:1];
    [ce setBytes:dims length:sizeof(dims) atIndex:2];
    // Aux doubles as full-size byte scratch (e.g. the blur passes
    // ping-pong RGBA8 through it); bufs[2] is spare (e.g. unsharp
    // keeps the original there). Kernels that ignore a binding
    // simply never declare it.
    [ce setBuffer:c->bufs[1] offset:0 atIndex:3];
    [ce setBuffer:c->bufs[2] offset:0 atIndex:4];
    [ce setTexture:c->pat atIndex:0];
    NSUInteger tx = (NSUInteger)c->w < 16 ? (NSUInteger)c->w : 16;
    NSUInteger ty = (NSUInteger)c->h < 16 ? (NSUInteger)c->h : 16;
    [ce dispatchThreads:MTLSizeMake((NSUInteger)c->w, (NSUInteger)c->h, 1)
        threadsPerThreadgroup:MTLSizeMake(tx, ty, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
  }
}

int nvgmtl_pattern(void *p, const unsigned char *px, int w, int h) {
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    if (c == NULL || px == NULL || w <= 0 || h <= 0) return -1;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w height:h
                                                        mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [c->dev newTextureWithDescriptor:td];
    if (t == nil) return -2;
    MTLRegion rg = MTLRegionMake2D(0, 0, w, h);
    [t replaceRegion:rg mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    [c->pat release];
    c->pat = [t retain];
    [t release];
    return 0;
  }
}

void nvgmtl_copy(void *p, int dstSlot, int srcSlot) {
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    if (c == NULL) return;
    if (dstSlot < 0 || dstSlot >= NVGMTL_NBUFS) return;
    if (srcSlot < 0 || srcSlot >= NVGMTL_NBUFS) return;
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromBuffer:c->bufs[srcSlot] sourceOffset:0
        toBuffer:c->bufs[dstSlot] destinationOffset:0
        size:(NSUInteger)(c->w * c->h * 4)];
    [bl endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
  }
}

void nvgmtl_upload(void *p, int slot, const unsigned char *src) {
  NvgMtlCtx *c = (NvgMtlCtx *)p;
  if (c == NULL || src == NULL) return;
  if (slot < 0 || slot >= NVGMTL_NBUFS) return;
  memcpy([c->bufs[slot] contents], src, (size_t)(c->w * c->h * 4));
}

void nvgmtl_readback(void *p, int slot, unsigned char *dst) {
  NvgMtlCtx *c = (NvgMtlCtx *)p;
  if (c == NULL || dst == NULL) return;
  if (slot < 0 || slot >= NVGMTL_NBUFS) return;
  memcpy(dst, [c->bufs[slot] contents], (size_t)(c->w * c->h * 4));
}

int nvgmtl_device_name(void *p, char *dst, int cap) {
  NvgMtlCtx *c = (NvgMtlCtx *)p;
  if (c == NULL || dst == NULL || cap <= 0) return -1;
  @autoreleasepool {
    const char *s = [[c->dev name] UTF8String];
    int n = 0;
    while (s[n] != '\0' && n < cap - 1) {
      dst[n] = s[n];
      n++;
    }
    dst[n] = '\0';
    return n;
  }
}
