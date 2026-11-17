## SVG loading tests with hand-written documents (no binaries).
##
## Every expectation is derived from the SVG source by hand: solid
## geometry, viewBox scaling, path winding, gradients, opacity and
## error cases.

import std/strutils
import std/unittest
import nvg

test "svg red rect on white":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<rect x=\"5\" y=\"5\" width=\"10\" height=\"10\" fill=\"red\"/>" &
    "</svg>")
  check s != nil
  check s.w == 20
  check s.h == 20
  check s.getPixel(0, 0).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(10, 10).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(19, 19).toRgba8() == (255u8, 255u8, 255u8, 255u8)

test "svg circle with translate":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<g transform=\"translate(10 0)\">" &
    "<circle cx=\"5\" cy=\"10\" r=\"4\" fill=\"blue\"/>" &
    "</g></svg>")
  check s != nil
  check s.getPixel(15, 10).toRgba8() == (0u8, 0u8, 255u8, 255u8)
  check s.getPixel(5, 10).toRgba8() == (255u8, 255u8, 255u8, 255u8)

test "svg scale widens geometry":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<g transform=\"scale(2)\">" &
    "<rect width=\"5\" height=\"5\" fill=\"red\"/>" &
    "</g></svg>")
  check s != nil
  check s.getPixel(9, 9).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(10, 10).toRgba8() == (255u8, 255u8, 255u8, 255u8)

test "svg viewBox scales to output":
  let s = renderSvg(
    "<svg viewBox=\"0 0 10 10\">" &
    "<rect width=\"10\" height=\"10\" fill=\"red\"/>" &
    "</svg>", 20.0, 20.0)
  check s != nil
  check s.w == 20
  check s.h == 20
  check s.getPixel(10, 10).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(19, 19).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  # One-sided size keeps the aspect (square here).
  let tall = renderSvg("<svg viewBox=\"0 0 10 10\">" &
    "<rect width=\"10\" height=\"10\" fill=\"red\"/></svg>", 30.0)
  check tall != nil
  check tall.w == 30
  check tall.h == 30

test "svg path triangle":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<path d=\"M0 0 L20 0 L10 20 Z\" fill=\"red\"/>" &
    "</svg>")
  check s != nil
  check s.getPixel(10, 5).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(0, 19).toRgba8() == (255u8, 255u8, 255u8, 255u8)

test "svg evenodd cuts a hole, nonzero fills it":
  const doc = "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<path d=\"M2 2 H18 V18 H2 Z M6 6 H14 V14 H6 Z\" fill=\"red\" " &
    "fill-rule=\"FILL\"/></svg>"
  let eo = renderSvg(doc.replace("FILL", "evenodd"))
  check eo != nil
  check eo.getPixel(4, 4).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check eo.getPixel(10, 10).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  let nz = renderSvg(doc.replace("FILL", "nonzero"))
  check nz != nil
  check nz.getPixel(10, 10).toRgba8() == (255u8, 0u8, 0u8, 255u8)

test "svg stroke line":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<line x1=\"0\" y1=\"10\" x2=\"20\" y2=\"10\" stroke=\"red\" " &
    "stroke-width=\"2\"/></svg>")
  check s != nil
  check s.getPixel(10, 10).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(10, 0).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(10, 12).toRgba8() == (255u8, 255u8, 255u8, 255u8)

test "svg linear gradient user space":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<defs><linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" " &
    "x1=\"0\" y1=\"0\" x2=\"20\" y2=\"0\">" &
    "<stop offset=\"0\" stop-color=\"red\"/>" &
    "<stop offset=\"1\" stop-color=\"blue\"/>" &
    "</linearGradient></defs>" &
    "<rect width=\"20\" height=\"20\" fill=\"url(#g)\"/>" &
    "</svg>")
  check s != nil
  let l = s.getPixel(0, 10).toRgba8()
  let r = s.getPixel(19, 10).toRgba8()
  check l[0] > l[2]
  check r[2] > r[0]

test "svg gradient object bounding box default":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<defs><linearGradient id=\"g\">" &
    "<stop offset=\"0\" stop-color=\"red\"/>" &
    "<stop offset=\"1\" stop-color=\"blue\"/>" &
    "</linearGradient></defs>" &
    "<rect x=\"5\" y=\"5\" width=\"10\" height=\"10\" " &
    "fill=\"url(#g)\"/></svg>")
  check s != nil
  let l = s.getPixel(5, 10).toRgba8()
  let r = s.getPixel(14, 10).toRgba8()
  check l[0] > l[2]
  check r[2] > r[0]
  check s.getPixel(0, 0).toRgba8() == (255u8, 255u8, 255u8, 255u8)

test "svg fill opacity blends over background":
  let s = renderSvg(
    "<svg width=\"20\" height=\"20\">" &
    "<rect width=\"20\" height=\"20\" fill=\"white\"/>" &
    "<rect width=\"20\" height=\"20\" fill=\"red\" " &
    "fill-opacity=\"0.5\"/></svg>")
  check s != nil
  check s.getPixel(10, 10).toRgba8() == (255u8, 128u8, 128u8, 255u8)

test "svg missing fill paints black, missing stroke paints nothing":
  let s = renderSvg("<svg width=\"4\" height=\"4\">" &
    "<rect width=\"4\" height=\"4\"/></svg>")
  check s != nil
  check s.getPixel(2, 2).toRgba8() == (0u8, 0u8, 0u8, 255u8)

test "svg malformed returns nil":
  check renderSvg("") == nil
  check renderSvg("<svg>") == nil
  check renderSvg("<html/>") == nil
  check renderSvg("<svg></svg>") == nil
  check renderSvg("<svg width=\"-4\" height=\"0\"></svg>") == nil
  let (w, h, ok) = svgSize(
    "<svg width=\"40\" height=\"30\"></svg>")
  check ok
  check w == 40.0
  check h == 30.0
  let (vw, vh, vok) = svgSize("<svg viewBox=\"0 0 8 6\"></svg>")
  check vok
  check vw == 8.0
  check vh == 6.0
  check not svgSize("<html/>")[2]

test "svg registry upload reports size":
  let c = newCanvas(8, 8)
  let id = c.createImageSvg(
    "<svg width=\"8\" height=\"8\">" &
    "<rect width=\"8\" height=\"8\" fill=\"red\"/></svg>", 8, 8, {})
  check id != 0
  check c.imageSize(id) == (8, 8, true)
  check c.createImageSvg("<svg>", 8, 8, {}) == 0
  check c.createImageSvg(
    "<svg width=\"8\" height=\"8\"/>", 0, 8, {}) == 0
