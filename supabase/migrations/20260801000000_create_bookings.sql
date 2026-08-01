-- Suds Monkey bookings table
-- Run this in the Supabase SQL Editor (Dashboard → SQL → New query),
-- or via `supabase db push` if you use the CLI.

create extension if not exists "pgcrypto";

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  first_name text not null,
  last_name text not null,
  email text not null,
  phone text not null,
  address text,
  package text,
  total text,
  date text,
  time text,
  add_ons text,
  wizard_answers text,
  monkey_bonus text,
  notes text
);

comment on table public.bookings is 'Customer booking requests from calendar.html';

alter table public.bookings enable row level security;

-- Website can insert bookings with the anon key; nobody can read via anon.
drop policy if exists "Allow public booking inserts" on public.bookings;
create policy "Allow public booking inserts"
  on public.bookings
  for insert
  to anon, authenticated
  with check (true);

-- Optional: let signed-in dashboard users read rows later.
-- Uncomment if you add Supabase Auth for an admin view.
-- create policy "Allow authenticated read"
--   on public.bookings
--   for select
--   to authenticated
--   using (true);

create index if not exists bookings_created_at_idx on public.bookings (created_at desc);
create index if not exists bookings_email_idx on public.bookings (email);
