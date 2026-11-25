-- ============================================================================
-- Suds Monkey: booking funnel + Squeege Master 3000 tracking
-- ============================================================================
-- Paste into Supabase -> SQL Editor -> Run. Safe to run more than once.
-- Works on its own or alongside supabase/vendor-portal.sql (they share the
-- admin key in network_settings).
--
-- The site logs one row per step to funnel_events: an anonymous per-visit
-- session id (random, kept in the browser tab's sessionStorage), the step,
-- a short detail (e.g. "stories:2", "gorilla"), and a timestamp. No names,
-- emails, phones, addresses or IP addresses are stored.
--
-- The public site key can only INSERT rows. Reading them takes the admin key
-- (admin.html -> Funnel, via admin_funnel()).
-- ============================================================================

create table if not exists public.funnel_events (
  id          bigint generated always as identity primary key,
  session_id  text not null check (length(session_id) between 8 and 64),
  event       text not null check (event in (
                'landing',          -- first page of the visit (detail = page)
                'segment',          -- residential or commercial flow opened
                'wizard_answer',    -- a quote question answered (detail = question:answer)
                'price_shown',      -- residential prices unlocked (detail = quote | storm)
                'package_picked',   -- detail = package
                'time_picker_open', -- booking calendar opened
                'time_picked',      -- detail = which pick (Preferred, Alt 1, ...)
                'book_tap',         -- tapped the Book / Confirm button
                'booked',           -- booking saved
                'game_start',       -- Squeege Master: picked a tool for the first time
                'game_window_done', -- finished a window (value = windows so far)
                'game_end'          -- left the game (value = seconds played)
              )),
  detail      text check (length(detail) <= 80),
  value       numeric,
  page        text check (length(page) <= 40),
  created_at  timestamptz not null default now()
);
create index if not exists funnel_events_time_idx on public.funnel_events (created_at);
create index if not exists funnel_events_session_idx on public.funnel_events (session_id, created_at);

alter table public.funnel_events enable row level security;
drop policy if exists "funnel insert" on public.funnel_events;
create policy "funnel insert" on public.funnel_events for insert to anon with check (true);
grant insert on public.funnel_events to anon;
revoke select, update, delete on public.funnel_events from anon;

-- Admin key (shared with the vendor portal; created there too).
create table if not exists public.network_settings (
  id        int primary key default 1 check (id = 1),
  admin_key text not null default replace(gen_random_uuid()::text, '-', '')
);
insert into public.network_settings (id) values (1) on conflict do nothing;
alter table public.network_settings enable row level security;


-- ---------------------------------------------------------------------------
-- admin_funnel: the report behind admin.html -> Funnel
-- ---------------------------------------------------------------------------
-- p_days:    look back this many days
-- p_segment: 'residential', 'commercial' or 'all' (sessions are grouped by the
--            flow they opened; 'all' includes visits that never opened one)
create or replace function public.admin_funnel(p_key text, p_days int, p_segment text) returns json
  language plpgsql security definer set search_path = public as $$
declare
  since  timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
  result json;
begin
  if p_key is null or not exists (select 1 from network_settings where admin_key = p_key) then
    raise exception 'invalid admin key' using errcode = '28000';
  end if;

  with ev as (
    select * from funnel_events where created_at >= since
  ),
  seg as (       -- each session's flow: the first one it opened
    select distinct on (session_id) session_id, detail as segment
      from ev where event = 'segment' order by session_id, created_at
  ),
  scoped as (
    select ev.* from ev left join seg using (session_id)
     where coalesce(p_segment, 'all') = 'all' or seg.segment = p_segment
  ),
  steps(ord, event, label) as (
    values (1, 'landing', 'Landed on the site'),
           (2, 'segment', 'Chose residential or commercial'),
           (3, 'wizard_answer', 'Answered a quote question'),
           (4, 'price_shown', 'Saw their price'),
           (5, 'package_picked', 'Picked a package'),
           (6, 'time_picker_open', 'Opened the time picker'),
           (7, 'time_picked', 'Picked a time'),
           (8, 'book_tap', 'Tapped Book'),
           (9, 'booked', 'Booking saved')
  ),
  step_counts as (
    select s.ord, s.event, s.label,
           (select count(distinct session_id) from scoped e where e.event = s.event) as sessions
      from steps s
     -- commercial has no price step
     where not (p_segment = 'commercial' and s.event = 'price_shown')
  ),
  questions as (
    select split_part(detail, ':', 1) as question, count(distinct session_id) as sessions
      from scoped where event = 'wizard_answer' group by 1
  ),
  games as (
    select session_id, min(created_at) as started from ev where event = 'game_start' group by 1
  ),
  game_stats as (
    select
      count(*) as games,
      round(avg((select max(value) from ev e where e.session_id = g.session_id and e.event = 'game_end'))) as avg_seconds,
      count(*) filter (where exists (select 1 from ev e where e.session_id = g.session_id and e.event = 'game_window_done')) as finished_window,
      count(*) filter (where exists (select 1 from ev e where e.session_id = g.session_id and e.event = 'segment' and e.created_at >= g.started)) as started_booking,
      count(*) filter (where exists (select 1 from ev e where e.session_id = g.session_id and e.event = 'booked' and e.created_at >= g.started)) as booked
    from games g
  )
  select json_build_object(
    'since', since,
    'segment', coalesce(p_segment, 'all'),
    'steps', (select json_agg(json_build_object('event', event, 'label', label, 'sessions', sessions) order by ord) from step_counts),
    'questions', (select coalesce(json_agg(json_build_object('question', question, 'sessions', sessions) order by sessions desc, question), '[]'::json) from questions),
    'game', (select row_to_json(game_stats) from game_stats)
  ) into result;
  return result;
end $$;

revoke all on function public.admin_funnel(text, int, text) from public;
grant execute on function public.admin_funnel(text, int, text) to anon;

-- Your admin key, if you don't have it yet:
-- select admin_key from public.network_settings;
