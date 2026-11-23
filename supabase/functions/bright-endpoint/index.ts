// Sends the customer confirmation + company notification for a booking or
// commercial consult. Both flows write to the same `bookings` table (see
// CLAUDE.md), so one function covers both -- residential vs commercial is
// told apart by `package` ("Site Visit" / "Phone Consultation" == commercial).
//
// Called directly by calendar.html/consult.html right after their booking
// INSERT succeeds, not via a Database Webhook -- keeps the whole flow in one
// place and avoids needing dashboard-side webhook config.
//
// Before sending, re-fetches the row from `bookings` with the service role
// key and requires an exact match on email/date_iso/time/package. The anon
// key this function's JWT check accepts is public (committed in the repo by
// design), so without this guard anyone could hit this endpoint directly and
// spam arbitrary "confirmation" emails through the business's Resend
// account. Requiring a real matching row means abuse costs an attacker a
// real row in the booking flow, not just a POST.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const FROM_EMAIL = "Suds Monkey Window Cleaning <bookings@sudsmonkey.io>";
const COMPANY_EMAIL = "levi@okcsuds.com";
const PHONE_DISPLAY = "(405) 882-2277";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const COMMERCIAL_PACKAGES = new Set(["Site Visit", "Phone Consultation"]);
function isCommercial(pkg: string) {
  return COMMERCIAL_PACKAGES.has(pkg);
}

function escapeHtml(s: unknown) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function row(label: string, value: unknown) {
  if (value === null || value === undefined || value === "") return "";
  return `<tr><td style="padding:4px 12px 4px 0;color:#7C7268;font-size:13px;white-space:nowrap;">${escapeHtml(label)}</td><td style="padding:4px 0;color:#3d3530;font-size:13px;font-weight:600;">${escapeHtml(value)}</td></tr>`;
}

function wrapEmail(heading: string, bodyHtml: string) {
  return `<div style="font-family:-apple-system,'Segoe UI',Roboto,sans-serif;max-width:480px;margin:0 auto;padding:24px;">
    <h1 style="font-size:20px;color:#A6382E;margin:0 0 16px;">${escapeHtml(heading)}</h1>
    ${bodyHtml}
    <p style="font-size:12px;color:#7C7268;margin-top:24px;">Suds Monkey Window Cleaning &middot; ${PHONE_DISPLAY}</p>
  </div>`;
}

type PickOption = { date_iso?: string; time?: string; date?: string; price?: number };

// "Tue, Nov 24" from "2026-11-24", without timezone drift.
function shortDay(iso: unknown) {
  const [y, m, d] = String(iso ?? "").slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return String(iso ?? "");
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
}
function longWeekday(iso: unknown) {
  const [y, m, d] = String(iso ?? "").slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return "";
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
}

function pickRows(b: Record<string, unknown>) {
  const opts = (Array.isArray(b.pick_options) ? b.pick_options : []) as PickOption[];
  const labels = ["Preferred", "Backup 1", "Backup 2"];
  return opts
    .map((o, i) => row(labels[i] ?? `Option ${i + 1}`, `${shortDay(o.date_iso)} at ${o.time ?? ""}${o.price != null ? ` ($${o.price})` : ""}`))
    .join("");
}

// Customer-facing copy stays neutral about who does the job (in-house or a
// network pro): "your Suds Monkey pro", never "our crew" or "contractor".
// See "Network language" in the Vendor Portal Notes doc.
//
// Set true to name the pro (and their company) in the "you're set" email.
const SHOW_PRO_NAME = false;

// "within 2 hours" when the deadline really is 2 hours away; otherwise the
// time (the clock pauses nights and weekends): "by 9:30 AM Monday".
function deadlineText(iso: unknown) {
  const d = new Date(String(iso ?? ""));
  if (isNaN(d.getTime())) return "within 2 hours";
  if (d.getTime() - Date.now() <= 2 * 3600000 + 60000) return "within 2 hours";
  const tz = "America/Chicago";
  const clock = d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: tz });
  const day = (x: Date) => x.toLocaleDateString("en-CA", { timeZone: tz });
  const tomorrow = new Date(Date.now() + 86400000);
  if (day(d) === day(new Date())) return `by ${clock} today`;
  if (day(d) === day(tomorrow)) return `by ${clock} tomorrow`;
  return `by ${clock} ${d.toLocaleDateString("en-US", { weekday: "long", timeZone: tz })}`;
}

