# kbshot

Screenshot a *thing* on your screen, chosen with the keyboard. Press a hotkey, every
screenshot-worthy region gets a labelled chip, type the label, that region is on your
clipboard. The mouse is never involved.

Not a rectangle-dragging tool with keyboard bindings bolted on — it looks at what is on
screen and offers you the objects: windows, panes, columns, paragraphs, chat messages,
code blocks, cards, table rows, figures.

![the overlay over a chat app](docs/overlay-slack.png)

## Why

Every Wayland screenshot tool wants you to drag a rectangle. `slurp` needs a mouse.
`wl-kbptr` can drive a pointer from the keyboard, but its region detector is tuned for
*click targets* — it explicitly discards anything taller than 50px or wider than 500px,
which is the exact opposite of what a screenshot wants. Accessibility tooling that
does screen parsing is either platform-specific or needs a GPU.

So kbshot does its own region detection and borrows wl-kbptr purely as the overlay.

## How it works

```
grim ──> frozen frame
           │
           ├─ hyprctl clients ──────> window rectangles          (free, exact)
           ├─ tesseract --psm 3 ────> block / para / line / word (layout TSV)
           ├─ sobel + components ───> drawn rectangles, 2 radii  (cards, images)
           ├─ recursive XY-cut ─────> whitespace-defined regions  (messages, paragraphs,
           │                                                       columns, code blocks)
           └─ background medians ───> painted-tint regions        (table rows, panels,
                                                                   callouts)
           │
      IoU dedupe ──> per-tier budget ──> label placement ──> wl-kbptr floating mode
           │
      type a label ──> crop at native resolution ──> clipboard + file + notification
```

The interesting part is the last two sources. Tesseract finds *text* and the sobel pass
finds *drawn boxes*, but neither can see a region defined purely by the whitespace
around it — and a chat message, a paragraph, a card and a table row are all exactly
that. A Slack message has no border, and to tesseract its author line, timestamp and
body are unrelated blocks; what makes it one object is the blank band above and below.

Recursive XY-cut finds those. Three details make it work on real screens rather than on
clean documents:

- **A blank tolerance, not a zero test.** On a real desktop no row of pixels is ever
  completely empty — measured on a live frame, the quietest row still carried 8px of
  ink because a window separator ran the full height. A strict test finds no gutter
  anywhere and the algorithm degenerates to a single box. The threshold is 1.2% of the
  span, just above that noise floor.
- **Both axes, not the widest gutter.** A table's column gutters are wider than its row
  gutters, so a widest-gutter rule cuts into columns first and then rows *within* a
  column — meaning it can only ever emit cells, and a full-width row is unreachable.
  Cutting both ways and offering both is strictly better for a picker.
- **Several gutter widths per node.** A table's inter-row gutters are all the same
  modest size, so any threshold derived from the widest gap in the region discards every
  one of them. Cutting at the widest, a typical, and the smallest gutter yields the
  section, row and line decompositions as alternatives.
- **Cut inside each window, not across the whole screen.** This one only shows up on a
  real desktop, and it is the difference between the source working and not working. Run
  screen-wide, persistent chrome bridges every gutter: a row of pixels through the empty
  middle of the screen still crosses a full-height browser sidebar, and a column still
  crosses the full-width taskbar, so neither projection ever falls under the blank
  tolerance and nothing is cut at all. Measured on a live frame, screen-level cutting
  found **2** regions where per-window cutting finds **166**. Single-app test scenes have
  no chrome and hide this completely, which is a standing argument for checking every
  synthetic result against a real screen.

### Background bands

Three of the four sources look for *contrast*: glyphs, drawn edges, whitespace. A fourth
kind of boundary has none — a table's zebra striping, a tinted code block, a callout
panel. Those are a painted background differing from the page by a handful of luma
levels, far too little for any edge threshold that is not also picking up noise.

So this channel ignores edges and reads the background colour directly: mask out the ink,
then take the **median** of the remaining pixels per row. The median is the point — it
discards glyphs and anti-aliasing, so a 4-level stripe that sobel can never see becomes a
clean step function. Bands are flat runs split at the steps; each band's horizontal extent
comes from the same median trick over columns, which is what recovers the *full stripe
width* when a row's ink only covers part of it.

Measured effect: table rows went from 0/14 in light themes and 13/14 in dark to **14/14 in
both**, for 17 extra candidates and ~30ms.

## Labels

