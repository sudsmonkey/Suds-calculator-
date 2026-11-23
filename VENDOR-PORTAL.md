# Vendor portal (Suds Monkey Network)

Built from the "Vendor Portal Notes" doc. A customer picks three times, every
active pro gets the job as an offer, and the first pro to accept gets it.
Payouts and Stripe come later.

## What's in the repo

| File | What it does |
|------|--------------|
| `supabase/vendor-portal.sql` | Creates `contractors`, `job_offers` and `network_settings` (the admin key), adds new columns to `bookings`, and sets up the trigger that sends each new booking to approved pros, the `portal_*` and `admin_*` functions, and the `job-photos` and `contractor-docs` buckets. Safe to run more than once. |
| `calendar.html` | Residential bookings use a scrolling list of days with 8 AM / 1 PM buttons, a pinned "preferred + two backups" header, Rush +$50 for tomorrow, Save 5% for 10+ days out, a price on each day, and a "We're finding your pro" screen. Consult links still use the month grid. |
| `admin.html` → **Pros** tab | Invite a pro (name, phone, email, pay rate) to get their link, with buttons to copy, text or email it. Review each pro's profile, insurance, W-9, workers' comp and signed terms, then Approve or Send back. Pause or reactivate pros, and change a pro's pay rate. The tab shows a badge when someone needs review. |
| `portal.html` | The pro's phone page. Until a pro is approved it shows onboarding: business info, service area, insurance upload, W-9 upload, workers' comp (certificate, or signed exemption if they have no employees), and the network terms with a checkbox and typed-name signature, then "We're reviewing your info". After approval: Jobs tab: New offers (payout, countdown, address with a map link, the three times; tap one, then Accept) and Upcoming jobs (customer name and phone, Mark complete with after photos). Payouts tab: amounts on the 3-day hold and amounts released. |
| `supabase/functions/bright-endpoint/index.ts` | New bookings get a "We're finding your pro" email. After a pro accepts, `portal.html` triggers a one-time "Jerry with Clearview took your Tuesday 8 AM" email. |

## Setup (needs a laptop or the Supabase dashboard)

1. **Run the SQL.** Supabase dashboard → SQL Editor → New query → paste all of
   `supabase/vendor-portal.sql` → Run.
2. **Get your admin key.** In the SQL Editor, run
   `select admin_key from network_settings;`. Open `admin.html` → Pros and paste
   it once. Keep it private: anyone with it can add and approve pros.
3. **Review the terms.** The network terms pros sign are a draft written for
   this build (`termsHtml()` in `portal.html`). Have them checked, ideally by a
   lawyer, before inviting anyone. If the wording changes after pros have
   signed, change `TERMS_VERSION` in `portal.html` and `_sm_terms_version()` in
   the SQL together.
4. **Invite your first pro** from admin → Pros, and text them the link. They
   finish onboarding on their phone, then you approve them.
5. **Redeploy the email function** so customers get the "finding your pro" and
   "pro took your time" emails instead of "You're booked!": Supabase → Edge
   Functions → `bright-endpoint` → paste the new `index.ts` → Deploy.

Until step 1 is done, `calendar.html` still saves bookings. The new columns
don't exist yet, so it leaves them out and writes the two backup times into the
booking's notes.

## Rules in the code (change in one place)

| Rule | Where |
|------|-------|
| 2-hour confirm window, starting when the customer books | `_sm_offer_window()` in the SQL, `CONFIRM_MINS` in `calendar.html` |
| Platform hours 8 AM to 7 PM Oklahoma time, Monday to Friday (the window only counts down inside them) | `_sm_hours_open()` / `_sm_hours_close()` / `_sm_tz()` in the SQL, `PLATFORM_OPEN` / `PLATFORM_CLOSE` in `calendar.html`. Keep the two in sync. |
| 3-day payout hold | `_sm_payout_hold()` in the SQL |
| Pro keeps 90% of the rush fee | `_sm_rush_pro_share()` in the SQL |
| Pro's share of the job price | `contractors.payout_rate`, one per pro. Set it when you invite them; change it from admin → Pros. New pros default to 70%. |
| Terms version pros sign | `TERMS_VERSION` in `portal.html` and `_sm_terms_version()` in the SQL |
| Rush +$50 (next business day), Save 5% at 10+ days | `RUSH_FEE`, `SAVE_PCT`, `SAVE_DAYS` in `calendar.html` |

## How it behaves

- The booking's `date_iso` / `time` / `total` start as the customer's preferred
  pick. If the pro accepts a backup time, they switch to that pick. This keeps
  availability checks and `admin.html` working unchanged.
- Only the preferred time blocks availability until a pro accepts. With one
  pro, a backup time can be taken by someone else in the meantime; accepting it
  then fails with "That time was just taken".
- Each offer's deadline (`job_offers.expires_at`) is set when the customer
  books: 2 hours, counting only 8 AM to 7 PM on weekdays. For example, a 3 PM
  booking is due at 5 PM, a 6:30 PM booking at 9:30 AM, and an 11 PM booking at
  10 AM. A Friday 6:30 PM booking is due Monday 9:30 AM, and any weekend booking
  is due Monday 10 AM. The
  customer's screen and email give the exact time. Overnight, the portal shows
  "Answer by 9:30 AM" instead of a long countdown.
- If no pro accepts by the deadline, or every pro declines, the booking's
  `status` becomes `no_pro` so you can follow up. `admin.html` doesn't show this
  yet.
- No same-day jobs: the list starts tomorrow. Rush (+$50) is the next business
  day: tomorrow, or Monday when booked Friday or over the weekend.
  A slot is hidden if the pro's deadline would land after it starts, so after
  5 PM tomorrow's 8 AM disappears and tomorrow's 1 PM stays. After 5 PM on
  Friday, and all weekend, Monday's 8 AM disappears.
- A pro's pay rate is shown in the terms they sign. If you change it later,
  open offers use the new rate, jobs they've already accepted keep their
  payout, and you should tell them about the change.
- Pros see the customer's phone and last name only after they accept.
- Pro statuses: `invited` (link sent) → `submitted` (waiting for you) →
  `approved` (gets offers) ⇄ `paused`. "Send back" returns a submitted pro to
  `invited` so they can fix something. Only approved pros get offers or see
  jobs. Pros who aren't approved can be removed; approved pros can only be paused.
- Insurance certificates, W-9s and workers' comp documents go to the private `contractor-docs` bucket,
  in a folder named after the pro's id. Nothing on the website can read them.
  View them in Supabase → Storage → contractor-docs. Uploads are only accepted
  into the folder of a pro who is still onboarding.
- The admin actions (`admin_*`) check the admin key, not `ADMIN_PASSWORD`,
  because that password is visible in `admin.html`'s source.

## Not built yet

- Text message (SMS) notice when a pro accepts. Email only for now.
- Showing `status` / `no_pro` and the after photos in `admin.html`.
- Editing a pro's details from `admin.html`, and an insurance expiry date or
  reminder.
- Which Oklahoma workers' comp exemption form to accept: check with your
  insurance agent. The portal takes any signed exemption as a file.
- Viewing a pro's insurance, W-9 or workers' comp from `admin.html`. Use the Supabase dashboard.
- Stripe payouts and complaint handling before pay is released.
- Multi-pro availability (a slot is still "taken" by one booking site-wide).
- Security note: anyone with the site key can upload to `job-photos` (they can't
  read or list it). Tighten this before the network grows.
