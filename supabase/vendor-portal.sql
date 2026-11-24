-- ============================================================================
-- Suds Monkey Network: vendor portal
-- ============================================================================
-- Paste this whole file into Supabase: Dashboard -> SQL Editor -> New query ->
-- Run. It is safe to run more than once.
--
-- What it sets up:
--   * contractors   -- the pros. Each has a private access_code that logs
--                      them into portal.html. Invite-only: you add a pro in
--                      admin.html, they finish their profile (service area,
--                      insurance, W-9, terms) in the portal, you approve.
--   * network_settings -- holds the admin key that admin.html's Pros tab
--                      needs. (The admin password in admin.html is visible
--                      in the page source, so it can't guard these.)
--   * job_offers    -- one row per booking offered to a pro, with the
--                      2-hour confirm window and the 3-day payout hold.
--   * new columns on bookings -- the customer's three picked times.
--   * a trigger     -- every new residential booking from calendar.html is
--                      offered to every active pro automatically.
--   * portal_* functions -- the only way portal.html reads or changes
--                      anything. The tables themselves stay closed to the
--                      public key, so nobody can list addresses or offers
--                      without a valid access code.
--   * admin_* functions -- add / approve / pause pros. Need the admin key.
--   * storage buckets: job-photos ("Mark complete" after photos) and
--                      contractor-docs (insurance + W-9; private).
--
-- After running it, get your admin key with the query at the very bottom.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. contractors
-- ---------------------------------------------------------------------------
create table if not exists public.contractors (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  company_name  text,                    -- pros keep their own business names
  phone         text,
  email         text,
  service_area  text,                    -- ZIP codes / areas they cover, as they typed it
  -- invited   -> added by you, hasn't finished their profile
  -- submitted -> profile, insurance, W-9 and terms in; waiting for you
  -- approved  -> gets job offers
  -- paused    -> no offers, can't use the portal's job screens
  status        text not null default 'invited'
                check (status in ('invited','submitted','approved','paused')),
  -- Private login code for portal.html. Generated automatically.
  access_code   text not null unique default replace(gen_random_uuid()::text, '-', ''),
  insurance_path text,                   -- contractor-docs/<id>/...
  w9_path        text,                   -- contractor-docs/<id>/...
  comp_type      text check (comp_type in ('policy','exempt')),  -- workers' comp: has a policy, or signed exemption (no employees)
  comp_path      text,                   -- contractor-docs/<id>/... certificate or signed exemption
  -- This pro's share of the job price before any rush fee, 0 to 1 (0.70 = 70%).
  -- Set when you invite them (they see it in the terms they sign); change it
  -- from admin.html -> Pros.
  payout_rate    numeric(4,3) not null default 0.70 check (payout_rate >= 0 and payout_rate <= 1),
  terms_version  text,
  terms_signature text,                  -- the full name they typed
  terms_accepted_at timestamptz,
  submitted_at   timestamptz,
  approved_at    timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.contractors add column if not exists comp_type text check (comp_type in ('policy','exempt'));
alter table public.contractors add column if not exists comp_path text;
-- Order pros are asked in (1 first). Set in admin.html -> Pros.
alter table public.contractors add column if not exists rank int;
alter table public.contractors add column if not exists payout_rate numeric(4,3) not null default 0.70
  check (payout_rate >= 0 and payout_rate <= 1);

-- One row. admin_key is what you enter once in admin.html's Pros tab.
create table if not exists public.network_settings (
  id        int primary key default 1 check (id = 1),
  admin_key text not null default replace(gen_random_uuid()::text, '-', '')
);
insert into public.network_settings (id) values (1) on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 2. new columns on bookings
-- ---------------------------------------------------------------------------
-- date_iso / time / date / total keep meaning "the booked slot". They start as
-- the customer's preferred pick and are switched to whichever pick the pro
-- accepts, so admin.html and the availability checks keep working unchanged.
alter table public.bookings add column if not exists status text;            -- null (old/consult rows), 'pending', 'countered', 'accepted', 'no_pro'
alter table public.bookings add column if not exists pick_options jsonb;     -- [{date_iso, time, date, price, rush}, x3], preferred first
alter table public.bookings add column if not exists base_total numeric;     -- package + add-ons before rush/save pricing
alter table public.bookings add column if not exists accepted_notified boolean not null default false;
-- Ranked offers / counters (section 7)
alter table public.bookings add column if not exists pro_deadline timestamptz;           -- the pros' shared 2 hours end here
alter table public.bookings add column if not exists counter_options jsonb;              -- lead pro's times sent to the customer
alter table public.bookings add column if not exists counter_contractor_id uuid;
alter table public.bookings add column if not exists counter_expires_at timestamptz;     -- customer's 2 hours to pick
alter table public.bookings add column if not exists customer_token text unique;         -- respond.html?t=...
alter table public.bookings add column if not exists counter_notified boolean not null default false;
alter table public.bookings add column if not exists no_pro_notified boolean not null default false;


-- ---------------------------------------------------------------------------
-- 3. job_offers
-- ---------------------------------------------------------------------------
-- booking_id has to match bookings.id's type, which this repo doesn't record,
-- so it is read from the live table.
do $$
declare
  id_type text;
begin
  if to_regclass('public.job_offers') is not null then
    return;
  end if;
  select format_type(a.atttypid, a.atttypmod) into id_type
    from pg_attribute a
   where a.attrelid = 'public.bookings'::regclass and a.attname = 'id';

  execute format($f$
    create table public.job_offers (
      id               uuid primary key default gen_random_uuid(),
      booking_id       %s not null references public.bookings(id) on delete cascade,
      contractor_id    uuid not null references public.contractors(id) on delete cascade,
      status           text not null default 'offered'
                       check (status in ('offered','accepted','declined','expired','taken')),
      offered_at       timestamptz not null default now(),   -- when the customer booked; see expires_at below
      responded_at     timestamptz,
      accepted_option  int,                                  -- 0 = preferred, 1 = alt 1, 2 = alt 2
      payout           numeric,                              -- set when accepted
      completed_at     timestamptz,                          -- "Mark complete"; starts the 3-day hold
      photo_paths      text[],
      created_at       timestamptz not null default now(),
      unique (booking_id, contractor_id)
    )$f$, id_type);
end $$;

create index if not exists job_offers_contractor_idx on public.job_offers (contractor_id, status);

-- Ranked offers (section 7). round 1 = the lead (top-ranked) pro; round 2 =
-- the next pros, one at a time.
alter table public.job_offers add column if not exists round int not null default 1;
-- Which of the customer's times (0 preferred, 1, 2) this pro may take.
alter table public.job_offers add column if not exists allowed_options int[] not null default '{0,1,2}';
-- 'held': the lead can do this alternate if nobody below takes the preferred time.
alter table public.job_offers add column if not exists held_option int;
-- The lead's own times (up to 2) when none of the customer's work.
alter table public.job_offers add column if not exists counter_options jsonb;
alter table public.job_offers add column if not exists notified_at timestamptz;          -- pro emailed about this offer
alter table public.job_offers add column if not exists won_notified boolean not null default false;
alter table public.job_offers drop constraint if exists job_offers_status_check;
alter table public.job_offers add constraint job_offers_status_check
  check (status in ('offered','held','accepted','declined','expired','taken'));


-- ---------------------------------------------------------------------------
-- 4. lock the new tables
-- ---------------------------------------------------------------------------
-- RLS on with no policies = the public (anon) key can't read or write them
-- directly. portal.html goes through the functions below instead.
alter table public.contractors      enable row level security;
alter table public.job_offers       enable row level security;
alter table public.network_settings enable row level security;


-- ---------------------------------------------------------------------------
-- 5. settings
-- ---------------------------------------------------------------------------
create or replace function public._sm_offer_window() returns interval
  language sql immutable as $$ select interval '2 hours' $$;
create or replace function public._sm_payout_hold() returns interval
  language sql immutable as $$ select interval '3 days' $$;
drop function if exists public._sm_payout_rate();   -- replaced by contractors.payout_rate (one per pro)
-- RUSH_PRO_SHARE: share of the rush surcharge the pro gets.
create or replace function public._sm_rush_pro_share() returns numeric
  language sql immutable as $$ select 0.90::numeric $$;
-- Platform hours: the confirm window only counts down between these times,
-- Monday to Friday, Oklahoma time. A booking at 6:30 PM gets 30 min tonight +
-- 90 min from 8 AM = due 9:30 AM; a Friday 6:30 PM booking is due Monday
-- 9:30 AM. calendar.html mirrors these values
-- (PLATFORM_OPEN / PLATFORM_CLOSE) to hide slots a pro couldn't confirm in time.
-- Version of the network terms pros agree to in the portal. Bump this when
-- the wording in portal.html (TERMS_VERSION) changes.
create or replace function public._sm_terms_version() returns text
  language sql immutable as $$ select 'v1-draft'::text $$;
create or replace function public._sm_tz() returns text
  language sql immutable as $$ select 'America/Chicago'::text $$;
create or replace function public._sm_hours_open() returns time
  language sql immutable as $$ select time '08:00' $$;
create or replace function public._sm_hours_close() returns time
  language sql immutable as $$ select time '19:00' $$;

-- The lead (top-ranked) pro's share of the 2 hours; the rest goes to the
-- next pros.
create or replace function public._sm_lead_window() returns interval
  language sql immutable as $$ select interval '1 hour' $$;
-- Customer's time to pick one of the lead pro's counter times.
create or replace function public._sm_counter_window() returns interval
  language sql immutable as $$ select interval '2 hours' $$;
-- Save discount on counter times (mirror SAVE_PCT / SAVE_DAYS in calendar.html).
create or replace function public._sm_save_pct() returns numeric
  language sql immutable as $$ select 0.05::numeric $$;
create or replace function public._sm_save_days() returns int
  language sql immutable as $$ select 10 $$;
create or replace function public._sm_slots() returns text[]
  language sql immutable as $$ select array['8:00 AM','1:00 PM'] $$;
-- For alert emails (pg_net -> the bright-endpoint function). Public values.
create or replace function public._sm_fn_url() returns text
  language sql immutable as $$ select 'https://ykjkcegpwiqhpfcgkwro.supabase.co/functions/v1/bright-endpoint'::text $$;
create or replace function public._sm_public_key() returns text
  language sql immutable as $$ select 'sb_publishable_wVwjixnqqbFjjJqH7f9nhA_qHGpE4md'::text $$;

-- p_start + p_window, counting only platform hours on weekdays (the clock
-- stops nights and weekends).
create or replace function public._sm_add_business_time(p_start timestamptz, p_window interval) returns timestamptz
  language plpgsql stable as $$
declare
  t         timestamp := p_start at time zone _sm_tz();   -- local wall-clock
  remaining interval  := p_window;
  day_open  timestamp;
  day_close timestamp;
begin
  loop
    if extract(isodow from t) >= 6 then             -- Saturday / Sunday
      t := date_trunc('day', t) + interval '1 day' + _sm_hours_open();
      continue;
    end if;
    day_open  := date_trunc('day', t) + _sm_hours_open();
    day_close := date_trunc('day', t) + _sm_hours_close();
    if t < day_open then
      t := day_open;
    elsif t >= day_close then
      t := date_trunc('day', t) + interval '1 day' + _sm_hours_open();
      continue;
    end if;
    if t + remaining <= day_close then
      return (t + remaining) at time zone _sm_tz();
    end if;
    remaining := remaining - (day_close - t);
    t := date_trunc('day', t) + interval '1 day' + _sm_hours_open();
  end loop;
end $$;

create or replace function public._sm_business_deadline(p_start timestamptz) returns timestamptz
  language sql stable as $$ select public._sm_add_business_time(p_start, public._sm_offer_window()) $$;

-- Each offer's deadline is fixed when it is made (when the customer books).
alter table public.job_offers add column if not exists expires_at timestamptz;
alter table public.job_offers alter column expires_at set default public._sm_business_deadline(now());
update public.job_offers set expires_at = public._sm_business_deadline(offered_at) where expires_at is null;


-- ---------------------------------------------------------------------------
-- 6. helpers
-- ---------------------------------------------------------------------------
-- Any pro with a valid code (used while onboarding).
create or replace function public._sm_contractor_login(p_code text) returns public.contractors
  language plpgsql security definer set search_path = public as $$
declare
  c contractors;
begin
  select * into c from contractors where access_code = p_code;
  if not found then
    raise exception 'invalid access code' using errcode = '28000';
  end if;
  return c;
end $$;

-- Only approved pros can see and work jobs.
create or replace function public._sm_contractor(p_code text) returns public.contractors
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor_login(p_code);
begin
  if c.status <> 'approved' then
    raise exception 'not approved yet' using errcode = '28000';
  end if;
  return c;
end $$;

create or replace function public._sm_admin(p_key text) returns void
  language plpgsql security definer set search_path = public as $$
begin
  if p_key is null or not exists (select 1 from network_settings where admin_key = p_key) then
    raise exception 'invalid admin key' using errcode = '28000';
  end if;
end $$;

-- What the pro earns for one of the customer's picks.
drop function if exists public._sm_payout(jsonb);
create or replace function public._sm_payout(p_option jsonb, p_rate numeric) returns numeric
  language sql immutable as $$
  select round(
    (coalesce((p_option->>'price')::numeric, 0) - coalesce((p_option->>'rush')::numeric, 0)) * p_rate
    + coalesce((p_option->>'rush')::numeric, 0) * _sm_rush_pro_share()
  , 2)
$$;

-- ---------------------------------------------------------------------------
-- 7. the offer engine: ranked pros, holds, counters
-- ---------------------------------------------------------------------------
-- A new booking goes to pros one at a time, in rank order, within a shared
-- 2 hours (weekday platform hours):
--  * Lead (rank 1) gets ~1 hour and sees all 3 customer times.
--      - takes the preferred time -> booked.
--      - can only do an alternate -> 'held'; the next pro is offered ONLY
--        the preferred time. If nobody takes it, the lead gets the alternate.
--      - can't do any -> may propose up to 2 of their own times; the next
--        pro may take ANY of the customer's 3 times.
--  * Next pros (rank 2, 3, ...) get the rest of the 2 hours, one at a time.
--  * Nobody takes a customer time: the lead's held alternate wins; else the
--    customer gets the lead's times (2 hours to pick, no rush fee, Save
--    still applies); else -> 'no_pro' for Levi.
-- If the lead is the only approved pro, they can take any time directly.

-- Queue an email through the bright-endpoint function (pg_net). Does nothing
-- if pg_net isn't enabled; alerts then just don't go out.
create or replace function public._sm_notify(p_body jsonb) returns void
  language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'net' and p.proname = 'http_post') then
    return;
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)'
    using _sm_fn_url(), p_body,
          jsonb_build_object('Content-Type', 'application/json',
                             'Authorization', 'Bearer ' || _sm_public_key(),
                             'apikey', _sm_public_key());
