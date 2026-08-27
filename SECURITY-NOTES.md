# Security notes

A quick audit of what's publicly visible in this repo (client-side keys,
hardcoded secrets). Parked here to revisit — nothing urgent since Stripe
invoicing isn't live yet, but worth closing out before it is.

## 1. Supabase key — fine, no action needed

`sb_publishable_...` in `admin.html`, `calendar.html`, `consult.html`,
`index.html`. This is a publishable key, meant to be public — it's only as
safe as the Row Level Security policies on the tables it can reach. Not a
leak.

## 2. Google Maps API key — verify restrictions

`AIzaSyCrEnJzvM5RCL_Y_TOymjadeQdmgB1swI8`, hardcoded in `admin.html`,
`calendar.html`, `consult.html`. Maps JavaScript API keys have to live in
client-side code, so being visible isn't itself a mistake — but it needs to
be **restricted** in Google Cloud Console:
- HTTP referrer restriction to `sudsmonkey.github.io` (and any custom
  domain in use)
- API restriction to just the Maps JavaScript API + Places API

Without those restrictions, anyone who copies the key out of the page
source could use it elsewhere and run up the Google Cloud bill on this
account. **Action:** confirm both restrictions are set in Google Cloud
Console — two-minute check.

## 3. Admin password — real risk, revisit before invoicing goes live

`ADMIN_PASSWORD = 'Lux13lux31'` in `admin.html`, hardcoded in plaintext,
visible to anyone who views source on the live site or browses this public
repo. Unlike the two above, this one is *supposed* to be secret — it's the
only barrier in front of:

- Customer PII (names, phones, emails, addresses) in the Bookings tab
- Full booking/calendar control (block/unblock slots, move dates, mark
  complete)
- Price editing on any booking
- The Stripe "Send Invoice" button, once live — sends a real payment
  request to a real customer

It was originally accepted as "not real security, just keeps casual
visitors out" (see the comment in `admin.html` above `ADMIN_PASSWORD`) back
when the worst case was someone poking at slot availability. That bar is
lower than what the admin panel now guards, especially once invoicing is
live and real money moves through a "Send Invoice" tap.

**Options to revisit before going live with invoicing:**
- Move the check server-side (a Supabase Edge Function that verifies the
  password and returns a session token, rather than comparing a hardcoded
  string in the browser)
- At minimum, treat `Lux13lux31` as burned (visible in a public repo) and
  rotate it to something not reused anywhere else, even if the mechanism
  stays client-side for now

No other stray secrets, `.env` files, or credentials found elsewhere in the
repo as of this audit.
