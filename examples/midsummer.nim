## Book-like A4 portrait setting of Shakespeare's
## *A Midsummer Night's Dream*, Act II, Scene 1
## (text: Open Source Shakespeare, public domain).
##
## One title block plus running body pages: centered title with its
## baseline guide and spec label, body verse set left with a faint
## baseline rule per line, margin and text-block frames, and a footer
## carrying the page spec. Pass --no-guides for the clean print look.
##
## Run: nim c -r examples/midsummer.nim -- /path/to/font.ttf [outDir] [--no-guides]
## The font path can also come from the TEXT_FONT environment variable.

import std/os
import std/strutils
import nvg

# --- Page geometry: A4 portrait at 96 dpi. ---
const
  PageW = 794.0
  PageH = 1123.0
  Cx = PageW * 0.5
  MarginOuter = 84.0
  BlockX = 122.0
  BlockW = PageW - 2 * BlockX
  BodySize = 20.0
  BodyLH = 1.4
  Leading = BodySize * BodyLH # 28.0
  TitleSize = 52.0
  TitleLH = 1.12
  TitleLeading = TitleSize * TitleLH # 58.2
  SpeakerSize = 18.0
  SpeakerLH = 1.4
  SpeakerLeading = SpeakerSize * SpeakerLH # 25.2
  StageSize = 18.0
  StageLH = 1.4
  StageLeading = StageSize * StageLH # 25.2
  FootY = PageH - 52.0

type
  Kind = enum
    kStage, kSpeaker, kVerse

  Entry = tuple[kind: Kind, text: string]

