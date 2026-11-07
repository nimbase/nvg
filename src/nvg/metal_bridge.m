// See metal_bridge.h. Manual retain/release (MRC): this file must also
// work when the host build does not enable ARC.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "metal_bridge.h"
#include <string.h>

@interface NvgMtlCtx : NSObject {
@public
  id<MTLDevice> dev;
  id<MTLCommandQueue> queue;
  id<MTLComputePipelineState> fillSolid;
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
    c->fillSolid = nil;
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
    [c->fillSolid release];
    [c->buf release];
    [c release];
  }
}

int nvgmtl_build_solid(void *p, const char *src, int len) {
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    if (c == NULL || src == NULL || len <= 0) return -1;
    NSString *s = [[NSString alloc] initWithBytes:src
                                           length:(NSUInteger)len
                                         encoding:NSUTF8StringEncoding];
    if (s == nil) return -2;
    NSError *err = nil;
    id<MTLLibrary> lib = [c->dev newLibraryWithSource:s options:nil error:&err];
    [s release];
    if (lib == nil) return -3;
    id<MTLFunction> fn = [lib newFunctionWithName:@"fill_solid"];
    [lib release];
    if (fn == nil) return -4;
    id<MTLComputePipelineState> ps =
        [c->dev newComputePipelineStateWithFunction:fn error:&err];
    [fn release];
    if (ps == nil) return -5;
    [c->fillSolid release];
    c->fillSolid = [ps retain];
    [ps release];
    return 0;
  }
}

void nvgmtl_fill_solid(void *p, float r, float g, float b, float a) {
  @autoreleasepool {
    NvgMtlCtx *c = (NvgMtlCtx *)p;
    if (c == NULL || c->fillSolid == nil) return;
    float col[4] = {r, g, b, a};
    uint32_t dims[2] = {(uint32_t)c->w, (uint32_t)c->h};
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:c->fillSolid];
    [ce setBuffer:c->buf offset:0 atIndex:0];
    [ce setBytes:col length:sizeof(col) atIndex:1];
    [ce setBytes:dims length:sizeof(dims) atIndex:2];
    NSUInteger n = (NSUInteger)(c->w * c->h);
    NSUInteger tg = n < 256 ? n : 256;
    [ce dispatchThreads:MTLSizeMake(n, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
  }
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
