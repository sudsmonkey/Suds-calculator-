# Funnel tracking

In-house tracking of the booking flow and Squeege Master 3000, read in
`admin.html` → **Funnel**. Basic traffic analytics (Vercel Analytics) comes
later, when the site moves to Vercel.

## Setup

1. Supabase → SQL Editor → paste all of `supabase/funnel.sql` → Run. Safe to
   run again. It works with or without `supabase/vendor-portal.sql`.
2. Open admin → Funnel. It uses the network admin key from the Pros tab; if you
   haven't entered it, get it with `select admin_key from network_settings;`.

Until step 1 is done the pages' tracking calls fail quietly, with no effect on
visitors.

## What's logged

Each page carries the same small inline snippet (`smTrack` / `smTrackOnce`,
just before `</head>`). Every event is one row in `funnel_events`:
`session_id` (random, per browser tab, kept in `sessionStorage`), `event`,
a short `detail`, an optional number `value`, the `page`, and `created_at`.
No names, emails, phones, addresses or IP addresses. Devices signed in to
admin (`suds_admin` in localStorage) log nothing.

| Event | Where | Detail / value |
|---|---|---|
| `landing` | first page of the visit (any page) | page name |
| `segment` | `calculator.html` (residential) or `consult.html` (commercial) opened | `residential` / `commercial` |
| `wizard_answer` | each quote question answered | `question:answer`, e.g. `stories:2`, `sqft:2000` |
| `price_shown` | residential prices unlocked | `quote` or `storm` |
| `package_picked` | a package selected (`selectPkg`, `bookConsult`) | package |
| `time_picker_open` | `calendar.html` loaded; first date tapped on `consult.html` | flow |
| `time_picked` | each time picked | `Preferred` / `Alt 1` / `Alt 2` (`:rush` / `:save`) |
| `book_tap` | Book / Confirm tapped | flow |
| `booked` | booking saved | package |
| `game_start` | first tool picked in the game | |
| `game_window_done` | a window finished | value = windows so far |
| `game_end` | game page hidden or left | value = seconds from start to last touch |

`calculator.html` and `consult.html` log by wrapping their existing handlers
at the end of the script (each answer is logged, then the original function
runs). The sq-ft slider only gets a `change` listener; the slider card itself
is untouched. `calendar.html`, `consult.html`'s Book button and `game.html`
have one-line calls in place.

## The report (`admin_funnel`)

- Counts distinct visits that reached each step, in the date range, for the
  chosen flow (a visit's flow is the first one it opened; "All visits" also
  includes visits that never opened one). Commercial has no price step.
- The biggest drop-off is the step that loses the largest share of the visits
  that reached the step before it.
- Under "Answered a quote question": visits per question, which shows where
  the wizard loses people.
- Squeege Master 3000: games started, average play time (longest `game_end`
  per visit), the share that finished a window, went on to a quote (opened
  the residential or commercial flow after starting the game) and booked.

Reading events needs the admin key; the public site key can only insert.

## Adding a step

Add the event name to the `check` list in `supabase/funnel.sql` (and to
`steps` in `admin_funnel` if it belongs in the funnel), re-run the SQL, then
call `smTrack('event_name', detail)` on the page.