# Excerpt: Act II, Scene 1, from Puck's entrance through his exit
# (line numbers of the edition stripped).
const Scene: seq[Entry] = @[
  (kStage, "[Enter, from opposite sides, a Fairy, and PUCK]"),
  (kSpeaker, "PUCK"),
  (kVerse, "How now, spirit! whither wander you?"),
  (kSpeaker, "FAIRY"),
  (kVerse, "Over hill, over dale,"),
  (kVerse, "Thorough bush, thorough brier,"),
  (kVerse, "Over park, over pale,"),
  (kVerse, "Thorough flood, thorough fire,"),
  (kVerse, "I do wander everywhere,"),
  (kVerse, "Swifter than the moon's sphere;"),
  (kVerse, "And I serve the fairy queen,"),
  (kVerse, "To dew her orbs upon the green."),
  (kVerse, "The cowslips tall her pensioners be:"),
  (kVerse, "In their gold coats spots you see;"),
  (kVerse, "Those be rubies, fairy favours,"),
  (kVerse, "In those freckles live their savours:"),
  (kVerse, "I must go seek some dewdrops here"),
  (kVerse, "And hang a pearl in every cowslip's ear."),
  (kVerse, "Farewell, thou lob of spirits; I'll be gone:"),
  (kVerse, "Our queen and all our elves come here anon."),
  (kSpeaker, "PUCK"),
  (kVerse, "The king doth keep his revels here to-night:"),
  (kVerse, "Take heed the queen come not within his sight;"),
  (kVerse, "For Oberon is passing fell and wrath,"),
  (kVerse, "Because that she as her attendant hath"),
  (kVerse, "A lovely boy, stolen from an Indian king;"),
  (kVerse, "She never had so sweet a changeling;"),
  (kVerse, "And jealous Oberon would have the child"),
  (kVerse, "Knight of his train, to trace the forests wild;"),
  (kVerse, "But she perforce withholds the loved boy,"),
  (kVerse, "Crowns him with flowers and makes him all her joy."),
  (kSpeaker, "FAIRY"),
  (kVerse, "Either I mistake your shape and making quite,"),
  (kVerse, "Or else you are that shrewd and knavish sprite"),
  (kVerse, "Call'd Robin Goodfellow: are not you he"),
  (kVerse, "That frights the maidens of the villagery?"),
  (kVerse, "Those that Hobgoblin call you and sweet Puck,"),
  (kVerse, "You do their work, and they shall have good luck:"),
  (kVerse, "Are not you he?"),
  (kSpeaker, "PUCK"),
  (kVerse, "Thou speak'st aright;"),
  (kVerse, "I am that merry wanderer of the night."),
  (kVerse, "I jest to Oberon and make him smile"),
  (kVerse, "When I a fat and bean-fed horse beguile,"),
  (kVerse, "Neighing in likeness of a filly foal:"),
  (kVerse, "And sometime lurk I in a gossip's bowl,"),
  (kVerse, "In very likeness of a roasted crab,"),
  (kVerse, "And when she drinks, against her lips I bob"),
  (kVerse, "And on her wither'd dewlap pour the ale."),
  (kVerse, "But, room, fairy! here comes Oberon."),
  (kSpeaker, "FAIRY"),
  (kVerse, "And here my mistress. Would that he were gone!"),
  (kStage, "[Enter OBERON with his train; TITANIA with hers]"),
  (kSpeaker, "OBERON"),
  (kVerse, "Ill met by moonlight, proud Titania."),
  (kSpeaker, "TITANIA"),
  (kVerse, "What, jealous Oberon! Fairies, skip hence:"),
  (kVerse, "I have forsworn his bed and company."),
  (kSpeaker, "OBERON"),
  (kVerse, "Tarry, rash wanton: am not I thy lord?"),
  (kSpeaker, "TITANIA"),
  (kVerse, "Then I must be thy lady: but I know"),
  (kVerse, "When thou hast stolen away from fairy land,"),
  (kVerse, "And in the shape of Corin sat all day,"),
  (kVerse, "Playing on pipes of corn and versing love"),
  (kVerse, "To amorous Phillida. Why art thou here,"),
  (kVerse, "Come from the farthest Steppes of India?"),
  (kVerse, "These are the forgeries of jealousy:"),
  (kVerse, "And never, since the middle summer's spring,"),
  (kVerse, "Met we on hill, in dale, forest or mead,"),
  (kVerse, "By paved fountain or by rushy brook,"),
  (kVerse, "Or in the beached margent of the sea,"),
  (kVerse, "To dance our ringlets to the whistling wind,"),
  (kVerse, "But with thy brawls thou hast disturb'd our sport."),
  (kVerse, "Therefore the winds, piping to us in vain,"),
  (kVerse, "As in revenge, have suck'd up from the sea"),
  (kVerse, "Contagious fogs; which falling in the land"),
  (kVerse, "Have every pelting river made so proud"),
  (kVerse, "That they have overborne their continents."),
  (kSpeaker, "OBERON"),
  (kVerse, "Do you amend it then; it lies in you:"),
  (kVerse, "Why should Titania cross her Oberon?"),
  (kVerse, "I do but beg a little changeling boy,"),
  (kVerse, "To be my henchman."),
  (kSpeaker, "TITANIA"),
  (kVerse, "Set your heart at rest:"),
  (kVerse, "The fairy land buys not the child of me."),
  (kVerse, "But she, being mortal, of that boy did die;"),
  (kVerse, "And for her sake do I rear up her boy,"),
  (kVerse, "And for her sake I will not part with him."),
  (kVerse, "Not for thy fairy kingdom. Fairies, away!"),
  (kVerse, "We shall chide downright, if I longer stay."),
  (kStage, "[Exit TITANIA with her train]"),
  (kSpeaker, "OBERON"),
  (kVerse, "Well, go thy way: thou shalt not from this grove"),
  (kVerse, "Till I torment thee for this injury."),
  (kVerse, "My gentle Puck, come hither. Thou rememberest"),
  (kVerse, "Since once I sat upon a promontory,"),
  (kVerse, "And heard a mermaid on a dolphin's back"),
  (kVerse, "Uttering such dulcet and harmonious breath"),
  (kVerse, "That the rude sea grew civil at her song."),
  (kSpeaker, "PUCK"),
  (kVerse, "I'll put a girdle round about the earth"),
  (kVerse, "In forty minutes."),
  (kStage, "[Exit]"),
]

const
  Ink = (0.12, 0.11, 0.10)
  SoftInk = (0.35, 0.33, 0.30)
  SpeakerInk = (0.45, 0.12, 0.10)
  GuideRed = (0.85, 0.25, 0.25, 0.55)
  GuideBlue = (0.25, 0.45, 0.90, 0.55)
  GuideGrey = (0.45, 0.45, 0.45)
  Paper = (0.992, 0.980, 0.961)

proc setCol(c: Canvas, t: tuple[r, g, b: float64]) =
  c.setFillColor(rgbf(t.r, t.g, t.b))
  c.setStrokeColor(rgbf(t.r, t.g, t.b))

proc hline(c: Canvas, x0, x1, y: float64) =
  c.beginPath()
  c.moveTo(x0, y)
  c.lineTo(x1, y)
  c.stroke()

proc frame(c: Canvas, x, y, w, h: float64) =
  c.beginPath()
  c.rect(x, y, w, h)
  c.stroke()

proc spec(c: Canvas, y: float64, s: string) =
  ## Small grey info label, right-anchored in the outer margin gutter.
  c.setFontSize(11.0)
  c.setTextAlign(thaRight, tvaBaseline)
  c.setLetterSpacing(0.5)
  c.setLineHeight(1.2)
  c.setFillColor(rgbf(GuideGrey[0], GuideGrey[1], GuideGrey[2]))
  discard c.fillText(PageW - 8, y, s)