exception when others then
  raise warning 'notify failed: %', sqlerrm;
end $$;

-- Is this slot free for booking p_booking (no other live booking, no block)?
create or replace function public._sm_slot_free(p_booking_id text, p_date text, p_time text) returns boolean
  language sql stable security definer set search_path = public as $$
  select not exists (select 1 from bookings x
                      where x.id::text <> p_booking_id and x.date_iso::text = p_date and x.time = p_time
                        and coalesce(x.status, '') not in ('no_pro'))
     and not exists (select 1 from blocked_slots s where s.date::text = p_date and s.time = p_time)
$$;

-- Approved pros in the order they're asked.
create or replace function public._sm_next_pro(p_booking_id text) returns uuid
  language sql stable security definer set search_path = public as $$
  select c.id from contractors c
   where c.status = 'approved'
     and not exists (select 1 from job_offers o where o.booking_id::text = p_booking_id and o.contractor_id = c.id)
   order by c.rank nulls last, c.created_at
   limit 1
$$;

-- Give the job to offer p_offer_id at option p_opt (a customer pick, or a
-- counter time). Closes every other offer on the booking.
create or replace function public._sm_assign(p_offer_id uuid, p_opt jsonb, p_idx int) returns numeric
  language plpgsql security definer set search_path = public as $$