// New residential bookings from calendar.html's pick-three flow aren't
// confirmed until a pro accepts (supabase/vendor-portal.sql).
function pendingCustomerEmail(b: Record<string, unknown>) {
  const by = deadlineText(b._deadline);
  const table = `<table style="border-collapse:collapse;width:100%;">
    ${pickRows(b)}
    ${row("Package", b.package)}
    ${row("Address", b.address)}
    ${row("Notes", b.notes)}
  </table>`;
  return {
    subject: "Got it! We're confirming your Suds Monkey time",
    html: wrapEmail(
      "Got it! We're confirming your time",
      `<p style="font-size:14px;color:#3d3530;">Thanks for booking! You'll hear back ${escapeHtml(by)} with your confirmed time. Here's what you picked:</p>${table}<p style="font-size:14px;color:#3d3530;">Questions? Call or text us at ${PHONE_DISPLAY}.</p>`,
    ),
  };
}

function acceptedCustomerEmail(b: Record<string, unknown>, pro: { name?: string; company_name?: string }) {
  const when = `${longWeekday(b.date_iso)} ${String(b.time ?? "").replace(":00", "")}`.trim();
  const headline = `Your Suds Monkey pro is set for ${when}`;
  const table = `<table style="border-collapse:collapse;width:100%;">
    ${row("Date", shortDay(b.date_iso))}
    ${row("Time", b.time)}
    ${SHOW_PRO_NAME ? row("Your pro", pro.company_name ? `${pro.name} (${pro.company_name})` : pro.name) : ""}
    ${row("Package", b.package)}
    ${row("Total", b.total)}
    ${row("Address", b.address)}
  </table>`;
  return {
    subject: headline,
    html: wrapEmail(
      headline,
      `<p style="font-size:14px;color:#3d3530;">You're booked. Here's the summary:</p>${table}<p style="font-size:14px;color:#3d3530;">Questions before then? Call or text us at ${PHONE_DISPLAY}.</p>`,
    ),
  };
}

function customerEmail(b: Record<string, unknown>) {
  if (b.status === "pending") return pendingCustomerEmail(b);
  const commercial = isCommercial(b.package as string);
  const heading = commercial ? "Your consultation is confirmed" : "You're booked!";
  const intro = commercial
    ? "Thanks for reaching out -- your consultation is on the calendar. Here's the summary:"
    : "Thanks for booking with us -- here's the summary:";
  const table = `<table style="border-collapse:collapse;width:100%;">
    ${row("Date", b.date)}
    ${row("Time", b.time)}
    ${row(commercial ? "Consultation type" : "Package", b.package)}
    ${!commercial ? row("Total", b.total) : ""}
    ${row("Address", b.address)}
    ${row("Notes", b.notes)}
  </table>`;
  return {
    subject: commercial ? "Your Suds Monkey consultation is confirmed" : "You're booked with Suds Monkey!",
    html: wrapEmail(heading, `<p style="font-size:14px;color:#3d3530;">${escapeHtml(intro)}</p>${table}<p style="font-size:14px;color:#3d3530;">Questions before then? Call or text us at ${PHONE_DISPLAY}.</p>`),
  };
}

function companyEmail(b: Record<string, unknown>) {
  const commercial = isCommercial(b.package as string);
  const table = `<table style="border-collapse:collapse;width:100%;">
    ${row("Name", `${b.first_name ?? ""} ${b.last_name ?? ""}`.trim())}
    ${row("Phone", b.phone)}
    ${row("Email", b.email)}
    ${row("Date", b.date)}
    ${row("Time", b.time)}
    ${row(commercial ? "Type" : "Package", b.package)}
    ${!commercial ? row("Total", b.total) : ""}
    ${row("Address", b.address)}
    ${row("Notes", b.notes)}
    ${b.status === "pending" ? pickRows(b) : ""}
  </table>`;
  return {
    subject: `New ${commercial ? "consult request" : b.status === "pending" ? "booking (offered to pros)" : "booking"}: ${b.first_name ?? ""} ${b.last_name ?? ""}`.trim(),
    html: wrapEmail(`New ${commercial ? "consult request" : "booking"}`, table),
  };
}

