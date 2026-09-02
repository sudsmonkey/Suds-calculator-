# Storm question flow — parked

Levi flagged the storm-windows question in the residential wizard
(`calculator.html`) on 2026-09-02: *"If they say yes to storms they go
straight to storm package, so need to load or toggle sq footage"* (exact
wording ambiguous — could mean either of two different things, see below).
Parked until he clarifies which one.

## What the code does today

Two paths lead into the Storm Package, both funneling through
`enterStormMode()`:

1. **Storm windows question** (`#calibrateStep3c`, `selectStormQ('yes', ...)`)
   → shows the `#calibrateStepStorm` terminal card ("You're in the Right
   Place") → user taps "See My Package →" → `stormWithBubbles()` →
   `enterStormMode()`.
2. **Historic neighborhood question** (`#calibrateStep5`,
   `selectHistoric('yes', ...)`) → `enterStormMode()` directly, no terminal
   card in between.

Both paths skip `#calibrateStepSize` (the "How big is your home?" sq-ft
slider question) entirely — the storm package is priced per-window
(`storm-floor1`/`storm-floor2` checkboxes + counts, $90/$135 each), not off
square footage, so the slider was never meant to gate it.

`enterStormMode()` (calculator.html:1510) unlocks the slider
(`disabled = false`, removes `.locked`) and adds `body.calibrated` +
`body.storm-mode`, but — unlike `completeCalibration()`, the normal
end-of-wizard path — it does **not** call `updatePrices()`.

## What I verified (Playwright, both paths)

- `body` ends up with `storm-mode calibrated` either way.
- `#sqftSlider` ends up `disabled: false`, value `1500` (the HTML default).
- `#sliderWrap` has no `.locked` class.
- `#sqftDisplay` reads "1,500 sq ft".
- No blur/opacity is left on `#calibrateStepSize` or `.size-band`.
- `updatePrices()` already runs once unconditionally at page load
  (calculator.html:1795) and again in `selectStories()`, so the underlying
  Lemur/Gorilla/Silverback numbers are already computed by the time either
  storm path fires — `enterStormMode()` not calling it again didn't appear
  to leave anything visibly stale in this test run.

So on paper, the storm-yes path already "goes straight to storm package"
without the customer ever having to touch the sq-ft slider, and nothing
looked broken in a fresh run-through.

## The ambiguity

Levi's sentence reads two ways depending on a dropped word:

- **"...package, *so* need to load or toggle sq footage"** — describes a
  bug: something about the sq-ft slider/pricing isn't being initialized
  ("loaded") when a customer jumps straight to storm, and needs to be
  fixed to match the normal `completeCalibration()` treatment (which does
  call `updatePrices()`).
- **"...package, *no* need to load or toggle sq footage"** — describes
  the *intended* behavior (storm doesn't need sq-ft at all), which the
  code above already appears to do — in which case the actual bug is
  something else Levi observed live that this local test didn't surface
  (different device, real Supabase data, a specific package/step
  combination, etc.).

Asked Levi to disambiguate via AskUserQuestion; he asked to park it here
instead and revisit later.

## Next step when picked back up

Ask Levi for specifics of what he's actually seeing go wrong on his end
(screenshot or screen recording ideal) — which question he answers, what
he expects to happen next, and what happens instead — rather than
re-guessing from the code alone.
