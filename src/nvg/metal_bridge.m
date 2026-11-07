// See metal_bridge.h. Manual retain/release (MRC): this file must also
// work when the host build does not enable ARC.
// NOTE: Nim only tracks this file's mtime for rebuilds, not the header's;
// touch this file after changing metal_bridge.h (e.g. NVGMTL_SLOTS).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "metal_bridge.h"
#include <string.h>

@interface NvgMtlCtx : NSObject {
@public
  id<MTLDevice> dev;
  id<MTLCommandQueue> queue;
  id<MTLComputePipelineState> pipes[NVGMTL_SLOTS];
  id<MTLBuffer> buf;
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
    c->buf = [[c->dev newBufferWithLength:(NSUInteger)(w * h * 4)
                                 options:MTLResourceStorageModeShared] retain];
    if (c->buf == nil) {
      [c release];
      return NULL;
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
    [c->buf release];
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
    [ce setBuffer:c->buf offset:0 atIndex:0];
    if (params != NULL && paramslen > 0)
      [ce setBytes:params length:(NSUInteger)paramslen atIndex:1];
    [ce setBytes:dims length:sizeof(dims) atIndex:2];
    NSUInteger tx = (NSUInteger)c->w < 16 ? (NSUInteger)c->w : 16;
    NSUInteger ty = (NSUInteger)c->h < 16 ? (NSUInteger)c->h : 16;
    [ce dispatchThreads:MTLSizeMake((NSUInteger)c->w, (NSUInteger)c->h, 1)
        threadsPerThreadgroup:MTLSizeMake(tx, ty, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
  }
}

void nvgmtl_upload(void *p, const unsigned char *src) {
  NvgMtlCtx *c = (NvgMtlCtx *)p;
  if (c == NULL || src == NULL) return;
  memcpy([c->buf contents], src, (size_t)(c->w * c->h * 4));
}

void nvgmtl_readback(void *p, unsigned char *dst) {
  NvgMtlCtx *c = (NvgMtlCtx *)p;
  if (c == NULL || dst == NULL) return;
  memcpy(dst, [c->buf contents], (size_t)(c->w * c->h * 4));
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
