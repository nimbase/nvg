## Text outline capture tests with the synthetic font (no binaries).
##
## Font geometry (see `fontbuilder`): gid 1 'A' is the triangle
## (0,0),(500,0),(250,700), gid 2 'B' the 400x500 square at the
## origin; upem 1000, so size 20 scales by 0.02 and flips y. Every
## verb below is derived from that geometry by hand. "BA" kerns -100
## units (-2 px at size 20).

import std/json
import std/strutils
import std/unittest
import nvg
import ./fontbuilder

proc close(a, b: float64, eps = 1e-9): bool = abs(a - b) < eps

proc cmdKinds(o: TextOutlines): seq[CommandKind] =
  for c in o.path.commands:
    result.add(c.kind)

test "single glyph outline matches the font geometry":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "A")
  let o = captureOutlines(lay, 10.0, 30.0)
  check o.path.commands.len == 4
  check cmdKinds(o) == @[pcMoveTo, pcLineTo, pcLineTo, pcClose]
  check o.path.commands[0].p.x == 10.0
  check o.path.commands[0].p.y == 30.0
  check o.path.commands[1].p.x == 20.0
  check o.path.commands[1].p.y == 30.0
  check o.path.commands[2].p.x == 15.0
  check o.path.commands[2].p.y == 16.0
  check o.groups.len == 1
  check not o.groups[0].hasColor
  check o.groups[0].first == 0
  check o.groups[0].last == 4
  check o.advance == 12.0
  check close(o.bounds.x, 10.0)
  check close(o.bounds.y, 16.0)
  check close(o.bounds.w, 10.0)
  check close(o.bounds.h, 14.0)

test "kern shifts the second glyph and advance":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "BA")
  let o = captureOutlines(lay, 0.0, 0.0)
  check o.advance == 24.0 # 14 + 12 - 2 kern
  check o.path.commands.len == 9
  check o.path.commands[5].kind == pcMoveTo
  check o.path.commands[5].p.x == 12.0
  check o.path.commands[5].p.y == 0.0

test "colored spans split into per-color groups":
  let font = loadFontBytes(buildTestFont())
  let red = rgbf(1, 0, 0)
  let blue = rgbf(0, 0, 1)
  let spans = [TextSpan(first: 0, last: 1, color: red, hasColor: true),
    TextSpan(first: 1, last: 2, color: blue, hasColor: true)]
  let lay = layoutSpans(font, 20.0, "AB", spans)
  let o = captureOutlines(lay, 0.0, 0.0)
  check o.groups.len == 2
  check o.groups[0].hasColor
  check sameColor(o.groups[0].color, red)
  check sameColor(o.groups[1].color, blue)
  check o.groups[0].first == 0
  check o.groups[1].first == o.groups[0].last
  check o.groups[1].last == o.path.commands.len

test "uncolored glyphs share one group ahead of colors":
  let font = loadFontBytes(buildTestFont())
  let blue = rgbf(0, 0, 1)
  let spans = [TextSpan(first: 1, last: 2, color: blue, hasColor: true)]
  let lay = layoutSpans(font, 20.0, "AB", spans)
  let o = captureOutlines(lay, 0.0, 0.0)
  check o.groups.len == 2
  check not o.groups[0].hasColor
  check o.groups[0].first == 0
  check o.groups[0].last == 4 # the A triangle
  check o.groups[1].first == 4

test "inline path box replays translated at its placed offset":
  let font = loadFontBytes(buildTestFont())
  var bp = Path()
  bp.moveTo(0, 0, identity())
  bp.lineTo(6, 0, identity())
  bp.lineTo(6, 10, identity())
  bp.closePath()
  let spans = [TextSpan(first: 1, last: 4,
    box: SpanBox(kind: sbkPath, path: bp, boxW: 6.0, boxH: 10.0))]
  let lay = layoutSpans(font, 20.0, "A\xE2\xBF\xBC", spans)
  let o = captureOutlines(lay, 0.0, 0.0)
  # A advance 12, box fitted 12 wide 20 tall, baseline aligned.
  check o.path.commands.len == 4 + 4
  check o.path.commands[4].p.x == 12.0
  check o.path.commands[4].p.y == -20.0
  check o.path.commands[5].p.x == 18.0
  check o.path.commands[5].p.y == -20.0
  check o.path.commands[6].p.x == 18.0
  check o.path.commands[6].p.y == -10.0
  check close(o.bounds.x + o.bounds.w, 18.0)

test "image box contributes its placed rect":
  let font = loadFontBytes(buildTestFont())
  let spans = [TextSpan(first: 1, last: 4,
    box: SpanBox(kind: sbkImage, imageId: 7, imageW: 10.0,
      imageH: 10.0))]
  let lay = layoutSpans(font, 20.0, "A\xE2\xBF\xBC", spans)
  let o = captureOutlines(lay, 0.0, 0.0)
  # Fitted 20x20 at x 12..32, y -20..0; rect verbs M/L/L/L/Z.
  check o.path.commands.len == 4 + 5
  check cmdKinds(o)[4 .. ^1] ==
    @[pcMoveTo, pcLineTo, pcLineTo, pcLineTo, pcClose]
  check o.path.commands[4].p.x == 12.0
  check o.path.commands[4].p.y == -20.0
  check close(o.bounds.x + o.bounds.w, 32.0)
  check close(o.bounds.y + o.bounds.h, 0.0)