proc wrap(c: Canvas, s: string, maxW: float64): seq[string] =
  ## Greedy word wrap measured with the current state font.
  result = @[]
  var line = ""
  for w in s.split(' '):
    let trial = if line == "": w else: line & " " & w
    if c.textBounds(0, 0, trial).w <= maxW or line == "":
      line = trial
    else:
      result.add(line)
      line = w
  if line != "":
    result.add(line)

proc entrySize(e: Entry): float64 =
  case e.kind
  of kStage: StageSize
  of kSpeaker: SpeakerSize
  of kVerse: BodySize

proc entryLeading(e: Entry): float64 =
  case e.kind
  of kStage: StageLeading
  of kSpeaker: SpeakerLeading
  of kVerse: Leading

proc fitSize(c: Canvas, s: string, start: float64, maxW: float64): float64 =
  ## Largest size at or below `start` whose ink fits `maxW`.
  result = start
  c.setFontSize(result)
  while result > 8.0 and c.textBounds(0, 0, s).w > maxW:
    result -= 1.0
    c.setFontSize(result)

proc drawTitle(c: Canvas, guides: bool) =
  ## Centered title block with baseline guide and spec label.
  c.setTextAlign(thaCenter, tvaBaseline)
  c.setLetterSpacing(0.0)
  c.setLineHeight(TitleLH)
  let tsize = c.fitSize("A Midsummer Night's Dream", TitleSize, BlockW)
  let ty = 176.0
  setCol(c, Ink)
  discard c.fillText(Cx, ty, "A Midsummer Night's Dream")
  if guides:
    c.setStrokeColor(rgbaf(GuideRed[0], GuideRed[1], GuideRed[2],
      GuideRed[3]))
    c.setStrokeWidth(1.0)
    c.hline(BlockX, BlockX + BlockW, ty)
    c.setStrokeColor(rgbaf(GuideBlue[0], GuideBlue[1], GuideBlue[2],
      GuideBlue[3]))
    c.frame(BlockX, ty - tsize, BlockW, tsize)
    c.spec(ty, "title " & formatFloat(tsize, ffDecimal, 0) & " / " &
      $TitleLH & " = " & formatFloat(tsize * TitleLH, ffDecimal, 1))
  c.setLineHeight(1.3)
  let ssize = c.fitSize("Act II, Scene 1  ·  A wood near Athens", 23.0,
    BlockW)
  c.setTextAlign(thaCenter, tvaBaseline)
  c.setFillColor(rgbf(SoftInk[0], SoftInk[1], SoftInk[2]))
  let sy = ty + 52.0
  discard c.fillText(Cx, sy, "Act II, Scene 1  ·  A wood near Athens")
  if guides:
    c.setStrokeColor(rgbaf(GuideRed[0], GuideRed[1], GuideRed[2],
      GuideRed[3]))
    c.hline(BlockX, BlockX + BlockW, sy)
    c.spec(sy, "subtitle " & formatFloat(ssize, ffDecimal, 0) &
      " / 1.3")
  # Rule under the title block.
  c.setStrokeColor(rgbf(SoftInk[0], SoftInk[1], SoftInk[2]))
  c.setStrokeWidth(1.0)
  c.hline(Cx - 90, Cx + 90, sy + 30.0)

proc drawFooter(c: Canvas, page, pages: int) =
  c.setFontSize(13.0)
  c.setLineHeight(1.2)
  c.setLetterSpacing(1.0)
  c.setTextAlign(thaCenter, tvaBaseline)
  c.setFillColor(rgbf(SoftInk[0], SoftInk[1], SoftInk[2]))
  discard c.fillText(Cx, FootY,
    "A Midsummer Night's Dream  ·  Act II, Scene 1  ·  " & $page &
    " / " & $pages)
  c.setTextAlign(thaCenter, tvaBaseline)
  c.setLetterSpacing(0.5)
  discard c.fillText(Cx, FootY + 18,
    "A4 portrait 794x1123  ·  margins 122  ·  body " & $int(BodySize) &
    " / " & $BodyLH & " = " & formatFloat(Leading, ffDecimal, 1) &
    "px leading")

proc drawPageFrames(c: Canvas) =
  c.setStrokeColor(rgbaf(GuideBlue[0], GuideBlue[1], GuideBlue[2], 0.35))
  c.setStrokeWidth(1.0)
  c.frame(MarginOuter, MarginOuter, PageW - 2 * MarginOuter,
    PageH - 2 * MarginOuter)
  c.setStrokeColor(rgbaf(GuideBlue[0], GuideBlue[1], GuideBlue[2], 0.55))
  c.frame(BlockX, MarginOuter, BlockW, PageH - 2 * MarginOuter)

