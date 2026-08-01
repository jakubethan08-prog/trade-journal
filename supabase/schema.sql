-- A+ Trades — Supabase schema, RLS policies, storage bucket, and auto-profile trigger.
-- Run this whole file once in the Supabase SQL editor (Project → SQL Editor → New query → paste → Run).
-- Safe to re-run: every statement below is idempotent (create-if-not-exists,
-- or drop-then-recreate), so running it again after a partial failure or by
-- accident just converges to the same end state instead of erroring.

-- =========================================================================
-- profiles — one row per user, extends auth.users
-- =========================================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  subscription_status text not null default 'trialing'
    check (subscription_status in ('trialing', 'active', 'past_due', 'canceled')),
  stripe_customer_id text,
  stripe_subscription_id text,
  current_period_end timestamptz
);

alter table public.profiles enable row level security;

drop policy if exists "select own profile" on public.profiles;
create policy "select own profile" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Column-level lock: RLS above only restricts which ROWS a user can touch.
-- Without this, any signed-in user could PATCH their own subscription_status
-- to 'active' directly via the API and bypass the paywall entirely. Only the
-- webhook (using the service-role key, which ignores both RLS and grants)
-- may write the subscription columns — everyday users may only ever update
-- their display_name.
revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;

-- Auto-create a profile row the instant a new auth user is created, so the
-- app never has to race a client-side "create profile after signup" step.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, subscription_status, created_at)
  values (new.id, 'trialing', now());
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =========================================================================
-- trades
-- =========================================================================
create table if not exists public.trades (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  date date not null,
  symbol text,
  side text check (side in ('long', 'short')),
  pnl numeric not null,
  duration integer not null default 0,
  risk numeric,
  rr numeric,
  grade text check (grade in ('B-', 'B', 'B+', 'A-', 'A', 'A+', 'A++')),
  entry_type text not null default 'trade' check (entry_type in ('trade', 'payout')),
  created_at timestamptz not null default now()
);

create index if not exists trades_user_date_idx on public.trades (user_id, date);

alter table public.trades enable row level security;

drop policy if exists "select own trades" on public.trades;
create policy "select own trades" on public.trades
  for select using (auth.uid() = user_id);
drop policy if exists "insert own trades" on public.trades;
create policy "insert own trades" on public.trades
  for insert with check (auth.uid() = user_id);
drop policy if exists "update own trades" on public.trades;
create policy "update own trades" on public.trades
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "delete own trades" on public.trades;
create policy "delete own trades" on public.trades
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- journal_entries
-- =========================================================================
create table if not exists public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  date date not null,
  mood text not null check (mood in ('calm', 'confident', 'anxious', 'fomo', 'frustrated', 'flat')),
  feeling_detail text,
  conditions text,
  notes text,
  trade_id uuid references public.trades (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists journal_entries_user_date_idx on public.journal_entries (user_id, date);

alter table public.journal_entries enable row level security;

drop policy if exists "select own journal entries" on public.journal_entries;
create policy "select own journal entries" on public.journal_entries
  for select using (auth.uid() = user_id);
drop policy if exists "insert own journal entries" on public.journal_entries;
create policy "insert own journal entries" on public.journal_entries
  for insert with check (auth.uid() = user_id);
drop policy if exists "update own journal entries" on public.journal_entries;
create policy "update own journal entries" on public.journal_entries
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "delete own journal entries" on public.journal_entries;
create policy "delete own journal entries" on public.journal_entries
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- targets — one row per user
-- =========================================================================
create table if not exists public.targets (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  profit_target numeric,
  max_loss numeric,
  axis_step numeric,
  profit_color text not null default '#16A34A',
  min_balance_color text not null default '#E23D45',
  growth_color text,
  axis_color text,
  cal_win_color text not null default '#16A34A',
  cal_loss_color text not null default '#E23D45',
  cal_payout_color text not null default '#0EA5E9'
);

alter table public.targets enable row level security;

drop policy if exists "select own targets" on public.targets;
create policy "select own targets" on public.targets
  for select using (auth.uid() = user_id);
drop policy if exists "insert own targets" on public.targets;
create policy "insert own targets" on public.targets
  for insert with check (auth.uid() = user_id);
drop policy if exists "update own targets" on public.targets;
create policy "update own targets" on public.targets
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "delete own targets" on public.targets;
create policy "delete own targets" on public.targets
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- trade_media — metadata only; binary files live in Supabase Storage
-- =========================================================================
create table if not exists public.trade_media (
  id uuid primary key default gen_random_uuid(),
  trade_id uuid not null references public.trades (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  storage_path text not null,
  type text not null check (type in ('image', 'video')),
  name text,
  created_at timestamptz not null default now()
);

create index if not exists trade_media_trade_idx on public.trade_media (trade_id);

alter table public.trade_media enable row level security;

drop policy if exists "select own trade media" on public.trade_media;
create policy "select own trade media" on public.trade_media
  for select using (auth.uid() = user_id);
drop policy if exists "insert own trade media" on public.trade_media;
create policy "insert own trade media" on public.trade_media
  for insert with check (auth.uid() = user_id);
drop policy if exists "delete own trade media" on public.trade_media;
create policy "delete own trade media" on public.trade_media
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- Storage bucket for trade photos/videos
-- =========================================================================
-- Private bucket — files are only ever served via short-lived signed URLs.
-- Path convention enforced by the app: {user_id}/{trade_id}/{random}-{filename}
insert into storage.buckets (id, name, public)
values ('trade-media', 'trade-media', false)
on conflict (id) do nothing;

drop policy if exists "select own trade media objects" on storage.objects;
create policy "select own trade media objects" on storage.objects
  for select using (bucket_id = 'trade-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "insert own trade media objects" on storage.objects;
create policy "insert own trade media objects" on storage.objects
  for insert with check (bucket_id = 'trade-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "delete own trade media objects" on storage.objects;
create policy "delete own trade media objects" on storage.objects
  for delete using (bucket_id = 'trade-media' and (storage.foldername(name))[1] = auth.uid()::text);
