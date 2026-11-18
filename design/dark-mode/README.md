# Dark mode — sketches (#191)

Sketches only: no app code changes. Today's board, layout, fonts and chrome are kept; only
colours change. The rejected redesign concept's dark palette looked dusty. These are four fresh
directions to choose from.

- `renders/comparison.png`: all directions side by side (light reference + 4 dark game screens, start screens below)
- `renders/<theme>-game.png`, `renders/<theme>-start.png`: iPhone 390×844 @2x for `light`, `espresso`, `night`, `walnut`, `felt`
- `themes.js`: every token, one object per direction (the source of truth for the tables below)
- `mock.html`: the mock (`#theme=night&screen=game`). The board is a 1:1 port of `BoardView` / `BoardGeometry` / `drawCheckerDisc` (900-unit design space)
- `sheet.html`: the comparison sheet. `render.sh` re-renders everything via headless Chrome
- `contrast.js`: the WCAG and checker-separation checks (`node contrast.js`)

## Why warm dark palettes go "dusty"

- **Low-chroma, mid-value browns.** A warm grey-brown (≈ #2a2420 to #3a322c) has almost no saturation.
  At that lightness the eye reads it as dirt or dust, not as a material. Warm darks only look rich when
  they are either very deep (near black, with the hue still visible) or clearly saturated.
- **Grey veils and opacity mud.** Tinting chrome with a warm colour at 10–20 % opacity over a dark
  base gives a grey-brown film. Desaturated tan secondary text (#b8a080-ish) on that film is the
  classic dusty look.
- **Small value steps between surfaces.** When page, cards and buttons sit within a few L* of each
  other in the same hue, nothing separates and everything looks hazy.
- **Muddy focal objects.** A bright caramel board, darkened red checkers and dimmed ivory all landing
  at similar mid values next to a brown page means the board, checkers and chrome blend into one
  temperature and one value.

**What makes a dark theme feel fresh and cool:** a deep, near-black base with clean value steps
(bg → surface → elevated about 4–6 L* apart), a little real chroma (cool blue or green, or a
saturated deep warm) instead of grey, crisp near-white type at 15:1 or more, one saturated accent,
and the board's warm colours used as the focal point, not spread over the chrome.

## Directions

All four keep: board geometry, diamonds, dice, checker rendering, amber move highlight
(`hl #f4b400`), button and card shapes, SF and Cormorant type. The light primary amber (#a87a3e,
white label) becomes a brighter caramel (#e0a0–#eaa7) with a **dark** label in dark mode, so it
reads as lit, not muddy.

### A · Espresso: warm, but deep
Near-black roasted brown (#100804) with real hue, crema-cream type and a caramel accent. The board
keeps caramel, toned down one step so it doesn't glare. This is the closest to today's brand mood,
but it's also the most at risk of sliding back to "brown": its buttons are amber-on-black tints that
read as leather, which is rich but not "cool".

### B · Night table: cool chrome, warm board ★
Ink-blue near-black chrome (#0a0e15 / #141a24 / #1d2531) with cool white type. The caramel board is
practically unchanged and becomes the warm, glowing centre of the screen (complementary blue vs
amber). A faint amber glow sits above the board. This direction most directly answers "fresh and
cool", and the board stays exactly recognisable.

### C · Walnut (OLED): the board dims too
A true-black screen with neutral near-black surfaces. The board itself turns walnut: a dark frame
with a caramel edge, a near-black play surface, and saturated cream-gold points (#ead09a, deliberately
*not* a beige that would go dusty). The checkers become the brightest objects, so contrast for play
is the best of all four. It is the least glare at night, but the board is a second palette to maintain
and is less "the Tavlo board".

### D · Kafeneio felt: something unexpected
Deep bottle-green chrome with a **green felt play surface** inside the caramel frame: the café-table
backgammon look. The red checkers pop strongly against the green. It is the most characterful, but it
changes the board's identity (mahogany → felt) more than #191 asks.

## Token tables

Values from `themes.js`. "light" is today's app (`CaramelPalette`, `ChromeTheme`, `ChromeKit`).

### Chrome

| Token | Light (today) | A Espresso | B Night table | C Walnut | D Felt |
|---|---|---|---|---|---|
| background | #ece6dc | #100804 | #0a0e15 | #000000 | #06120d |
| surface (card) | #f6f0e3 | #1e110a | #141a24 | #141210 | #0d231a |
| elevated | #fdf9f1 | #2a1910 | #1d2531 | #1f1c19 | #143024 |
| separator | ink 12 % | rgba(255,214,160,.10) | rgba(170,190,220,.12) | rgba(255,240,220,.12) | rgba(170,230,200,.12) |
| text primary | #3a2510 | #f8ecd6 | #eef2f7 | #f5efe6 | #eef6f1 |
| text secondary | ink 72 % | cream 70 % | #a3afc0 | 66 % | #9fbcad |
| accent (primary fill) | #a87a3e | #e8a24a | #eaa74d | #e09a42 | #eaa64c |
| on-accent | #ffffff | #1c0f05 | #1a1006 | #140a02 | #1a1006 |
| secondary button fill | #a87a3e 16 % | #e8a24a 15 % | rgba(170,190,220,.12) | rgba(255,240,220,.10) | rgba(110,210,160,.11) |
| chip / score pill | ink 6 % | rgba(255,226,180,.07) | rgba(170,190,220,.08) | rgba(255,240,220,.08) | rgba(170,230,200,.08) |
| destructive | #b05a44 | #f08b6d | #ff8a70 | #ff8d72 | #ff8a70 |
| wordmark | #3a2510 | #f3c27a | #f0b860 | #f5efe6 | #f0b860 |
| card edge (instead of shadow) | shadow 10 % | 1px rgba(255,214,160,.06) | 1px rgba(170,190,220,.07) | 1px rgba(255,240,220,.07) | 1px rgba(170,230,200,.07) |
| chrome disc White / Red | #fbeed1 / #a83a2a | #f1e6c8 / #d84a36 | #f1e6c8 / #e0503c | #f3e8cc / #e04a35 | #f1e6c8 / #e0503c |

### Board

| Token | Light (today) | A Espresso | B Night table | C Walnut | D Felt |
|---|---|---|---|---|---|
| frame top / mid / bot | #e8c089 / #d4a466 / #a87a3e | #d7a868 / #bd8a4b / #8c5f2a | #e0b476 / #c99858 / #996a32 | #6e4526 / #553219 / #341c0c | #d9ab6c / #c08e50 / #8e612b |
| frame highlight | #f4d6a3 | #ecc78c | #f2d29e | #c8904e | #efcd96 |
| play surface top / bot | #8a4a22 / #6a361a | #7e3f1b / #5c2a12 | #8a4a22 / #6a361a | #1f110a / #140a05 | #1e5a40 / #143f2c |
| points (fill) | #fbeed1 | #f4e3c0 | #f7e8c8 | #ead09a | #f4e6c6 |
| point stroke / bar line | #2a1408 | #1c0d05 | #2a1408 | #0a0503 / #a8743e | #0b1f16 |
| White checker fill / hi / ring / edge | #f1e6c8 / #fbf3d8 / #a8915f / #5a4828 | same | same | #f4e9cd / #fffaea / #a8915f / #3a2d18 | same |
| Red checker fill / hi / ring / edge | #c0392b / #dc5040 / #5e160b / #2a0a04 | #cc3a2a / #e85844 / same | same as light | #d7412f / #f0604c / #6a1a0d / #1a0603 | same as light |
| die face / pip | #f5ead0 / #2a1408 | #f6ead0 / same | same | #efe2c2 / same | same |

### Highlights

| Token | Light (today) | A | B | C | D |
|---|---|---|---|---|---|
| selected source ring (`hl`) | #f4b400 | #f4b400 | #f4b400 | #f4b400 | #f4b400 |
| legal target frame / fill (`hl` / `hlFill`) | #f4b400 / #f6c623 | same | same | same | same |
| review best (`hlBest`) | #2f7fd1 | #2f7fd1 | #2f7fd1 | #4a9bf0 | #2f7fd1 |
| review both (`hlBoth`) | #3fa64a | #3fa64a | #3fa64a | #4cc25a | #3fa64a |
| last move (not in the app today; proposal) | `hlBest` at 60 % ring | same | same | #4a9bf0 | same |

The amber highlight needs no dark variant: it was chosen to read on ivory points *and* the dark
mahogany, and that holds on every surface here (5.3:1 or better against the play surface).

## Contrast notes (`node contrast.js`)

| theme | text/bg | text2/bg | text2/card | text2/chip | btn label/tint | onAccent/accent | accent/bg | red↔white checker ΔE | red↔white L-ratio | red/surface | white/surface | red/point ΔE | hl/surface |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| light | 11.7 | 5.2 | 5.5 | 4.9 | 10.0 | 3.8 | 3.1 | 75 | 4.4 | 1.8 | 7.8 | 77 | 5.3 |
| espresso | 17.0 | 8.4 | 8.1 | 7.9 | 13.5 | 8.7 | 9.2 | 77 | 4.0 | 2.3 | 9.4 | 75 | 6.3 |
| night | 17.2 | 8.7 | 7.9 | 7.7 | 14.0 | 9.0 | 9.3 | 75 | 4.4 | 1.8 | 7.8 | 75 | 5.3 |
| walnut | 18.4 | 7.9 | 7.5 | 7.5 | 15.5 | 8.3 | 8.9 | 78 | 3.7 | 4.4 | 16.2 | 67 | 10.6 |
| felt | 17.4 | 9.3 | 8.1 | 8.0 | 14.3 | 9.0 | 9.1 | 75 | 4.4 | 2.2 | 9.5 | 74 | 6.4 |

- Every dark direction passes **WCAG AA for body text with a wide margin**: primary text at 17:1 or
  more, secondary at 7.5:1 or more on every surface. All four beat today's light theme (secondary
  4.9–5.5).
- The primary button improves from 3.8:1 (white on #a87a3e: today it passes only as large, bold text)
  to about 9:1 (dark label on a brighter caramel).
- **Red vs White checkers** stay clearly distinct everywhere (ΔE 75–78, luminance ratio 3.7–4.4). The
  checkers keep their edge and rings, so a White checker on a cream point still separates. A Red
  checker on a dark play surface is low in luminance contrast (1.8–2.3:1, the same as today) but
  separated by hue and its dark edge. Walnut is the best case for this (4.4:1).

## Recommendation: B · Night table

1. **It answers the complaint directly.** "Dusty" comes from warm, low-chroma mid-darks. Night table
   uses a cool, slightly blue near-black with clean value steps and white type, which reads as fresh and
   crisp. The warmth is concentrated where it belongs: the board and the one caramel accent.
2. **The board stays exactly recognisable.** The board and checkers are today's palette (the frame is a
   hair less bright). Dark mode becomes a *chrome-only* change: `ChromeTheme` / `ChromeKit` /
   page-background tokens get light and dark values, and `CaramelPalette` barely changes. That is the
   smallest and safest implementation, and the review chart, dice and highlights need no re-tuning.
3. **Complementary contrast flatters the board.** Amber against ink-blue makes the caramel look more
   saturated than it does on paper, so the board becomes the screen's focal point at night.

Runner-up: **C · Walnut** as an optional "dim board" for people who play in bed (OLED black, nothing
glares), if the extra board palette is worth maintaining. A could be a fallback if the user wants
dark mode to stay warm. D is a fun alternative look rather than a dark mode.

## Open questions for the user

1. **System setting vs manual toggle.** Follow iOS Appearance automatically (recommended, with no
   setting), or add a Display setting "Appearance: System / Light / Dark"?
2. **Board in dark mode.** Keep the caramel board (B, A, D) or darken it too (C)? Or offer C as a
   separate "dim board" option?
3. **Warm or cool chrome.** Is a cool blue-black acceptable for the brand, or must the chrome stay
   warm (then A Espresso)?
4. **App icon.** The dark icon already uses an espresso tile (#2a1408). With Night table, should the
   dark icon's tile move to the ink blue (#0a0e15) to match, or stay espresso?
5. **Review chart / game-over card.** These weren't mocked. In B, the review chart keeps its mahogany
   "board window", and the game-over card becomes an elevated surface (#1d2531) over a black 55 % scrim.

---

## Round 2: refined variants of C (user feedback)

The user disliked the blue (B) and green (D) backgrounds. They really liked C's all-black look and
dark walnut board, but prefer warm, brown text to white, and worried that true black looks worse on
their non-OLED iPad. Sheet: **`renders/c-variants.png`**, with per-variant renders in
`renders/c1-…c4-game.png` / `-start.png`. All four keep C's walnut board unchanged.

| Token | C1 (today's C) | C2 Black + warm | C3 Espresso + warm | C4 Balanced |
|---|---|---|---|---|
| background | #000000 | #000000 | #0e0805 | #080402 |
| surface | #141210 | #16100a | #1d130b | #18100a |
| elevated | #1f1c19 | #22180f | #2b1c10 | #25190f |
| headings (turn status, card titles) | #f5efe6 | #f4d7a4 | #f4d7a4 | **#f2b866** (caramel) |
| wordmark | #f5efe6 | #f4d7a4 | #f4d7a4 | #f2b866 |
| body / button labels | #f5efe6 | #f4d7a4 | #f4d7a4 | #f7e6c8 (warm cream) |
| secondary text | 66 % white | #cf9f62 | #cf9f62 | #c99c64 |
| icons | 80 % white | #d9ad72 | #d9ad72 | #e0b47a |
| secondary button fill | white 10 % | rgba(255,190,110,.10) | rgba(255,190,110,.11) | rgba(255,190,110,.10) |
| accent / on-accent | #e09a42 / #140a02 | same | same | same |

The secondary text is a saturated caramel-tan (#cf9f62, about 40 % chroma), deliberately not a
greyed tan, so it stays crisp. Surfaces are warm-tinted near-blacks rather than neutral greys.

### Contrast (`node contrast.js c1 c2 c3 c4`)

| theme | text/bg | heading/bg | text/card | text2/bg | text2/card | text2/chip | btn label/tint | onAccent/accent | accent/bg |
|---|---|---|---|---|---|---|---|---|---|
| c1 | 18.4 | 18.4 | 16.3 | 7.9 | 7.5 | 7.5 | 15.5 | 8.3 | 8.9 |
| c2 | 15.1 | 15.1 | 13.6 | 8.8 | 7.9 | 8.0 | 13.2 | 8.3 | 8.9 |
| c3 | 14.3 | 14.3 | 13.1 | 8.3 | 7.6 | 7.2 | 11.9 | 8.3 | 8.4 |
| c4 | 16.6 | 11.5 | 15.3 | 8.2 | 7.5 | 7.4 | 14.4 | 8.3 | 8.6 |

Every variant clears AAA (7:1) for primary text and AA by a wide margin for secondary text
(7.2 or more against the 4.5 target). The board values are identical across C1–C4 (red↔white
checker ΔE 78, white/surface 16.2, red/surface 4.4, highlight/surface 10.6).

### LCD note

An LCD can't switch pixels off, so the backlight lifts #000 to roughly #0f0f0f. That is a flat,
slightly cool charcoal, with a brighter glow toward the edges. The strip on the sheet approximates
this with a screen blend of #0f0f11 plus edge bleed. It's a rough model, not a calibrated one.
Under that lift, true black (C2) turns neutral grey and fights the warm text. An espresso-black
(C3, and to a lesser degree C4) lifts to a warm dark brown that still matches the walnut board.
On OLED, C3 is visibly brown-black, while C4's #080402 is practically indistinguishable from black.

### Recommendation: C4

C4 looks all-black on an OLED iPhone. Its #080402 base adds just enough warmth that on an LCD
iPad the lifted black leans warm brown instead of cool grey. The caramel headings and wordmark tie
the chrome to the board's frame and the app icon, and the warm-cream body keeps long text calm and
readable. If the LCD iPad still looks too grey in a real test, step the base to C3's #0e0805: it's
a single token. A real-device check on the user's iPad before deciding is worth more than the
simulation.

---

## Implemented: C3 · Espresso + warm text (#191)

The user picked **C3** (espresso-black chrome, warm cream-caramel text, tan secondary text,
caramel accent with a dark label) with C's walnut board. Values come straight from `themes.js`
(`c3`). The app follows the iOS appearance by default, with Settings → Display → Appearance
(System / Light / Dark). Light mode is pixel-identical to before (verified by image diff of the
start and game screens on iPhone 13 mini and iPad Pro 11", see `*-light-*.png` vs `*-light-*-main.png`).

`implementation-screens/` holds simulator screenshots (half resolution) of the shipped dark
mode: `iphone-dark-*` (iPhone 13 mini, portrait + landscape) and `ipad-dark-*` (iPad Pro 11"
portrait). `iphone-dark-settings-display.png` and `iphone-dark-review-details.png` were taken
before the dark segmented-control styling landed (grey system segments); the other settings
screenshots show the final warm segments.
