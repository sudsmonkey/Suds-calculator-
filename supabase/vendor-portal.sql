-- ============================================================================
-- Suds Monkey Network: vendor portal, step 1
-- ============================================================================
-- Paste this whole file into Supabase: Dashboard -> SQL Editor -> New query ->
-- Run. It is safe to run more than once.
--
-- What it sets up:
--   * contractors   -- the pros. Each has a private access_code that logs
--                      them into portal.html.
--   * job_offers    -- one row per booking offered to a pro, with the
--                      2-hour confirm window and the 3-day payout hold.
--   * new columns on bookings -- the customer's three picked times.
--   * a trigger     -- every new residential booking from calendar.html is
--                      offered to every active pro automatically.
--   * portal_* functions -- the only way portal.html reads or changes
--                      anything. The tables themselves stay closed to the
--                      public key, so nobody can list addresses or offers
--                      without a valid access code.
--   * a job-photos storage bucket for the "Mark complete" after photos.
--
-- After running it, add your first pro at the very bottom of this file.
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
  service_area  text,
  active        boolean not null default true,
  -- Share of the job price (before any rush fee) the pro is paid, 0 to 1.
  -- 0.70 = 70%. The rush fee is paid separately at 90% (see RUSH_PRO_SHARE).
  payout_rate   numeric(4,3) not null check (payout_rate >= 0 and payout_rate <= 1),
  -- Private login code for portal.html. Generated automatically.
  access_code   text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_at    timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 2. new columns on bookings
-- ---------------------------------------------------------------------------
-- date_iso / time / date / total keep meaning "the booked slot". They start as
-- the customer's preferred pick and are switched to whichever pick the pro
-- accepts, so admin.html and the availability checks keep working unchanged.
alter table public.bookings add column if not exists status text;            -- null (old/consult rows), 'pending', 'accepted', 'no_pro'
alter table public.bookings add column if not exists pick_options jsonb;     -- [{date_iso, time, date, price, rush}, x3], preferred first
alter table public.bookings add column if not exists base_total numeric;     -- package + add-ons before rush/save pricing
alter table public.bookings add column if not exists accepted_notified boolean not null default false;


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
      offered_at       timestamptz not null default now(),   -- drives the 2-hour confirm window
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


-- ---------------------------------------------------------------------------
-- 4. lock the new tables
-- ---------------------------------------------------------------------------
-- RLS on with no policies = the public (anon) key can't read or write them
-- directly. portal.html goes through the functions below instead.
alter table public.contractors enable row level security;
alter table public.job_offers  enable row level security;


-- ---------------------------------------------------------------------------
-- 5. settings
-- ---------------------------------------------------------------------------
create or replace function public._sm_offer_window() returns interval
  language sql immutable as $$ select interval '2 hours' $$;
create or replace function public._sm_payout_hold() returns interval
  language sql immutable as $$ select interval '3 days' $$;
-- RUSH_PRO_SHARE: share of the rush surcharge the pro gets.
create or replace function public._sm_rush_pro_share() returns numeric
  language sql immutable as $$ select 0.90::numeric $$;


-- ---------------------------------------------------------------------------
-- 6. offer every new pending booking to every active pro
-- ---------------------------------------------------------------------------
create or replace function public._sm_offer_new_booking() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then
    insert into job_offers (booking_id, contractor_id)
    select new.id, c.id from contractors c where c.active
    on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists sm_offer_new_booking on public.bookings;
create trigger sm_offer_new_booking
  after insert on public.bookings
  for each row execute function public._sm_offer_new_booking();


-- ---------------------------------------------------------------------------
-- 7. helpers
-- ---------------------------------------------------------------------------
create or replace function public._sm_contractor(p_code text) returns public.contractors
  language plpgsql security definer set search_path = public as $$
declare
  c contractors;
begin
  select * into c from contractors where access_code = p_code and active;
  if not found then
    raise exception 'invalid access code' using errcode = '28000';
  end if;
  return c;
end $$;

-- Marks offers whose 2-hour window has run out, and flags bookings that no
-- pro took so admin can follow up.
create or replace function public._sm_expire_offers() returns void
  language plpgsql security definer set search_path = public as $$
begin
  update job_offers
     set status = 'expired', responded_at = now()
   where status = 'offered' and offered_at + _sm_offer_window() < now();

  update bookings b
     set status = 'no_pro'
   where b.status = 'pending'
     and exists (select 1 from job_offers o where o.booking_id = b.id)
     and not exists (select 1 from job_offers o where o.booking_id = b.id and o.status in ('offered','accepted'));
end $$;

-- What the pro earns for one of the customer's picks.
create or replace function public._sm_payout(p_option jsonb, p_rate numeric) returns numeric
  language sql immutable as $$
  select round(
    (coalesce((p_option->>'price')::numeric, 0) - coalesce((p_option->>'rush')::numeric, 0)) * p_rate
    + coalesce((p_option->>'rush')::numeric, 0) * _sm_rush_pro_share()
  , 2)