wl-kbptr centres a label inside the area it is given and scales the font from that
area's **height**. Handing it the detected regions directly fails in two ways at once: a
27x15 text run gets a label wider than its own box, and concentric regions share a
centre so their labels stack on the same pixels.

So the areas handed to wl-kbptr are not the regions — they are fixed-size chips at each
region's top-left corner, nudged outward until they stop colliding, Vimium-style, with a
dict mapping chip geometry back to the real region. Uniform chip height means one
readable font size for every element however small, and `label_font_size = N 0 N`
exploits wl-kbptr clamping `height * proportion` into `[min, max]` so a zero proportion
pins the size exactly.

When a region genuinely has nowhere to put a chip, it is **grouped** onto the chip it
collided with rather than dropped, and selecting that chip opens a second round among
just those few. Two hundred tiny elements in one corner cannot each own a readable
label, but everything you can see stays reachable.

![five concentric regions, five distinct labels](docs/overlay-concentric.png)

## Contrast

wl-kbptr paints label text straight onto the area rectangle with no backing of its own,
so a label's real contrast is against the fill *composited over whatever was already on
screen*. wl-kbptr's stock `selectable_bg_color` is 13% opaque, which puts white label
text on a white article page at about 2:1 — invisible, not merely poor.

Every palette here uses a near-opaque fill instead. It costs nothing, because a chip is
only 46x30 logical px, and it buys a contrast ratio that does not depend on the
wallpaper. Measured worst case across white, light, mid-grey, near-black and saturated
backgrounds:

| theme | label on chip | typed prefix | typed vs untyped |
|---|---|---|---|
| `default` | 16.9:1 | 6.9:1 | 2.4:1 |
| `colorblind` | 18.0:1 | 6.8:1 | 2.6:1 |
| `light` | 17.5:1 | 5.4:1 | 3.2:1 |

`--theme colorblind` encodes **no distinction in hue**. The typed-so-far prefix is
separated from the remainder by lightness alone (grey against white), and the border is
Okabe-Ito sky blue. Verified by pushing every colour through the Machado et al. (2009)
severity-1.0 deuteranopia, protanopia and tritanopia matrices and re-measuring: label
contrast stays within 0.1 of 18:1 and the typed/untyped separation within 0.04 of 2.6:1
under all three.

`tests/test_contrast.py` computes all of it — and it earns its keep: it caught the
default palette's bright amber separating from white by only 1.54:1, invisible at 19px.

## Evals

Detection quality is not observable by taking a screenshot and squinting, so `--from-image`
runs the whole candidate pipeline against a saved image and prints the candidates as
JSON. `tests/gen_scenes.py` draws 19 synthetic screens — chat, article, photographed book
page, code editor, terminal, spreadsheet, dashboard, dense settings UI, concentric
rectangles, image-dominated — in dark and light variants, and derives 239 ground-truth
regions from the draw calls, so the annotations are exact rather than eyeballed.

`tests/harness.py` scores two independent families:

**Semantic** — is the region actually offered, and what does it cost to reach?

| | text + rects only | + XY-cut | + background bands |
|---|---|---|---|
| primary recall @ IoU 0.70 | 45.8% | 81.9% | **91.6%** |
| primary recall @ IoU 0.50 | 60.0% | 92.9% | **98.1%** |
| median best IoU | 0.622 | 0.907 | **0.930** |
| mean keystrokes to a target | 1.95 | 1.99 | 2.03 |

By region kind, after: table-row 28/28, paragraph 26/26, code-block 8/8,
terminal-output 10/10, column 6/6, pane 6/6, concentric 5/5, heading 4/4, figure 4/4,
card 18/20, message 14/18, chart 7/12, message-group 0/2.

**Structural** — invariants that must hold on *any* screen, needing no annotation:
no two labels may overlap, every offered region clears the minimum size, labels are
unique, every candidate is reachable by some keystroke path, and two runs on one image
must produce identical labels or no muscle memory can form. All four counters are 0
across the 19 synthetic scenes and 30 real desktop captures, and the repeat run is
byte-identical.

The harness also measures **clutter** — what fraction of the screen the chips cover —
because recall alone is a trap. At the 324-candidate ceiling recall peaked but the
rendered overlay was visibly carpeted and mean keystrokes rose to 2.54. The default of
280 is the measured knee:

| budget | recall @.7 | recall @.5 | chips cover | mean keystrokes |
|---|---|---|---|---|
| 120 | 70.3% | 78.1% | 3.2% | 1.98 |
| 200 | 74.8% | 84.5% | 5.3% | 1.98 |
| **280** | **81.9%** | **92.9%** | **7.4%** | **1.99** |
| 324 | 83.9% | 93.5% | 8.5% | 2.54 |

On 30 real desktop captures all four structural counters stay 0, chips cover a median
5.5% of the screen (max 7.4%), and median latency is 0.69s.

Known weak spots: runs of consecutive same-author chat messages (`message-group` 0/2);
`chart` 7/12 and `message` 14/18, both of which lost a point or two to candidates the
bands channel added, which is the eviction effect the budget table below describes; and on
a very dense list view the chips do cover content — `--max 120` drops coverage to 3.2% if
you prefer a calmer overlay.

## Not stacking overlays

wl-kbptr takes an **exclusive** layer-shell keyboard grab, so a wedged picker is not a
stuck window — it is a black hole for every keystroke with no way out. Pressing this
tool's hotkey and then another screenshot hotkey (which starts a fullscreen frozen-screen
layer on top) leaves the screen covered while an invisible surface owns the keyboard.

Three independent automatic defences, because a user should not have to remember an
escape hatch:

1. **Single-flight** — a second invocation replaces the first instead of stacking.
2. **Pre-clear** — rival overlays are torn down *before* the frame is captured, so a
   frozen copy of the screen is never baked into the detected regions.
3. **Yield watcher** — if a rival overlay appears while the picker holds the keyboard,
   the picker cancels itself within 0.2s.

Plus a hard `--timeout` (45s default) and `kbshot --abort` as a last resort.

## Install

### Nix

```nix
# flake input
kbshot.url = "github:MattHandzel/kbshot";

# then
environment.systemPackages = [ inputs.kbshot.packages.${system}.default ];
```

Or run it without installing:

```
nix run github:MattHandzel/kbshot
```

### Manually

Needs `wl-kbptr` ≥ 0.4.1, `grim`, `tesseract`, `wl-clipboard`, `libnotify`, `procps`,
and Python with `numpy`, `scipy`, `pillow`. Window detection uses `hyprctl` and is
skipped gracefully elsewhere; the other three sources work on any wlroots compositor.

```
python3 kbshot.py
```

### Binding it

```
bind = CTRL, Print, exec, kbshot
bind = CTRL ALT, Print, exec, kbshot --ocr        # copy the text, not the image
bind = CTRL SHIFT, Print, exec, kbshot --corners  # type two corners instead
bind = SUPER SHIFT, Print, exec, kbshot --abort
```

## Usage

```
kbshot                      detect, pick, copy + save
kbshot --ocr                OCR the chosen region, copy the text
kbshot --corners            no detection: narrow to two corners by typing
kbshot --region             print "X,Y WxH" and exit
kbshot --fast               skip OCR: ~0.5s to overlay instead of ~1.3s
kbshot --theme colorblind   hue-independent palette
kbshot --words              also offer individual words
kbshot --from-image F.png   run detection on a file, print candidates as JSON
kbshot --debug-overlay O.png   draw the detected regions onto the frame
kbshot --abort              kill any overlay holding the screen or keyboard
```

The label alphabet defaults to `udagcprfylmwkjvbxq` — 18 letters chosen to avoid
home-row modifiers. If your keyboard puts hold-tap mods on the home row, a label's first
character is by definition typed after a pause, which is exactly the timing that
resolves to a modifier and turns a selection into `Alt+key`. Override with `--labels`.

## Latency

Median 1.3s to the overlay on a 2880x1800 screen, of which tesseract is most of it;
`--fast` drops it to ~0.5s. Two things matter and are easy to get wrong:
`OMP_THREAD_LIMIT=1` makes tesseract ~40% *faster* here (its OpenMP threads contend more
than they help), and OCR runs on a half-scale copy because halving the input barely
moves box geometry while cutting the time from 4.3s to 1.5s.

## Fractional scaling

`hyprctl` rounds `scale` to two decimals and dividing by the rounded figure puts every
coordinate a few pixels out — `2880/1.33 = 2165` where the true logical width is 2160.
Wayland quantises scale to 1/120 and the logical size must be a whole number of pixels,
so the exact scale is recovered by searching k/120 near the reported value. Crops round
each **edge** from its absolute coordinate rather than rounding width and height, which
is what makes adjacent regions tile without seams.

## License

MIT