declare
  o   job_offers;
  pay numeric;
begin
  select * into o from job_offers where id = p_offer_id;
  pay := _sm_payout(p_opt, (select payout_rate from contractors where id = o.contractor_id));
  update job_offers
     set status = 'accepted', responded_at = now(), accepted_option = p_idx, payout = pay
   where id = o.id;
  update job_offers
     set status = 'taken', responded_at = now()
   where booking_id = o.booking_id and id <> o.id and status in ('offered', 'held');
  update bookings
     set status   = 'accepted',
         date_iso = (p_opt->>'date_iso')::date,
         time     = p_opt->>'time',
         date     = coalesce(p_opt->>'date', date),
         total    = '$' || (p_opt->>'price')
   where id = o.booking_id;
  perform _sm_notify(jsonb_build_object('type', 'accepted', 'booking_id', o.booking_id));
  return pay;
end $$;

-- Offer the booking to a pro.
create or replace function public._sm_offer(p_booking_id text, p_pro uuid, p_round int, p_allowed int[], p_expires timestamptz) returns void
  language plpgsql security definer set search_path = public as $$
declare
  new_id uuid;
begin
  execute format('insert into job_offers (booking_id, contractor_id, round, allowed_options, expires_at)
                  select b.id, $1, $2, $3, $4 from bookings b where b.id::text = $5 returning id')
    into new_id using p_pro, p_round, p_allowed, p_expires, p_booking_id;
  perform _sm_notify(jsonb_build_object('type', 'offer', 'offer_id', new_id));
end $$;

-- Move a booking along: expire overdue turns, ask the next pro, or resolve.
-- Safe to call any time; called after every pro/customer action and by the
-- every-minute tick.
create or replace function public._sm_advance(p_booking_id text) returns void
  language plpgsql security definer set search_path = public as $$
declare
  b       bookings;
  lead    job_offers;
  nxt     uuid;
  n_other int;
  opt     jsonb;
  base    numeric;
  today_d date := (now() at time zone _sm_tz())::date;
begin
  select * into b from bookings where id::text = p_booking_id for update;
  if not found then return; end if;

  if b.status = 'countered' then
    if b.counter_expires_at < now() then
      update bookings set status = 'no_pro' where id = b.id;
      perform _sm_notify(jsonb_build_object('type', 'no_pro', 'booking_id', b.id));
    end if;
    return;
  end if;
  if coalesce(b.status, '') <> 'pending' then return; end if;
  if exists (select 1 from job_offers where booking_id = b.id and status = 'accepted') then
    return;                                                  -- already has a pro
  end if;

  update job_offers set status = 'expired', responded_at = now()
   where booking_id = b.id and status = 'offered' and expires_at < now();
  if exists (select 1 from job_offers where booking_id = b.id and status = 'offered') then
    return;                                                  -- someone's turn
  end if;

  select * into lead from job_offers where booking_id = b.id and round = 1;
  if not found then
    -- Start: offer to the top-ranked pro.
    if b.pro_deadline is null then
      update bookings set pro_deadline = _sm_add_business_time(now(), _sm_offer_window())
       where id = b.id returning * into b;
    end if;
    nxt := _sm_next_pro(p_booking_id);
    if nxt is null then
      update bookings set status = 'no_pro' where id = b.id;
      perform _sm_notify(jsonb_build_object('type', 'no_pro', 'booking_id', b.id));
      return;
    end if;
    select count(*) into n_other from contractors where status = 'approved' and id <> nxt;
    perform _sm_offer(p_booking_id, nxt, 1, '{0,1,2}',
      case when n_other > 0 then least(_sm_add_business_time(now(), _sm_lead_window()), b.pro_deadline)
           else b.pro_deadline end);
    return;
  end if;

  -- The lead has answered (or run out of time). Next pro, while time remains.
  if now() < b.pro_deadline then
    nxt := _sm_next_pro(p_booking_id);
    if nxt is not null then
      perform _sm_offer(p_booking_id, nxt, 2,
        case when lead.status = 'held' then '{0}'::int[] else '{0,1,2}'::int[] end,
        b.pro_deadline);
      return;
    end if;
  end if;

  -- Nobody below took it.
  if lead.status = 'held' then
    opt := b.pick_options -> lead.held_option;
    if _sm_slot_free(p_booking_id, opt->>'date_iso', opt->>'time') then
      perform _sm_assign(lead.id, opt, lead.held_option);
      perform _sm_notify(jsonb_build_object('type', 'won', 'offer_id', lead.id));
      return;
    end if;
  end if;

  if lead.counter_options is not null and jsonb_array_length(lead.counter_options) > 0 then
    base := coalesce(b.base_total, nullif(regexp_replace(coalesce(b.total, ''), '[^0-9.]', '', 'g'), '')::numeric);
    update bookings set
      status = 'countered',
      counter_contractor_id = lead.contractor_id,
      counter_expires_at = _sm_add_business_time(now(), _sm_counter_window()),
      customer_token = coalesce(customer_token, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
      counter_options = (
        select jsonb_agg(jsonb_build_object(
                 'date_iso', c->>'date_iso',
                 'time',     c->>'time',
                 'date',     to_char((c->>'date_iso')::date, 'FMMonth FMDD, YYYY'),
                 'rush',     0,
                 'price',    case when base is null then null
                                  when (c->>'date_iso')::date - today_d >= _sm_save_days()
                                  then round(base * (1 - _sm_save_pct()))
                                  else base end)
               order by ord)
          from jsonb_array_elements(lead.counter_options) with ordinality as e(c, ord))
    where id = b.id;
    perform _sm_notify(jsonb_build_object('type', 'counter', 'booking_id', b.id));
    return;
  end if;

  update bookings set status = 'no_pro' where id = b.id;
  perform _sm_notify(jsonb_build_object('type', 'no_pro', 'booking_id', b.id));
end $$;

-- Every open booking. Run every minute by pg_cron (section 12), and before
-- any portal or customer read so nothing waits on the cron.
create or replace function public._sm_tick() returns void
  language plpgsql security definer set search_path = public as $$
declare
  bid text;
begin
  for bid in select id::text from bookings where status in ('pending', 'countered') loop
    perform _sm_advance(bid);
  end loop;
end $$;

-- Kept for older callers.
create or replace function public._sm_expire_offers() returns void
  language sql security definer set search_path = public as $$ select public._sm_tick() $$;

-- New residential bookings from calendar.html start the chain.
create or replace function public._sm_offer_new_booking() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then
    perform _sm_advance(new.id::text);
  end if;
  return new;
end $$;

drop trigger if exists sm_offer_new_booking on public.bookings;
create trigger sm_offer_new_booking
  after insert on public.bookings
  for each row execute function public._sm_offer_new_booking();



-- ---------------------------------------------------------------------------
-- 8. portal functions (the only things the public key may call)
-- ---------------------------------------------------------------------------

-- Who's logged in, and where they are in onboarding.
create or replace function public.portal_me(p_code text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor_login(p_code);
begin
  return json_build_object(
    'id', c.id, 'name', c.name, 'company_name', c.company_name,
    'phone', c.phone, 'email', c.email, 'service_area', c.service_area,
    'status', c.status,
    'has_insurance', c.insurance_path is not null,
    'has_w9', c.w9_path is not null,
    'comp_type', c.comp_type,
    'has_comp', c.comp_path is not null,
    'payout_rate', c.payout_rate,
    'rush_share', _sm_rush_pro_share(),
    'terms_version', _sm_terms_version());
end $$;

-- Onboarding: the pro's profile, documents and signed terms. Moves them to
-- 'submitted' for you to review. They can resubmit until you approve.
drop function if exists public.portal_submit_profile(text, text, text, text, text, text, text, text, text);
create or replace function public.portal_submit_profile(
  p_code text, p_company text, p_phone text, p_email text, p_service_area text,
  p_insurance_path text, p_w9_path text, p_comp_type text, p_comp_path text,
  p_signature text, p_terms_version text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor_login(p_code);
  prefix text := c.id::text || '/';
begin
  if c.status not in ('invited', 'submitted') then
    raise exception 'Your profile is already approved. Call Suds Monkey to change it.';
  end if;
  if coalesce(trim(p_phone), '') = '' or coalesce(trim(p_email), '') = '' then
    raise exception 'Add your phone and email.';
  end if;
  if coalesce(trim(p_service_area), '') = '' then
    raise exception 'Add the areas you cover.';
  end if;
  if coalesce(p_insurance_path, c.insurance_path) is null or coalesce(p_insurance_path, c.insurance_path) not like prefix || '%' then
    raise exception 'Upload your insurance certificate.';
  end if;
  if coalesce(p_w9_path, c.w9_path) is null or coalesce(p_w9_path, c.w9_path) not like prefix || '%' then
    raise exception 'Upload your W-9.';
  end if;
  if p_comp_type is null or p_comp_type not in ('policy', 'exempt') then
    raise exception 'Choose your workers'' comp option.';
  end if;
  if coalesce(p_comp_path, c.comp_path) is null or coalesce(p_comp_path, c.comp_path) not like prefix || '%'
     or (p_comp_path is null and c.comp_type is distinct from p_comp_type) then   -- switched option: needs the matching document
    raise exception 'Upload your workers'' comp certificate or signed exemption.';
  end if;
  if p_terms_version is distinct from _sm_terms_version() then
    raise exception 'The terms were updated. Refresh the page and review them again.';
  end if;
  if length(coalesce(trim(p_signature), '')) < 3 then
    raise exception 'Type your full name to sign the terms.';
  end if;

  update contractors set
    company_name      = nullif(trim(p_company), ''),
    phone             = trim(p_phone),
    email             = trim(p_email),
    service_area      = trim(p_service_area),
    insurance_path    = coalesce(p_insurance_path, insurance_path),
    w9_path           = coalesce(p_w9_path, w9_path),
    comp_type         = p_comp_type,
    comp_path         = coalesce(p_comp_path, comp_path),
    terms_version     = p_terms_version,
    terms_signature   = trim(p_signature),
    terms_accepted_at = now(),
    submitted_at      = now(),
    status            = 'submitted'
  where id = c.id;
  return json_build_object('ok', true);
end $$;

-- Everything portal.html shows: open offers, holds, counters waiting on the
-- customer, upcoming jobs, payouts.
create or replace function public.portal_jobs(p_code text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor(p_code);
  others_waiting boolean;
  result json;
begin
  perform _sm_tick();

  select coalesce(json_agg(j order by j.sort_key), '[]'::json) into result
  from (
    select
      o.id,
      o.booking_id,
      o.status,
      o.round,
      o.allowed_options,
      o.held_option,
      o.counter_options,
      -- 'lead': top pro with others behind them (alternates are holds);
      -- 'solo': only pro (can take any time); 'next': lower-ranked pro.
      case when o.round > 1 then 'next'
           when exists (select 1 from contractors x where x.status = 'approved' and x.id <> c.id
                          and not exists (select 1 from job_offers y where y.booking_id = o.booking_id and y.contractor_id = x.id))
             then 'lead'
           else 'solo' end                                   as mode,
      o.offered_at,
      o.expires_at,
      b.pro_deadline,
      b.status                                               as booking_status,
      case when b.status = 'countered' then b.counter_expires_at end as counter_expires_at,
      o.accepted_option,
      o.payout,
      o.completed_at,
      case when o.completed_at is not null
           then o.completed_at + _sm_payout_hold() end      as released_at,
      coalesce(array_length(o.photo_paths, 1), 0)           as photo_count,
      b.package,
      b.add_ons,
      b.address,
      b.notes,
      b.first_name,
      b.date_iso,
      b.time,
      -- Contact details only once the pro has the job.
      case when o.status = 'accepted' then b.last_name end as last_name,
      case when o.status = 'accepted' then b.phone end     as phone,
      (select json_agg(opt || jsonb_build_object('payout', _sm_payout(opt, c.payout_rate)) order by ord)
         from jsonb_array_elements(b.pick_options) with ordinality as e(opt, ord)) as options,
      (select json_agg(opt || jsonb_build_object('payout', _sm_payout(opt, c.payout_rate)) order by ord)
         from jsonb_array_elements(case when b.status = 'countered' then b.counter_options end) with ordinality as e(opt, ord)) as counter_priced,
      coalesce(b.date_iso::text, '') || ' ' || o.offered_at::text as sort_key
    from job_offers o
    join bookings b on b.id = o.booking_id
    where o.contractor_id = c.id
      and (o.status in ('offered', 'held', 'accepted')
           or (o.status = 'declined' and b.status = 'countered' and b.counter_contractor_id = c.id))
  ) j;

  return result;
end $$;

-- Take one of the customer's times. For the lead with other pros behind
-- them, an alternate (1 or 2) becomes a hold: the next pro gets a shot at
-- the preferred time first.
create or replace function public.portal_accept(p_code text, p_offer_id uuid, p_option int) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c   contractors := _sm_contractor(p_code);
  o   job_offers;
  b   bookings;
  opt jsonb;
  pay numeric;
begin
  perform _sm_tick();

  select * into o from job_offers where id = p_offer_id and contractor_id = c.id for update;
  if not found then raise exception 'offer not found'; end if;
  if o.status = 'expired' then raise exception 'This offer has expired.'; end if;
  if o.status <> 'offered' then raise exception 'This offer is no longer open.'; end if;

  select * into b from bookings where id = o.booking_id for update;
  if coalesce(b.status, '') <> 'pending' then raise exception 'Another pro already took this job.'; end if;

  if not (p_option = any (o.allowed_options)) then
    raise exception 'That time isn''t open to you on this job.';
  end if;
  opt := b.pick_options -> p_option;
  if opt is null then raise exception 'That time is not one of the customer''s picks.'; end if;
  if not _sm_slot_free(b.id::text, opt->>'date_iso', opt->>'time') then
    raise exception 'That time was just taken. Pick another of the customer''s times.';
  end if;

  if o.round = 1 and p_option > 0 and _sm_next_pro(b.id::text) is not null then
    update job_offers set status = 'held', held_option = p_option, responded_at = now() where id = o.id;
    perform _sm_advance(b.id::text);
    return json_build_object('ok', true, 'held', true, 'date', opt->>'date', 'time', opt->>'time',
                             'payout', _sm_payout(opt, c.payout_rate));
  end if;

  pay := _sm_assign(o.id, opt, p_option);
  return json_build_object('ok', true, 'payout', pay, 'date', opt->>'date', 'time', opt->>'time');
end $$;

-- Can't do it. The lead (round 1) may send up to 2 of their own times
-- ([{date_iso, time}, ...]); the customer sees them only if no other pro can
-- do the customer's times.
drop function if exists public.portal_decline(text, uuid);
create or replace function public.portal_decline(p_code text, p_offer_id uuid, p_counter jsonb default null) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c   contractors := _sm_contractor(p_code);
  o   job_offers;
  b   bookings;
  t   jsonb;
  d   date;
  today_d date := (now() at time zone _sm_tz())::date;
  clean jsonb := '[]'::jsonb;
begin
  perform _sm_tick();
  select * into o from job_offers where id = p_offer_id and contractor_id = c.id and status = 'offered' for update;
  if not found then raise exception 'This offer is no longer open.'; end if;
  select * into b from bookings where id = o.booking_id;

  if p_counter is not null and jsonb_typeof(p_counter) = 'array' and jsonb_array_length(p_counter) > 0 then
    if o.round <> 1 then raise exception 'Only the first pro asked can suggest other times.'; end if;
    if jsonb_array_length(p_counter) > 2 then raise exception 'Suggest up to 2 times.'; end if;
    for t in select * from jsonb_array_elements(p_counter) loop
      begin
        d := (t->>'date_iso')::date;
      exception when others then
        raise exception 'Pick a date for each time.';
      end;
      if not ((t->>'time') = any (_sm_slots())) then raise exception 'Times must be 8 AM or 1 PM.'; end if;
      if d <= today_d or d > today_d + 60 then raise exception 'Pick days from tomorrow to 60 days out.'; end if;
      -- The customer may get up to 2 hours (after the pros' time is up) to
      -- pick, so the time must start after that.
      if ((d + to_timestamp(t->>'time', 'HH:MI AM')::time) at time zone _sm_tz())
         <= _sm_add_business_time(greatest(b.pro_deadline, now()), _sm_counter_window()) then
        raise exception 'That time is too soon for the customer to answer. Pick a later one.';
      end if;
      if extract(isodow from d) >= 6 then raise exception 'Pick weekdays only.'; end if;
      if exists (select 1 from jsonb_array_elements(b.pick_options) p
                  where p->>'date_iso' = d::text and p->>'time' = t->>'time') then
        raise exception 'That''s one of the customer''s times. Accept it instead.';
      end if;
      if clean @> jsonb_build_array(jsonb_build_object('date_iso', d::text, 'time', t->>'time')) then
        raise exception 'Pick two different times.';
      end if;
      if not _sm_slot_free(b.id::text, d::text, t->>'time') then
        raise exception 'That time is already booked. Pick another.';
      end if;
      clean := clean || jsonb_build_array(jsonb_build_object('date_iso', d::text, 'time', t->>'time'));
    end loop;
  end if;

  update job_offers
     set status = 'declined', responded_at = now(),
         counter_options = case when jsonb_array_length(clean) > 0 then clean end
   where id = o.id;
  perform _sm_advance(b.id::text);
  return json_build_object('ok', true, 'countered', jsonb_array_length(clean) > 0);
end $$;

-- "Mark complete" after the after-photos are uploaded. Starts the 3-day hold.
create or replace function public.portal_complete(p_code text, p_offer_id uuid, p_photo_paths text[]) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor(p_code);
begin
  if coalesce(array_length(p_photo_paths, 1), 0) = 0 then
    raise exception 'Add at least one after photo.';
  end if;
  update job_offers
     set completed_at = now(), photo_paths = p_photo_paths
   where id = p_offer_id and contractor_id = c.id and status = 'accepted' and completed_at is null;
  if not found then raise exception 'This job can''t be marked complete.'; end if;
  update bookings set completed = true
   where id = (select booking_id from job_offers where id = p_offer_id);
  return json_build_object('ok', true, 'released_at', now() + _sm_payout_hold());
end $$;


-- ---------------------------------------------------------------------------
-- 8b. customer counter page (respond.html?t=TOKEN)
-- ---------------------------------------------------------------------------
-- The token is long and random, sent only in the customer's email.
create or replace function public.customer_counter(p_token text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  if coalesce(length(p_token), 0) < 32 then raise exception 'link not found'; end if;
  select * into b from bookings where customer_token = p_token;
  if not found then raise exception 'link not found'; end if;
  perform _sm_advance(b.id::text);
  select * into b from bookings where id = b.id;
  return json_build_object(
    'status', b.status, 'first_name', b.first_name, 'package', b.package,
    'picked', b.pick_options, 'options', b.counter_options, 'base_price', b.base_total,
    'expires_at', b.counter_expires_at,
    'booked', case when b.status = 'accepted' then json_build_object('date_iso', b.date_iso, 'time', b.time, 'total', b.total) end);
end $$;

create or replace function public.customer_pick(p_token text, p_option int) returns json
  language plpgsql security definer set search_path = public as $$
declare
  b   bookings;
  o   job_offers;
  opt jsonb;
begin
  if coalesce(length(p_token), 0) < 32 then raise exception 'link not found'; end if;
  select * into b from bookings where customer_token = p_token;
  if not found then raise exception 'link not found'; end if;
  perform _sm_advance(b.id::text);
  select * into b from bookings where id = b.id for update;
  if b.status = 'accepted' then raise exception 'You''re already booked.'; end if;
  if b.status <> 'countered' then raise exception 'These times have expired. Call or text us at (405) 882-2277.'; end if;
  opt := b.counter_options -> p_option;
  if opt is null then raise exception 'Pick one of the times shown.'; end if;
  if not _sm_slot_free(b.id::text, opt->>'date_iso', opt->>'time') then
    raise exception 'That time was just taken. Pick the other one, or call us.';
  end if;
  select * into o from job_offers where booking_id = b.id and contractor_id = b.counter_contractor_id;
  perform _sm_assign(o.id, opt, null);
  perform _sm_notify(jsonb_build_object('type', 'won', 'offer_id', o.id));
  return json_build_object('ok', true, 'date', opt->>'date', 'time', opt->>'time', 'total', '$' || (opt->>'price'));
end $$;

create or replace function public.customer_decline_counter(p_token text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  if coalesce(length(p_token), 0) < 32 then raise exception 'link not found'; end if;
  select * into b from bookings where customer_token = p_token for update;
  if not found then raise exception 'link not found'; end if;
  if b.status = 'countered' then
    update bookings set status = 'no_pro' where id = b.id;
    perform _sm_notify(jsonb_build_object('type', 'no_pro', 'booking_id', b.id));
  end if;
  return json_build_object('ok', true);
end $$;


-- ---------------------------------------------------------------------------
-- 9. admin functions (admin.html's Pros tab; need the admin key)
-- ---------------------------------------------------------------------------
create or replace function public.admin_pros(p_key text) returns json
  language plpgsql security definer set search_path = public as $$
begin
  perform _sm_admin(p_key);
  return (select coalesce(json_agg(row_to_json(x) order by
             array_position(array['submitted','invited','approved','paused'], x.status), x.rank nulls last, x.created_at desc), '[]'::json)
          from (select id, name, company_name, phone, email, service_area, status, access_code, payout_rate, rank,
                       insurance_path, w9_path, comp_type, comp_path, terms_version, terms_signature, terms_accepted_at,
                       submitted_at, approved_at, created_at,
                       (select count(*) from job_offers o where o.contractor_id = c.id and o.status = 'accepted') as jobs_taken
                  from contractors c) x);
end $$;

drop function if exists public.admin_invite_pro(text, text, text, text);
create or replace function public.admin_invite_pro(p_key text, p_name text, p_phone text, p_email text, p_rate numeric) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors;
begin
  perform _sm_admin(p_key);
  if coalesce(trim(p_name), '') = '' then raise exception 'Add their name.'; end if;
  if p_rate is null or p_rate <= 0 or p_rate > 1 then raise exception 'Set their pay rate (1 to 100%%).'; end if;
  insert into contractors (name, phone, email, payout_rate)
  values (trim(p_name), nullif(trim(p_phone), ''), nullif(trim(p_email), ''), p_rate)
  returning * into c;
  return json_build_object('id', c.id, 'access_code', c.access_code);
end $$;

-- Change a pro's pay rate. Applies to offers they haven't accepted yet;
-- accepted jobs keep the payout they were accepted at.
create or replace function public.admin_set_pro_rate(p_key text, p_id uuid, p_rate numeric) returns json
  language plpgsql security definer set search_path = public as $$
begin
  perform _sm_admin(p_key);
  if p_rate is null or p_rate <= 0 or p_rate > 1 then raise exception 'Pay rate must be 1 to 100%%.'; end if;
  update contractors set payout_rate = p_rate where id = p_id;
  if not found then raise exception 'Pro not found.'; end if;
  return json_build_object('ok', true);
end $$;

-- approve (from submitted or paused) / pause (from approved).
create or replace function public.admin_set_pro_status(p_key text, p_id uuid, p_status text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors;
begin
  perform _sm_admin(p_key);
  select * into c from contractors where id = p_id for update;
  if not found then raise exception 'Pro not found.'; end if;
  if p_status = 'approved' and c.status in ('submitted', 'paused') then
    update contractors set status = 'approved', approved_at = coalesce(approved_at, now()),
           rank = coalesce(rank, (select coalesce(max(rank), 0) + 1 from contractors where status = 'approved'))
     where id = p_id;
  elsif p_status = 'paused' and c.status = 'approved' then
    update contractors set status = 'paused' where id = p_id;
  elsif p_status = 'invited' and c.status = 'submitted' then
    -- send back for fixes (e.g. expired insurance); they resubmit in the portal
    update contractors set status = 'invited' where id = p_id;
  else
    raise exception 'Can''t change % to %.', c.status, p_status;
  end if;
  return json_build_object('ok', true);
end $$;

-- Set the order pros are asked in: p_ids first to last (approved pros).
create or replace function public.admin_set_pro_order(p_key text, p_ids uuid[]) returns json
  language plpgsql security definer set search_path = public as $$
begin
  perform _sm_admin(p_key);
  update contractors c set rank = x.ord
    from unnest(p_ids) with ordinality as x(id, ord)
   where c.id = x.id;
  return json_build_object('ok', true);
end $$;

-- Remove a pro who never got approved (typo, changed their mind).
create or replace function public.admin_delete_pro(p_key text, p_id uuid) returns json
  language plpgsql security definer set search_path = public as $$
begin
  perform _sm_admin(p_key);
  delete from contractors where id = p_id and status in ('invited', 'submitted');
  if not found then raise exception 'Only pros who aren''t approved yet can be removed. Pause them instead.'; end if;
  return json_build_object('ok', true);
end $$;

-- Storage policy helper: uploads to contractor-docs must go in the folder of
-- a pro who is still onboarding.
create or replace function public._sm_doc_upload_ok(p_name text) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from contractors
                  where id::text = split_part(p_name, '/', 1)
                    and status in ('invited', 'submitted'))
$$;


-- ---------------------------------------------------------------------------
-- 10. who may call what
-- ---------------------------------------------------------------------------
revoke all on function public._sm_contractor(text)            from public, anon, authenticated;
revoke all on function public._sm_contractor_login(text)      from public, anon, authenticated;
revoke all on function public._sm_admin(text)                 from public, anon, authenticated;
revoke all on function public._sm_expire_offers()             from public, anon, authenticated;
revoke all on function public._sm_offer_new_booking()         from public, anon, authenticated;
revoke all on function public._sm_advance(text)               from public, anon, authenticated;
revoke all on function public._sm_tick()                      from public, anon, authenticated;
revoke all on function public._sm_assign(uuid, jsonb, int)    from public, anon, authenticated;
revoke all on function public._sm_offer(text, uuid, int, int[], timestamptz) from public, anon, authenticated;
revoke all on function public._sm_notify(jsonb)               from public, anon, authenticated;

grant execute on function public.portal_me(text)                       to anon;
grant execute on function public.portal_jobs(text)                     to anon;
grant execute on function public.portal_accept(text, uuid, int)        to anon;
grant execute on function public.portal_decline(text, uuid, jsonb)     to anon;
grant execute on function public.customer_counter(text)                to anon;
grant execute on function public.customer_pick(text, int)              to anon;
grant execute on function public.customer_decline_counter(text)        to anon;
grant execute on function public.portal_complete(text, uuid, text[])   to anon;
grant execute on function public.portal_submit_profile(text, text, text, text, text, text, text, text, text, text, text) to anon;
grant execute on function public.admin_pros(text)                      to anon;
grant execute on function public.admin_invite_pro(text, text, text, text, numeric) to anon;
grant execute on function public.admin_set_pro_rate(text, uuid, numeric) to anon;
grant execute on function public.admin_set_pro_status(text, uuid, text) to anon;
grant execute on function public.admin_delete_pro(text, uuid)          to anon;
grant execute on function public.admin_set_pro_order(text, uuid[])     to anon;
grant execute on function public._sm_doc_upload_ok(text)               to anon;


-- ---------------------------------------------------------------------------
-- 11. storage
-- ---------------------------------------------------------------------------
-- Private bucket: anyone with the site key can upload, nobody can list or
-- download through it. You view photos in the Supabase dashboard (Storage).
insert into storage.buckets (id, name, public)
values ('job-photos', 'job-photos', false)
on conflict (id) do nothing;

drop policy if exists "job photos upload" on storage.objects;
create policy "job photos upload" on storage.objects
  for insert to anon
  with check (bucket_id = 'job-photos');

-- Insurance certificates and W-9s (W-9s carry SSNs/EINs). Private: nothing
-- on the website can read them. View them in Supabase -> Storage ->
-- contractor-docs -> <pro id>.
insert into storage.buckets (id, name, public)
values ('contractor-docs', 'contractor-docs', false)
on conflict (id) do nothing;

drop policy if exists "contractor docs upload" on storage.objects;
create policy "contractor docs upload" on storage.objects
  for insert to anon
  with check (bucket_id = 'contractor-docs' and public._sm_doc_upload_ok(name));


-- ---------------------------------------------------------------------------
-- 12. background tick + alert emails
-- ---------------------------------------------------------------------------
-- pg_cron moves bookings along every minute (a pro's turn ends, the customer
-- runs out of time) even when nobody has the portal open. pg_net lets the
-- database send the alert emails (new offer to a pro, the customer's counter
-- times, "you got the job", no pro found). If either can't be enabled here,
-- turn them on in Supabase -> Database -> Extensions and run this file again.
do $$
begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net not enabled (%): alert emails are off until it is', sqlerrm;
end $$;

do $$
begin
  create extension if not exists pg_cron;
  if exists (select 1 from cron.job where jobname = 'suds-network-tick') then
    perform cron.unschedule('suds-network-tick');
  end if;
  perform cron.schedule('suds-network-tick', '* * * * *', 'select public._sm_tick()');
exception when others then
  raise notice 'pg_cron not enabled (%): bookings only move along when someone opens the portal', sqlerrm;
end $$;


-- ============================================================================
-- 13. YOUR ADMIN KEY
-- ============================================================================
-- Run this on its own to see the key, then enter it once in admin.html ->
-- Pros. Keep it private (it can add and approve pros). To change it:
--   update public.network_settings set admin_key = replace(gen_random_uuid()::text, '-', '');
--
-- select admin_key from public.network_settings;
