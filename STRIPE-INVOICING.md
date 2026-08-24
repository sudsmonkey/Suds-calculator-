# Stripe invoicing

Lets you send a real, live Stripe invoice straight from a booking card in
`admin.html` — tap **Send Invoice**, confirm the amount/email, and Stripe
emails the customer a payment link. It's manual and per-booking (not
automatic on Mark Complete), so you decide when it fires.

## Why this needs a separate piece

`admin.html` is a static page with no backend — anything in its JS is
visible to anyone who looks. Stripe's secret key can never live there; it
has to stay server-side. The fix is a **Supabase Edge Function**
(`send-invoice`) that holds the key and talks to Stripe on the site's
behalf. The browser only ever calls that function, never Stripe directly.

This mirrors the confirmation-email setup already in place
(`bright-endpoint`, used by `calendar.html`/`consult.html`) — same idea,
new function.

## One-time setup

1. **Get your Stripe secret key** — Stripe Dashboard → Developers → API
   keys → copy the **Secret key** (`sk_live_...`). Not the publishable one.

2. **Create the Edge Function** — Supabase Dashboard → your project → Edge
   Functions → Deploy a new function → name it exactly `send-invoice` →
   paste in the code below → Deploy.

3. **Add the key as a secret** — same Edge Functions area → Secrets → add
   `STRIPE_SECRET_KEY` set to your `sk_live_...` value. This is the whole
   reason to do it this way: the key lives here, never in the repo.

4. **Run this SQL once** (Supabase → SQL Editor) so the app remembers which
   bookings are already invoiced:
   ```sql
   alter table public.bookings add column if not exists invoice_url text;
   alter table public.bookings add column if not exists stripe_invoice_id text;
   ```

That's it — "Send Invoice" on any booking card in admin.html will work
after this.

## How it behaves

- Tapping **Send Invoice** shows a `confirm()` dialog with the dollar
  amount and customer email before anything happens — a real Stripe
  invoice goes out immediately after you confirm.
- Once sent, the card remembers `invoice_url` / `stripe_invoice_id` and
  swaps the button for a **View Invoice** link, so the same job can't be
  double-invoiced by an accidental second tap.
- The amount comes from the booking's `total` field; the description is
  the package name + date.
- Manual/blocked-work cards don't get this button — there's no customer
  email attached to those.

## The Edge Function code

```typescript
// Supabase Edge Function: send-invoice
// Creates (or reuses) a Stripe customer, then creates, finalizes, and sends
// a live Stripe invoice -- Stripe emails the customer a payment link
// directly. The Stripe secret key lives only here, as an Edge Function
// secret, and never reaches the browser.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const { email, name, amount, description } = await req.json();
    if (!email || !amount) {
      return new Response(JSON.stringify({ error: 'email and amount are required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY');
    if (!STRIPE_SECRET_KEY) {
      return new Response(JSON.stringify({ error: 'Stripe is not configured on the server' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const stripeHeaders = {
      Authorization: 'Bearer ' + STRIPE_SECRET_KEY,
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    // 1. Find an existing customer by email, or create one.
    let customerId;
    const searchRes = await fetch(
      'https://api.stripe.com/v1/customers?email=' + encodeURIComponent(email) + '&limit=1',
      { headers: { Authorization: 'Bearer ' + STRIPE_SECRET_KEY } }
    );
    const searchData = await searchRes.json();
    if (!searchRes.ok) throw new Error(searchData.error?.message || 'Could not look up Stripe customer');

    if (searchData.data && searchData.data.length) {
      customerId = searchData.data[0].id;
    } else {
      const custRes = await fetch('https://api.stripe.com/v1/customers', {
        method: 'POST',
        headers: stripeHeaders,
        body: new URLSearchParams({ email, name: name || '' }),
      });
      const custData = await custRes.json();
      if (!custRes.ok) throw new Error(custData.error?.message || 'Could not create Stripe customer');
      customerId = custData.id;
    }

    // 2. Create the invoice line item.
    const amountCents = Math.round(Number(amount) * 100);
    const itemRes = await fetch('https://api.stripe.com/v1/invoiceitems', {
      method: 'POST',
      headers: stripeHeaders,
      body: new URLSearchParams({
        customer: customerId,
        amount: String(amountCents),
        currency: 'usd',
        description: description || 'Window cleaning service',
      }),
    });
    const itemData = await itemRes.json();
    if (!itemRes.ok) throw new Error(itemData.error?.message || 'Could not create invoice item');

    // 3. Create the invoice (send_invoice = customer pays via a link, not
    //    an auto-charge -- days_until_due gives them a week).
    const invRes = await fetch('https://api.stripe.com/v1/invoices', {
      method: 'POST',
      headers: stripeHeaders,
      body: new URLSearchParams({
        customer: customerId,
        collection_method: 'send_invoice',
        days_until_due: '7',
      }),
    });
    const invData = await invRes.json();
    if (!invRes.ok) throw new Error(invData.error?.message || 'Could not create invoice');

    // 4. Finalize it -- locks in the line items and generates the PDF/link.
    const finRes = await fetch('https://api.stripe.com/v1/invoices/' + invData.id + '/finalize', {
      method: 'POST',
      headers: stripeHeaders,
    });
    const finData = await finRes.json();
    if (!finRes.ok) throw new Error(finData.error?.message || 'Could not finalize invoice');

    // 5. Send it -- Stripe emails the customer directly from here.
    const sendRes = await fetch('https://api.stripe.com/v1/invoices/' + invData.id + '/send', {
      method: 'POST',
      headers: stripeHeaders,
    });
    const sendData = await sendRes.json();
    if (!sendRes.ok) throw new Error(sendData.error?.message || 'Could not send invoice');

    return new Response(
      JSON.stringify({ invoice_id: sendData.id, invoice_url: sendData.hosted_invoice_url }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
```

## Client side (already done, live on `main`)

`admin.html` already has the "Send Invoice" button, the `confirm()` guard,
and the call to `/functions/v1/send-invoice`. Nothing else to change there
unless the invoicing behavior itself needs to evolve (e.g. auto-invoice on
Mark Complete instead of manual — deliberately *not* built that way per an
explicit decision to keep it opt-in per job).
