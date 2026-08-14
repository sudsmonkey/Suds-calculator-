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