async function sendEmail(to: string, subject: string, html: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from: FROM_EMAIL, to, subject, html }),
  });
  if (!res.ok) {
    console.error("Resend send failed", res.status, await res.text());
  }
  return res.ok;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405, headers: CORS_HEADERS });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON" }), { status: 400, headers: CORS_HEADERS });
  }

  // portal.html calls this right after a pro accepts. Sends the customer
  // "Your Suds Monkey pro is set for <day> <time>" -- only for a booking a pro
  // really accepted, and only once (accepted_notified), so a direct POST
  // can't be used to spam.
  if (payload.type === "accepted") {
    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: b, error: bErr } = await sb
      .from("bookings")
      .select("*")
      .eq("id", payload.booking_id as string)
      .eq("status", "accepted")
      .eq("accepted_notified", false)
      .maybeSingle();
    if (bErr || !b) {
      return new Response(JSON.stringify({ error: "nothing to send" }), { status: 404, headers: CORS_HEADERS });
    }
    const { data: offer } = await sb
      .from("job_offers")
      .select("contractors(name, company_name)")
      .eq("booking_id", b.id)
      .eq("status", "accepted")
      .maybeSingle();
    const pro = ((offer as { contractors?: { name?: string; company_name?: string } } | null)?.contractors) ?? {};
    // Claim the send first so two quick calls can't both email.
    const { data: claimed } = await sb
      .from("bookings")
      .update({ accepted_notified: true })
      .eq("id", b.id)
      .eq("accepted_notified", false)
      .select("id");
    if (!claimed || claimed.length === 0) {
      return new Response(JSON.stringify({ error: "already sent" }), { status: 409, headers: CORS_HEADERS });
    }
    const msg = acceptedCustomerEmail(b, pro);
    const ok = b.email ? await sendEmail(b.email, msg.subject, msg.html) : false;
    const proLabel = pro.company_name ? `${pro.name} (${pro.company_name})` : (pro.name ?? "a pro");
    await sendEmail(COMPANY_EMAIL, `${proLabel} accepted: ${b.first_name ?? ""} ${b.last_name ?? ""}, ${shortDay(b.date_iso)} ${b.time ?? ""}`.trim(),
      wrapEmail(`${proLabel} accepted`, `<p style="font-size:14px;color:#3d3530;">The customer was sent:</p>${msg.html}`));
    return new Response(JSON.stringify({ ok: true, customerSent: ok }), {
      status: 200,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const { email, date_iso, time, package: pkg } = payload as Record<string, string>;
  if (!email || !date_iso || !time || !pkg) {
    return new Response(JSON.stringify({ error: "missing email/date_iso/time/package" }), { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: matches, error } = await supabase
    .from("bookings")
    .select("*")
    .eq("email", email)
    .eq("date_iso", date_iso)
    .eq("time", time)
    .eq("package", pkg)
    .limit(1);

  if (error) {
    console.error("lookup failed", error);
    return new Response(JSON.stringify({ error: "lookup failed" }), { status: 500, headers: CORS_HEADERS });
  }
  if (!matches || matches.length === 0) {
    return new Response(JSON.stringify({ error: "no matching booking found" }), { status: 404, headers: CORS_HEADERS });
  }

  const booking = matches[0];
  if (booking.status === "pending") {
    // The offer deadline counts only platform hours (8 AM-7 PM), so tell the
    // customer the actual time rather than "2 hours".
    const { data: offer } = await supabase
      .from("job_offers")
      .select("expires_at")
      .eq("booking_id", booking.id)
      .order("expires_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    booking._deadline = offer?.expires_at ?? null;
  }
  const cust = customerEmail(booking);
  const co = companyEmail(booking);

  const [custOk, coOk] = await Promise.all([
    sendEmail(booking.email, cust.subject, cust.html),
    sendEmail(COMPANY_EMAIL, co.subject, co.html),
  ]);

  return new Response(JSON.stringify({ ok: true, customerSent: custOk, companySent: coOk }), {
    status: 200,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
});
