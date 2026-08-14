# SEO backlog

Deferred work, to be picked up after the design/build passes are finished.
Nothing here is urgent; none of it is blocking. Audited 2026-08-14.

## Current state

| Page | `<title>` | meta description | canonical | Open Graph | JSON-LD |
|------|-----------|------------------|-----------|------------|---------|
| `index.html` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `consult.html` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `calculator.html` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `calendar.html` | ✅ | ❌ | ❌ | ❌ | ❌ |

No `robots.txt`, no `sitemap.xml`.

`index.html`'s meta description already names Oklahoma City, Edmond, Norman,
Moore. Its title is "Suds Monkey – Window Cleaning Oklahoma City Metro".

## Context: the removed city list

The old `.cta-band` on `index.html` carried ten city-name pills (Oklahoma City,
Edmond, Moore, Norman, Yukon, Mustang, Midwest City, Bethany, Piedmont,
Choctaw). It was replaced by the thank-you band in `267614a`.

Assessed impact: minimal. Four of the ten already appear in the meta
description, which is a stronger placement, and a bare list of city names is a
weak on-page signal — it's a keyword list with no supporting content. The six
that now appear nowhere are Yukon, Mustang, Midwest City, Bethany, Piedmont,
Choctaw. The right home for those is `areaServed` in structured data (below),
not a pill row.

**Do not re-add the pills to the thank-you band.** That section is deliberately
free of CTAs and reference clutter. If the list comes back, it goes in the
footer.

## Ranked by return

1. **`LocalBusiness` JSON-LD on `index.html`** — the biggest gap. Nothing on the
   site tells Google in machine-readable form what the business is, where it
   operates, or how to reach it; it's all inferred from prose. ~20 lines in
   `<head>`, no visual change. Include `name`, `telephone` (405) 882-2277,
   `areaServed` (all ten cities), `url`, `priceRange`, and `openingHours` once
   real hours are settled. Type is likely `HomeAndConstructionBusiness`.

2. **Open Graph + Twitter card tags on all four pages** — currently a shared
   link renders as a bare URL with no preview. Matters more than it sounds for
   a business that travels by word of mouth and text message. Needs a share
   image; the truck photo (`img-truck.jpg`) is the obvious candidate.

3. **Meta description + canonical on `consult.html`, `calculator.html`,
   `calendar.html`** — mechanical, five minutes.

4. **`robots.txt` + `sitemap.xml`** — marginal for a four-page site, but cheap.

## Outside the repo

- **Google Business Profile is the dominant factor** for "window cleaning
  [city]" searches — proximity to the searcher, review count and quality,
  category, NAP consistency. The website supports it; it does not drive it. Any
  effort here outweighs everything above.
- **Custom domain.** The site lives at `sudsmonkey.github.io/Suds-calculator-`
  — a subdirectory on a shared domain, with a trailing hyphen in the path.
  Moving to a real domain would outweigh every on-page item on this list
  combined.

---

# Image weight / page speed

Measured 2026-08-14. Page speed feeds search ranking, so it lives here too.

**Not urgent.** On a normal connection the home page is fine; this only bites on
a weak signal.

| connection | result |
|------------|--------|
| good signal | loads in 0.4–3.8s |
| weak LTE (1.6 Mbps, 150ms) | structure at 10s, full load **never completed in 90s** (27 of 55MB) |

## The split that matters

The images fall into two groups that must be treated differently. Measured
displayed widths, not guesses:

**Full-width backgrounds — leave alone.** `img-hero.jpg`, `img-wash.jpg`,
`img-highrise.jpg`, `img-truck.jpg`, `img-res-tree.jpg`. These render at the
full viewport width: 1920px on a big monitor, so up to 3840px for a retina
screen. Shrinking these *would* visibly soften them on desktop. `img-hero.jpg`
is already only 1400px and is arguably too small for a large display.

**The residential photo strip — the entire problem.** All 17 `IMG_*.jpeg`
files render at **220px wide on every screen size, desktop included** — they are
thumbnails in a scrolling row. They are 4032px camera originals, roughly 18×
oversized, and account for **~52MB of the home page's ~55MB**. Even allowing 2×
for retina they need 440px. Re-saved at ~600px they would total around 1MB with
nothing visible lost at any screen size.

## To do

1. **Re-save the 17 `IMG_*.jpeg` strip photos at ~600px wide.** Keep the
   originals in the repo (they are real job photos) and point the pages at
   web-sized copies. ~52MB → ~1MB.
2. **Add `loading="lazy"`** below the fold. Currently 0 of 52 `<img>` tags on
   `index.html` use it, so everything downloads immediately whether or not it is
   near the viewport.
3. **Delete three unused files**: `img-residential-windows.jpg` (5.9MB),
   `img-commercial.jpg`, `img-residential.jpg`. Referenced by no page.

Total repo image weight is 64.9MB across 27 files; 18 are over 2MB.
