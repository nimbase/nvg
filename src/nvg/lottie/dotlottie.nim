## dotLottie (`.lottie`) loading: a zip with `manifest.json` plus one
## animation JSON per id under `animations/`.
##
## Unzips via the `archive` package (`archive/zipfile` + `archive/io`,
## stored and deflate entries). Animation JSON parses through the normal
## `parser`; image files stay in a name-to-bytes table for
## `registerDotLottie`. `data:` URIs and external files keep working
## through `asset.registerImageAsset`.

import std/json
import std/tables
import std/strutils
import archive/zipfile
import archive/io
import ../canvas
import ../svg
import ./model
import ./parser
import ./asset

type
  DotLottie* = object
    anim*: Animation
    animId*: string
    files*: Table[string, string] ## zip path -> raw entry bytes

proc entryBytes*(r: ZipReader, name: string): string =
  ## Inflated bytes for `name` ("" when absent).
  for f in r.files:
    if not f.isDir and f.name == name:
      return readAll(entryContent(f))
  ""

proc animIdAt*(r: ZipReader, idx = 0): string =
  let m = parseJson(r.entryBytes("manifest.json"))
  let anims = m["animations"]
  if anims.kind != JArray or idx >= anims.len:
    raise newException(ValueError, "dotLottie: no animation at index " &
      $idx)
  anims[idx]["id"].getStr()

proc loadDotLottieMem*(data: string, animId = ""): DotLottie =
  ## Parse a `.lottie` archive from memory. Empty `animId` selects the
  ## first manifest entry. Raises on bad archives, missing manifest,
  ## or unknown ids.
  let r = openZip(openInputString(data))
  let id =
    if animId.len > 0: animId
    else: r.animIdAt(0)
  let blobs = block:
    var t = initTable[string, string]()
    for f in r.files:
      if not f.isDir:
        t[f.name] = readAll(entryContent(f))
    t
  if "animations/" & id & ".json" notin blobs:
    raise newException(ValueError, "dotLottie: missing animation " & id)
  result = DotLottie(animId: id, files: blobs)
  result.anim = parseAnimation(parseJson(blobs["animations/" & id &
    ".json"]))

proc loadDotLottieFile*(path: string, animId = ""): DotLottie =
  ## Like `loadDotLottieMem` but reads `path` first.
  let r = openZip(openInputFile(path))
  let id =
    if animId.len > 0: animId
    else: r.animIdAt(0)
  var blobs = initTable[string, string]()
  for f in r.files:
    if not f.isDir:
      blobs[f.name] = readAll(entryContent(f))
  if "animations/" & id & ".json" notin blobs:
    raise newException(ValueError, "dotLottie: missing animation " & id)
  result = DotLottie(animId: id, files: blobs)
  result.anim = parseAnimation(parseJson(blobs["animations/" & id &
    ".json"]))

proc isDotLottieData*(data: string): bool =
  ## Zip magic sniff (`PK\x03\x04`, empty-disk span).
  data.len >= 4 and data[0] == 'P' and data[1] == 'K' and
    data[2] == '\x03' and data[3] == '\x04'

proc registerDotLottie*(c: Canvas, lib: var AssetLib, dl: DotLottie) =
  ## Register image assets, preferring archive entries (`u` + `p` path
  ## as stored) over the filesystem. Falls back to `registerImageAsset`
  ## (data: URIs, external files) when the entry is absent.
  for a in dl.anim.assets:
    if a.kind != akImage: continue
    if lib.imageHandle(a.id) != 0: continue
    if not a.imgPath.startsWith("data:") and a.imgPath in dl.files:
      let raw = dl.files[a.imgPath]
      let w = max(1, a.imgW)
      let h = max(1, a.imgH)
      var handle = 0
      if a.imgPath.toLowerAscii().endsWith(".svg"):
        handle = c.createImageSvg(raw, w, h, {})
      else:
        handle = c.createImageMem(toBytes(raw), {})
      if handle != 0:
        lib.handles.add((a.id, handle))
        continue
    registerImageAsset(c, lib, a)