proc drawBodyLine(c: Canvas, e: Entry, line: string, baselineY: float64,
    guides: bool, first: bool) =
  ## One physical line: baseline guide, then the text itself.
  if guides:
    c.setStrokeColor(rgbaf(GuideRed[0], GuideRed[1], GuideRed[2],
      GuideRed[3]))
    c.setStrokeWidth(1.0)
    c.hline(BlockX, BlockX + BlockW, baselineY)
  let indent = if first: 0.0 else: 26.0
  case e.kind
  of kVerse:
    c.setFontSize(BodySize)
    c.setLineHeight(BodyLH)
    c.setLetterSpacing(0.0)
    c.setTextAlign(thaLeft, tvaBaseline)
    setCol(c, Ink)
    discard c.fillText(BlockX + indent, baselineY, line)
  of kSpeaker:
    c.setFontSize(SpeakerSize)
    c.setLineHeight(SpeakerLH)
    c.setLetterSpacing(3.0)
    c.setTextAlign(thaLeft, tvaBaseline)
    c.setFillColor(rgbf(SpeakerInk[0], SpeakerInk[1], SpeakerInk[2]))
    discard c.fillText(BlockX + indent, baselineY, line)
  of kStage:
    c.setFontSize(StageSize)
    c.setLineHeight(StageLH)
    c.setLetterSpacing(0.0)
    c.setTextAlign(thaCenter, tvaBaseline)
    c.setFillColor(rgbf(SoftInk[0], SoftInk[1], SoftInk[2]))
    discard c.fillText(Cx, baselineY, line)

proc drawBodySpec(c: Canvas, y: float64) =
  c.spec(y, "body " & $int(BodySize) & " / " & $BodyLH & " = " &
    formatFloat(Leading, ffDecimal, 1))

proc main(fontPath, outDir: string, guides: bool) =
  createDir(outDir)
  # Wrap every entry once; pagination then works on physical lines.
  let wc = newCanvas(8, 8)
  discard wc.createFont("body", fontPath)
  wc.setFontFace("body")
  wc.setFontSize(BodySize)
  wc.setLineHeight(BodyLH)
  var wrapped: seq[tuple[e: Entry, lines: seq[string]]] = @[]
  for e in Scene:
    wc.setFontSize(entrySize(e))
    wrapped.add((e, wc.wrap(e.text, BlockW)))

  # Paginate: page 1 starts below the title block, rest at the top.
  const bodyTop1 = 330.0
  const bodyTopN = 130.0
  const bodyBottom = FootY - 44.0
  var pages: seq[seq[tuple[e: Entry, line: string, first: bool]]] = @[]
  var cur: seq[tuple[e: Entry, line: string, first: bool]] = @[]
  var y = bodyTop1
  var firstPage = true
  for w in wrapped:
    for li, ln in w.lines:
      let lead = w.e.entryLeading()
      if y + lead * 0.35 > bodyBottom:
        pages.add(cur)
        cur = @[]
        y = bodyTopN
        firstPage = false
      y += lead
      cur.add((w.e, ln, li == 0))
      # Speaker breathing room: extra half leading after the name.
      if w.e.kind == kSpeaker and w.lines.len == 1:
        y += SpeakerLeading * 0.35
  if cur.len > 0:
    pages.add(cur)

  let c = newCanvas(int(PageW), int(PageH))
  let id = c.createFont("body", fontPath)
  if id == 0:
    quit "cannot load font: " & fontPath
  c.setFontFace("body")

  for pi, lines in pages:
    c.clear(rgbf(Paper[0], Paper[1], Paper[2]))
    if guides:
      c.drawPageFrames()
    if pi == 0:
      c.drawTitle(guides)
      y = bodyTop1
    else:
      y = bodyTopN
    if guides and lines.len > 0:
      c.drawBodySpec(y - entryLeading(lines[0].e) + 13.0)
    for ln in lines:
      y += ln.e.entryLeading()
      c.drawBodyLine(ln.e, ln.line, y, guides, ln.first)
    c.drawFooter(pi + 1, pages.len)
    let name = "midsummer_p" & align($ (pi + 1), 2, '0') & ".png"
    c.savePng(outDir / name)
    echo "wrote ", outDir / name, "  (", lines.len, " lines)"

when isMainModule:
  var fontPath = getEnv("TEXT_FONT")
  var outDir = "examples/out"
  var guides = true
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "--no-guides":
      guides = false
    elif fontPath == "" and not a.startsWith("--") and
        (a.endsWith(".ttf") or a.endsWith(".otf") or a.endsWith(".ttc")):
      fontPath = a
    elif not a.startsWith("--"):
      outDir = a
  if fontPath == "":
    quit "usage: midsummer [font.ttf] [outDir] [--no-guides]  (or set TEXT_FONT)"
  main(fontPath, outDir, guides)