$$;


-- ---------------------------------------------------------------------------
-- 8. portal functions (the only things the public key may call)
-- ---------------------------------------------------------------------------

-- Who's logged in.
create or replace function public.portal_me(p_code text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor(p_code);
begin
  return json_build_object('name', c.name, 'company_name', c.company_name);
end $$;

-- Everything portal.html shows: open offers, upcoming jobs, payouts.
create or replace function public.portal_jobs(p_code text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor(p_code);
  result json;
begin
  perform _sm_expire_offers();

  select coalesce(json_agg(j order by j.sort_key), '[]'::json) into result
  from (
    select
      o.id,
      o.booking_id,
      o.status,
      o.offered_at,
      o.offered_at + _sm_offer_window()                    as expires_at,
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
      coalesce(b.date_iso::text, '') || ' ' || o.offered_at::text as sort_key
    from job_offers o
    join bookings b on b.id = o.booking_id
    where o.contractor_id = c.id
      and o.status in ('offered','accepted')
  ) j;

  return result;
end $$;

-- Accept one of the customer's three times.
create or replace function public.portal_accept(p_code text, p_offer_id uuid, p_option int) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c   contractors := _sm_contractor(p_code);
  o   job_offers;
  b   bookings;
  opt jsonb;
  pay numeric;
begin
  perform _sm_expire_offers();

  select * into o from job_offers where id = p_offer_id and contractor_id = c.id for update;
  if not found then raise exception 'offer not found'; end if;
  if o.status = 'expired' then raise exception 'This offer has expired.'; end if;
  if o.status <> 'offered' then raise exception 'This offer is no longer open.'; end if;

  select * into b from bookings where id = o.booking_id for update;
  if coalesce(b.status, '') <> 'pending' then raise exception 'Another pro already took this job.'; end if;

  opt := b.pick_options -> p_option;
  if opt is null then raise exception 'That time is not one of the customer''s picks.'; end if;

  -- The slot must still be free (another booking or an admin block).
  if exists (select 1 from bookings x
              where x.id <> b.id and x.date_iso::text = opt->>'date_iso' and x.time = opt->>'time'
                and coalesce(x.status, '') <> 'no_pro')
     or exists (select 1 from blocked_slots s
              where s.date::text = opt->>'date_iso' and s.time = opt->>'time') then
    raise exception 'That time was just taken. Pick another of the customer''s times.';
  end if;

  pay := _sm_payout(opt, c.payout_rate);

  update job_offers
     set status = 'accepted', responded_at = now(), accepted_option = p_option, payout = pay
   where id = o.id;

  update job_offers
     set status = 'taken', responded_at = now()
   where booking_id = b.id and id <> o.id and status = 'offered';

  update bookings
     set status   = 'accepted',
         date_iso = (opt->>'date_iso')::date,
         time     = opt->>'time',
         date     = coalesce(opt->>'date', date),
         total    = '$' || (opt->>'price')
   where id = b.id;

  return json_build_object('ok', true, 'payout', pay, 'date', opt->>'date', 'time', opt->>'time');
end $$;

create or replace function public.portal_decline(p_code text, p_offer_id uuid) returns json
  language plpgsql security definer set search_path = public as $$
declare
  c contractors := _sm_contractor(p_code);
begin
  update job_offers
     set status = 'declined', responded_at = now()
   where id = p_offer_id and contractor_id = c.id and status = 'offered';
  if not found then raise exception 'This offer is no longer open.'; end if;
  perform _sm_expire_offers();
  return json_build_object('ok', true);
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
-- 9. who may call what
-- ---------------------------------------------------------------------------
revoke all on function public._sm_contractor(text)            from public, anon, authenticated;
revoke all on function public._sm_expire_offers()             from public, anon, authenticated;
revoke all on function public._sm_offer_new_booking()         from public, anon, authenticated;

grant execute on function public.portal_me(text)                       to anon;
grant execute on function public.portal_jobs(text)                     to anon;
grant execute on function public.portal_accept(text, uuid, int)        to anon;
grant execute on function public.portal_decline(text, uuid)            to anon;
grant execute on function public.portal_complete(text, uuid, text[])   to anon;


-- ---------------------------------------------------------------------------
-- 10. after-photo storage
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


-- ============================================================================
-- 11. ADD YOUR FIRST PRO
-- ============================================================================
-- Edit the values, then run just this statement (or leave it in and run the
-- whole file). payout_rate 0.70 = the pro keeps 70% of the job price; rush
-- fees are paid at 90% on top. The result shows their access_code: send them
-- https://sudsmonkey.github.io/Suds-calculator-/portal.html?code=THAT_CODE
--
-- insert into public.contractors (name, company_name, phone, email, service_area, payout_rate)
-- values ('Jerry Smith', 'Clearview', '(405) 555-0100', 'jerry@example.com', 'OKC metro', 0.70)
-- returning name, access_code;