test "box layout wraps and honors the width":
  let font = loadFontBytes(buildTestFont())
  var o = TextOutlines()
  let c = newCanvas(200, 200)
  o = c.textBoxOutlines(font, 20.0, 0.0, 0.0, 30.0, 200.0, "A B A B")
  check o.path.commands.len > 0
  check o.advance <= 30.0
  check o.bounds.w <= 30.0
  check o.groups.len == 1

test "stateful capture matches stateless under identity":
  let c = newCanvas(200, 200)
  discard c.createFontMem("t", buildTestFont())
  c.setFontFace("t")
  c.setFontSize(20.0)
  c.setTextAlign(thaLeft, tvaBaseline)
  let a = c.textOutlines(10.0, 30.0, "AB")
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "AB")
  let b = captureOutlines(lay, 10.0, 30.0, thaLeft, tvaBaseline,
    identity())
  check a.path.commands.len == b.path.commands.len
  for i, cmd in a.path.commands:
    check cmd.kind == b.path.commands[i].kind

test "svg is a full document with one path per group":
  let font = loadFontBytes(buildTestFont())
  let red = rgbf(1, 0, 0)
  let spans = [TextSpan(first: 0, last: 1, color: red, hasColor: true)]
  let lay = layoutSpans(font, 20.0, "AB", spans)
  let o = captureOutlines(lay, 5.0, 40.0)
  let doc = outlinesSvg(o)
  check doc.startsWith("<svg xmlns=")
  check "viewBox=\"5.0 26.0 20.0 14.0\"" in doc
  check doc.count("<path ") == 2
  check "fill=\"rgba(255, 0, 0, 1.0)\"" in doc
  check "fill-rule=\"nonzero\"" in doc
  check doc.endsWith("</svg>")

test "svg round trip matches fillText pixels":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "AB")
  let o = captureOutlines(lay, 5.0, 40.0)
  let doc = outlinesSvg(o)
  let surf = renderSvg(doc, 20.0, 14.0)
  check surf != nil
  check surf.w == 20
  check surf.h == 14
  let c = newCanvas(60, 60)
  c.clear(rgbaf(0, 0, 0, 0))
  c.setFillColor(rgbf(0, 0, 0))
  discard c.fillText(font, 20.0, 5.0, 40.0, "AB")
  var maxDiff = 0
  for y in 0 ..< 14:
    for x in 0 ..< 20:
      let i = ((26 + y) * 60 + (5 + x)) * 4
      let j = (y * 20 + x) * 4
      for k in 0 ..< 4:
        maxDiff = max(maxDiff,
          abs(int(c.surface.pixels[i + k]) - int(surf.pixels[j + k])))
  check maxDiff == 0

test "json envelope carries anchor, advance and verb groups":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "A")
  let o = captureOutlines(lay, 10.0, 30.0)
  let node = parseJson($outlinesJson(o))
  check node["x"].getFloat() == 10.0
  check node["y"].getFloat() == 30.0
  check node["advance"].getFloat() == 12.0
  check node["fillRule"].getStr() == "nonzero"
  check node["bounds"]["w"].getFloat() == 10.0
  check node["bounds"]["h"].getFloat() == 14.0
  check node["groups"].len == 1
  check node["groups"][0]["color"].kind == JNull
  let verbs = node["groups"][0]["path"]
  check verbs.len == 4
  check verbs[0]["op"].getStr() == "M"
  check verbs[0]["x"].getFloat() == 10.0
  check verbs[1]["op"].getStr() == "L"
  check verbs[3]["op"].getStr() == "Z"

test "decor option appends an underline rect ahead of the ink":
  let font = loadFontBytes(buildTestFont())
  let plain = TextBoxOpts(maxW: 200)
  let under = TextBoxOpts(maxW: 200, decor: tdUnderline)
  let c = newCanvas(200, 200)
  let a = c.textBoxOutlines(font, 20.0, 0.0, 0.0, "AB", plain)
  let b = c.textBoxOutlines(font, 20.0, 0.0, 0.0, "AB", under)
  check b.path.commands.len == a.path.commands.len + 5
  # Decor verbs lead (indices 0..4): rect(0, uy, 20, 1.25) where
  # uy is the tvaTop shift (13.984375; extents quantize to 1/64)
  # plus desc 0 plus max(1, 20*0.06).
  check cmdKinds(b)[0 .. 4] ==
    @[pcMoveTo, pcLineTo, pcLineTo, pcLineTo, pcClose]
  check close(b.path.commands[0].p.x, 0.0)
  check close(b.path.commands[0].p.y, 15.184375)
  check close(b.path.commands[2].p.x, 20.0)
  check close(b.path.commands[2].p.y, 16.434375)

test "empty text captures nothing but stays valid":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "")
  let o = captureOutlines(lay, 7.0, 9.0)
  check o.path.commands.len == 0
  check o.groups.len == 0
  check o.advance == 0.0
  let doc = outlinesSvg(o)
  check doc.startsWith("<svg ")
  check doc.endsWith("</svg>")
  check "<path " notin doc
  let node = parseJson($outlinesJson(o))
  check node["groups"].len == 0
