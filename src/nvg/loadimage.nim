## File-backed image decoding via the workspace `image` package.
##
## `decodeRgba8` sniffs magic bytes and decodes PNG, JPEG, BMP, GIF
## (first frame), QOI, PNM, or TGA into flat straight-alpha RGBA8 —
## the exact upload layout `images.newImage` takes. Anything else
## (unknown magic, truncated data, unwired formats like WebP/TIFF) is
## a clean `ok = false`, never an exception. Only the needed codec
## submodules are imported so everyday builds stay fast.

import image/reader
import image/format
import image/dynamic
import image/buffer
import image/codecs/png
import image/codecs/jpeg
import image/codecs/bmp
import image/codecs/gif
import image/codecs/qoi
import image/codecs/pnm
import image/codecs/tga

proc pushPx(outP: var seq[uint8], r, g, b, a: uint8) =
  outP.add(r)
  outP.add(g)
  outP.add(b)
  outP.add(a)

proc checkDims(w, h: uint32, n: int): bool =
  w > 0 and h > 0 and uint64(w) * uint64(h) == uint64(n)

proc dynamicToRgba8*(img: DynamicImage):
    tuple[ok: bool, w, h: int, pixels: seq[uint8]] =
  ## Flatten any 8/16-bit integer variant to RGBA8. Float (HDR) variants
  ## cannot arise from the wired codecs and are rejected.
  case img.kind
  of dkRgba8:
    let s = img.rgba8
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP = newSeq[uint8](s.pixels.len * 4)
    for i, p in s.pixels:
      outP[i * 4] = p.data[0]
      outP[i * 4 + 1] = p.data[1]
      outP[i * 4 + 2] = p.data[2]
      outP[i * 4 + 3] = p.data[3]
    (true, int(s.width), int(s.height), outP)
  of dkRgb8:
    let s = img.rgb8
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      outP.pushPx(p.data[0], p.data[1], p.data[2], 255u8)
    (true, int(s.width), int(s.height), outP)
  of dkLuma8:
    let s = img.luma8
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      outP.pushPx(p.data[0], p.data[0], p.data[0], 255u8)
    (true, int(s.width), int(s.height), outP)
  of dkLumaA8:
    let s = img.lumaA8
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      outP.pushPx(p.data[0], p.data[0], p.data[0], p.data[1])
    (true, int(s.width), int(s.height), outP)
  of dkRgba16:
    let s = img.rgba16
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      outP.pushPx(uint8(int(p.data[0]) div 257),
        uint8(int(p.data[1]) div 257), uint8(int(p.data[2]) div 257),
        uint8(int(p.data[3]) div 257))
    (true, int(s.width), int(s.height), outP)
  of dkRgb16:
    let s = img.rgb16
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      outP.pushPx(uint8(int(p.data[0]) div 257),
        uint8(int(p.data[1]) div 257), uint8(int(p.data[2]) div 257),
        255u8)
    (true, int(s.width), int(s.height), outP)
  of dkLuma16:
    let s = img.luma16
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      let v = uint8(int(p.data[0]) div 257)
      outP.pushPx(v, v, v, 255u8)
    (true, int(s.width), int(s.height), outP)
  of dkLumaA16:
    let s = img.lumaA16
    if not checkDims(s.width, s.height, s.pixels.len):
      return (false, 0, 0, @[])
    var outP: seq[uint8] = @[]
    for p in s.pixels:
      let v = uint8(int(p.data[0]) div 257)
      outP.pushPx(v, v, v, uint8(int(p.data[1]) div 257))
    (true, int(s.width), int(s.height), outP)
  else:
    (false, 0, 0, @[])

proc decodeRgba8*(data: openArray[uint8]):
    tuple[ok: bool, w, h: int, pixels: seq[uint8]] =
  ## Decode `data` (format sniffed) to flat RGBA8. Never raises.
  if data.len == 0:
    return (false, 0, 0, @[])
  var bytes = newSeq[uint8](data.len)
  for i, b in data:
    bytes[i] = b
  let (found, fmt) = guessFormat(bytes)
  if not found:
    return (false, 0, 0, @[])
  case fmt
  of fmtPng:
    let r = decodePng(bytes)
    if not r.ok:
      return (false, 0, 0, @[])
    dynamicToRgba8(r.value)
  of fmtJpeg:
    let r = decodeJpeg(bytes)
    if not r.ok:
      return (false, 0, 0, @[])
    dynamicToRgba8(r.value)
  of fmtBmp:
    let r = decodeBmp(bytes)
    if not r.ok:
      return (false, 0, 0, @[])
    dynamicToRgba8(r.value)
  of fmtTga:
    let r = decodeTga(bytes)
    if not r.ok:
      return (false, 0, 0, @[])
    dynamicToRgba8(r.value)
  of fmtPnm:
    let r = decodePnm(bytes)
    if not r.ok:
      return (false, 0, 0, @[])
    dynamicToRgba8(r.value)
  of fmtQoi:
    let r = decodeQoi(bytes)
    if not r.ok:
      return (false, 0, 0, @[])
    dynamicToRgba8(DynamicImage(kind: dkRgba8, rgba8: r.value))
  of fmtGif:
    let g = decodeGif(bytes)
    if not g.ok or g.value.frames.len == 0:
      return (false, 0, 0, @[])
    let fr = gifFrameToRgba(g.value, 0)
    if not fr.ok:
      return (false, 0, 0, @[])
    # Composite frame 0 over a transparent full-canvas buffer.
    let cw = int(g.value.width)
    let ch = int(g.value.height)
    let fw = int(fr.value.width)
    let fh = int(fr.value.height)
    if not checkDims(uint32(cw), uint32(ch), cw * ch):
      return (false, 0, 0, @[])
    let ox = min(int(g.value.frames[0].left), cw)
    let oy = min(int(g.value.frames[0].top), ch)
    var px = newSeq[uint8](cw * ch * 4)
    for y in 0 ..< fh:
      if oy + y >= ch:
        break
      for x in 0 ..< fw:
        if ox + x >= cw:
          break
        let p = fr.value.pixels[y * fw + x]
        let o = ((oy + y) * cw + (ox + x)) * 4
        px[o] = p.data[0]
        px[o + 1] = p.data[1]
        px[o + 2] = p.data[2]
        px[o + 3] = p.data[3]
    (true, cw, ch, px)
  else:
    (false, 0, 0, @[])
