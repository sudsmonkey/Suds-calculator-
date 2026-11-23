# Vendor portal (Suds Monkey Network), step 1

Built from the "Vendor Portal Notes" doc. A customer picks three times, every
active pro gets the job as an offer, and the first pro to accept gets it.
Payouts and Stripe come later.

## What's in the repo

| File | What it does |
|------|--------------|
| `supabase/vendor-portal.sql` | Creates `contractors` and `job_offers`, adds new columns to `bookings`, and sets up the trigger that sends each new booking to the pros, the `portal_*` functions, and the `job-photos` bucket. Safe to run more than once. |
| `calendar.html` | Residential bookings use a scrolling list of days with 8 AM / 1 PM buttons, a pinned "preferred + two backups" header, Rush +$50 for tomorrow, Save 5% for 10+ days out, a price on each day, and a "We're finding your pro" screen. Consult links still use the month grid. |
| `portal.html` | The pro's phone page. Jobs tab: New offers (payout, countdown, address with a map link, the three times; tap one, then Accept) and Upcoming jobs (customer name and phone, Mark complete with after photos). Payouts tab: amounts on the 3-day hold and amounts released. |
| `supabase/functions/bright-endpoint/index.ts` | New bookings get a "We're finding your pro" email. After a pro accepts, `portal.html` triggers a one-time "Jerry with Clearview took your Tuesday 8 AM" email. |

## Setup (needs a laptop or the Supabase dashboard)

1. **Run the SQL.** Supabase dashboard → SQL Editor → New query → paste all of
   `supabase/vendor-portal.sql` → Run.
2. **Add your first pro.** At the bottom of that file, uncomment the
   `insert into public.contractors …` statement, edit the name, company and
   `payout_rate` (0.70 = 70% of the job price), and run it. It returns the pro's
   `access_code`.
3. **Send the pro their link:**
   `https://sudsmonkey.github.io/Suds-calculator-/portal.html?code=ACCESS_CODE`.
   The portal remembers the code on their phone after the first visit.
4. **Redeploy the email function** so customers get the "finding your pro" and
   "pro took your time" emails instead of "You're booked!": Supabase → Edge
   Functions → `bright-endpoint` → paste the new `index.ts` → Deploy.

Until step 1 is done, `calendar.html` still saves bookings. The new columns
don't exist yet, so it leaves them out and writes the two backup times into the
booking's notes.

## Rules in the code (change in one place)

| Rule | Where |
|------|-------|
| 2-hour confirm window, starting when the customer books | `_sm_offer_window()` in the SQL, `CONFIRM_MINS` in `calendar.html` |
| Platform hours 8 AM to 7 PM Oklahoma time (the window only counts down inside them) | `_sm_hours_open()` / `_sm_hours_close()` / `_sm_tz()` in the SQL, `PLATFORM_OPEN` / `PLATFORM_CLOSE` in `calendar.html`. Keep the two in sync. |
| 3-day payout hold | `_sm_payout_hold()` in the SQL |
| Pro keeps 90% of the rush fee | `_sm_rush_pro_share()` in the SQL |
| Pro's share of the job price | `contractors.payout_rate`, one per pro |
| Rush +$50, Save 5% at 10+ days | `RUSH_FEE`, `SAVE_PCT`, `SAVE_DAYS` in `calendar.html` |

## How it behaves

- The booking's `date_iso` / `time` / `total` start as the customer's preferred
  pick. If the pro accepts a backup time, they switch to that pick. This keeps
  availability checks and `admin.html` working unchanged.
- Only the preferred time blocks availability until a pro accepts. With one
  pro, a backup time can be taken by someone else in the meantime; accepting it
  then fails with "That time was just taken".
- Each offer's deadline (`job_offers.expires_at`) is set when the customer
  books: 2 hours, counting only 8 AM to 7 PM. For example, a 3 PM booking is
  due at 5 PM, a 6:30 PM booking at 9:30 AM, and an 11 PM booking at 10 AM. The
  customer's screen and email give the exact time. Overnight, the portal shows
  "Answer by 9:30 AM" instead of a long countdown.
- If no pro accepts by the deadline, or every pro declines, the booking's
  `status` becomes `no_pro` so you can follow up. `admin.html` doesn't show this
  yet.
- No same-day jobs: the list starts tomorrow, and tomorrow is the Rush day.
  A slot is hidden if the pro's deadline would land after it starts, so after
  5 PM tomorrow's 8 AM disappears and tomorrow's 1 PM stays.
- Pros see the customer's phone and last name only after they accept.

## Not built yet

- Text message (SMS) notice when a pro accepts. Email only for now.
- Showing `status` / `no_pro` and the after photos in `admin.html`.
- Adding and editing pros from `admin.html`. For now, use the SQL editor or the
  Table Editor.
- Stripe payouts and complaint handling before pay is released.
- Multi-pro availability (a slot is still "taken" by one booking site-wide).
- Security note: anyone with the site key can upload to `job-photos` (they can't
  read or list it). Tighten this before the network grows.
