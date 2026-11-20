## Image assets: registry of file-backed images for image layers.
##
## Raster bytes (PNG/JPEG/BMP/GIF/QOI/PNM/TGA) decode through
## `createImageMem/File`. SVG payloads (`.svg` files or `data:` URIs with
## an SVG mime) rasterize through `nvg`'s SVG module at the asset size,
## so vector assets need no new code. Unknown files register nothing
## (handle 0) and their layers are skipped at render.

import std/base64
import std/os
import std/strutils
import ../canvas
import ../svg
import ./model

type
  AssetLib* = object
    baseDir*: string
    handles*: seq[tuple[id: string, handle: int]]

proc imageHandle*(lib: AssetLib, id: string): int =
  for e in lib.handles:
    if e.id == id: return e.handle
  0

proc toBytes*(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc registerImageAsset*(c: Canvas, lib: var AssetLib, a: Asset) =
  ## Decode `a` into the canvas registry: file path relative to
  ## `baseDir` (or absolute), or a `data:` URI (base64 or raw). SVG
  ## goes through the SVG module at the asset size.
  if a.kind != akImage: return
  if lib.imageHandle(a.id) != 0: return
  let w = max(1, a.imgW)
  let h = max(1, a.imgH)
  var handle = 0
  if a.imgPath.startsWith("data:"):
    let comma = a.imgPath.find(',')
    if comma >= 0:
      let meta = a.imgPath[0 ..< comma]
      let payload = a.imgPath[comma + 1 .. ^1]
      let isSvg = meta.contains("svg")
      if meta.contains("base64"):
        try:
          let raw = decode(payload)
          if isSvg:
            handle = c.createImageSvg(raw, w, h, {})
          else:
            handle = c.createImageMem(toBytes(raw), {})
        except CatchableError:
          handle = 0
      elif isSvg:
        handle = c.createImageSvg(payload, w, h, {})
      else:
        handle = c.createImageMem(toBytes(payload), {})
  elif a.imgPath.len > 0:
    let p = if isAbsolute(a.imgPath): a.imgPath
      else: lib.baseDir / a.imgPath
    if p.toLowerAscii().endsWith(".svg"):
      handle = c.createImageSvgFile(p, w, h, {})
    else:
      handle = c.createImageFile(p, {})
  if handle != 0:
    lib.handles.add((a.id, handle))

proc registerAll*(c: Canvas, lib: var AssetLib, anim: Animation,
    baseDir = "") =
  lib.baseDir = baseDir
  for a in anim.assets:
    registerImageAsset(c, lib, a)
