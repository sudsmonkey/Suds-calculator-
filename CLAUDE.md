# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Deployment

This is a static GitHub Pages site — no build step, no package manager, no server.

**Deploy to production:**
```bash
git push origin <branch>:main --force-with-lease=main:origin/main
git push -u origin <branch>
```
Always push to both: the first deploys to GitHub Pages (live site), the second keeps the feature branch current. The live URL is `https://sudsmonkey.github.io/Suds-calculator-/`.

**Development branch:** `claude/calculator-visibility-4e46v0`

## Deferred work

`SEO-BACKLOG.md` holds audited SEO gaps (structured data, Open Graph, per-page
meta) parked until the design passes are done. Read it before touching `<head>`
on any page, or before re-adding the city-name list that used to sit above the
footer on `index.html`.

`STRIPE-INVOICING.md` documents the "Send Invoice" feature on `admin.html`'s
booking cards: the Supabase Edge Function it depends on (`send-invoice`,
holds the live Stripe secret key server-side, deployed separately from this
repo), the one-time setup steps, and the full function code. Read it before
touching invoicing-related code in `admin.html` (the `sendInvoice()`
function, `.invoice-actions`, `invoice_url`/`stripe_invoice_id` columns).

`SECURITY-NOTES.md` holds a parked security audit (client-side keys, the
hardcoded admin password) to revisit before Stripe invoicing goes live.
Read it before changing `ADMIN_PASSWORD` or the Google Maps API key.

## Architecture

Four standalone HTML files — all CSS and JS are inlined. No framework, no bundler, no shared modules.

| File | Purpose |
|------|---------|
| `index.html` | Suds Calculator — instant quote tool for residential packages |
| `calendar.html` | Booking calendar — date/time selection and Supabase booking submission |
| `admin.html` | Admin dashboard — password-gated; block/unblock slots, view bookings |
| `game.html` | "Squeege Master 3000" — browser mini-game used as a marketing engagement hook |

### Data flow

`index.html` → `calendar.html` via URL query params:
- `?pkg=NAME&price=TOTAL&addons=ADDON:PRICE,...&wizard=...&shared=yes`

`calendar.html` reads those params to populate the summary card and Supabase booking record.

### Supabase (sole backend)

- **URL:** `https://ykjkcegpwiqhpfcgkwro.supabase.co`
- **Key:** `sb_publishable_wVwjixnqqbFjjJqH7f9nhA_qHGpE4md` (publishable, safe to commit)
- All API calls are direct REST (`fetch` to `/rest/v1/...`) — no Supabase JS SDK

**Tables:**

`bookings` — customer booking records
- Key columns: `date_iso` (YYYY-MM-DD), `time` (matches SLOTS values), `first_name`, `last_name`, `email`, `phone`, `package`, `total`, `date` (human-readable display), `add_ons`, `notes`, `monkey_bonus`

`blocked_slots` — admin-created blocks
- Key columns: `id`, `date` (YYYY-MM-DD), `time`, `created_at`

**RLS:** anon role has read/insert/delete on `blocked_slots`; anon has read/insert on `bookings`.

### Availability logic

`SLOTS = ['8:00 AM', '1:00 PM']` — defined as a constant in both `calendar.html` and `admin.html`. A date is "full" when taken slot count ≥ `SLOTS.length`.

Both `bookings.date_iso` and `blocked_slots.date` are queried and merged to determine availability. The `slotHour()` helper in `index.html`'s availability IIFE converts slot strings to 24h integers; today's slots require 1-hour notice (current hour + 1 > slot hour → hidden).

### Calendar rendering pattern

`renderCalendar()` is async (fetches month availability upfront). **Do not call `renderCalendar()` un-awaited from within `selectDate()`** — this causes a race condition where the async month fetch competes with `fetchTakenSlots()` and can leave the time grid in a stale state. Instead, toggle the `.selected` class directly using `data-date` attributes on calendar day elements.

### Admin auth

Client-side only: `sessionStorage.getItem('suds_admin') === '1'`. Password constant is `ADMIN_PASSWORD` at the top of the `admin.html` script block.

## Critical constraint

**DO NOT TOUCH the slider card in `index.html`** — not height, padding, margins, content, or structure. This is the sq-ft range input + story buttons section (`.input-card`, `#sqftSlider`, `.slider-section`). It is fragile and must not be modified.

## Design tokens

Consistent across all files (defined as CSS custom properties):
```
--orange: #F56E64      (primary CTA, coral)
--dark:   #A6382E      (headings, deep coral)
--mint:   #9ED9C0      (Silverback accent, availability dots)
--cream:  #FDF9F5      (page background)
--mid:    #7C7268      (secondary text)
--radius: 20px
```

Fonts: Anton (display), Nunito 700/800/900 (UI labels, prices), DM Sans 400/500/600 (body), Barlow Condensed Italic 800 (decorative). All loaded from Google Fonts CDN.

## Package structure (index.html)

Four packages in order: Lemur, Gorilla, Silverback Supreme, Silverback Storm.
- Lemur/Gorilla/Silverback → `selectPkg()` → `goToCalendar()` → `calendar.html`
- Storm → contact-only (phone/email), no online booking
- Prices are calculated dynamically from `sqft` slider + add-on checkboxes via `updatePrices()`
- Buttons and prices are blurred/hidden until `body.calibrated` class is applied (user has set sq-ft)
- `?ref=1` URL param activates a $25 referral discount ("Monkey Bonus")

## Availability pills (index.html)

An IIFE at the bottom of the script fetches the next 45 weekdays from Supabase and finds the first open slot. It sets `.avail-pill.open` (mint) on lemur/gorilla/storm pill elements and `.avail-pill.open.coral` on the Silverback (`avail-silver`) pill. Pills are hidden on network error.
