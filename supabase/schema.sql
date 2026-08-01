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

-- =========================================================================
-- Friends — mutual opt-in connections. Once accepted, each side can see the
-- other's trades (NOT journal entries — those stay private) via the extra
-- select policy added to `trades` below.
-- =========================================================================
alter table public.profiles add column if not exists email text;

update public.profiles p
set email = u.email
from auth.users u
where p.id = u.id and p.email is null;

create unique index if not exists profiles_email_lower_idx on public.profiles (lower(email));

-- Keep new signups' profiles populated with their email too.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, subscription_status, created_at)
  values (new.id, new.email, 'trialing', now());
  return new;
end;
$$;

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

create index if not exists friendships_requester_idx on public.friendships (requester_id);
create index if not exists friendships_addressee_idx on public.friendships (addressee_id);

alter table public.friendships enable row level security;

drop policy if exists "select own friendships" on public.friendships;
create policy "select own friendships" on public.friendships
  for select using (auth.uid() = requester_id or auth.uid() = addressee_id);

drop policy if exists "update own friendship as addressee" on public.friendships;
create policy "update own friendship as addressee" on public.friendships
  for update using (auth.uid() = addressee_id) with check (auth.uid() = addressee_id);

drop policy if exists "delete own friendship" on public.friendships;
create policy "delete own friendship" on public.friendships
  for delete using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- Deliberately no insert policy: rows are only ever created through
-- request_friend() below (a security-definer function), which validates the
-- target email and blocks duplicate/self requests before inserting.
create or replace function public.request_friend(target_email text)
returns public.friendships
language plpgsql
security definer set search_path = public
as $$
declare
  target_id uuid;
  existing public.friendships;
  result public.friendships;
begin
  select id into target_id from public.profiles where lower(email) = lower(trim(target_email));
  if target_id is null then
    raise exception 'No account found with that email.';
  end if;
  if target_id = auth.uid() then
    raise exception 'You can''t add yourself as a friend.';
  end if;

  select * into existing from public.friendships
    where (requester_id = auth.uid() and addressee_id = target_id)
       or (requester_id = target_id and addressee_id = auth.uid());

  if existing.id is not null then
    if existing.status = 'declined' then
      update public.friendships
        set status = 'pending', requester_id = auth.uid(), addressee_id = target_id,
            created_at = now(), responded_at = null
        where id = existing.id
        returning * into result;
      return result;
    else
      raise exception 'A friend request already exists with this person.';
    end if;
  end if;

  insert into public.friendships (requester_id, addressee_id, status)
  values (auth.uid(), target_id, 'pending')
  returning * into result;
  return result;
end;
$$;

grant execute on function public.request_friend(text) to authenticated;

-- Let each side of a friendship (pending, accepted, or declined) see the
-- other's profile — needed just to display a name/email in the Friends list.
drop policy if exists "select friend profiles" on public.profiles;
create policy "select friend profiles" on public.profiles
  for select using (
    exists (
      select 1 from public.friendships f
      where (f.requester_id = auth.uid() and f.addressee_id = profiles.id)
         or (f.addressee_id = auth.uid() and f.requester_id = profiles.id)
    )
  );

-- Additional select policy on trades (Postgres OR's this with "select own
-- trades" above) — accepted friends only.
drop policy if exists "select accepted friends trades" on public.trades;
create policy "select accepted friends trades" on public.trades
  for select using (
    exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = trades.user_id)
          or (f.addressee_id = auth.uid() and f.requester_id = trades.user_id))
    )
  );

-- =========================================================================
-- confluences — atomic, user-named tags (e.g. "IFVG", "HTF FVG", "CISD")
-- selected on a trade in Add Trade.
-- =========================================================================
-- Superseded by confluences/patterns below (an earlier version of this
-- schema used "patterns" for what's now "confluences" — drop it clean if
-- it's already there, nothing depends on it existing).
drop table if exists public.trade_patterns cascade;
drop table if exists public.patterns cascade;

create table if not exists public.confluences (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

alter table public.confluences enable row level security;

drop policy if exists "select own confluences" on public.confluences;
create policy "select own confluences" on public.confluences
  for select using (auth.uid() = user_id);
drop policy if exists "insert own confluences" on public.confluences;
create policy "insert own confluences" on public.confluences
  for insert with check (auth.uid() = user_id);
drop policy if exists "delete own confluences" on public.confluences;
create policy "delete own confluences" on public.confluences
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- trade_confluences — many-to-many: which confluences were tagged on a trade
-- =========================================================================
create table if not exists public.trade_confluences (
  trade_id uuid not null references public.trades (id) on delete cascade,
  confluence_id uuid not null references public.confluences (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  timeframe text,
  primary key (trade_id, confluence_id)
);

alter table public.trade_confluences add column if not exists timeframe text;

alter table public.trade_confluences drop constraint if exists trade_confluences_timeframe_check;
alter table public.trade_confluences add constraint trade_confluences_timeframe_check
  check (timeframe is null or timeframe in ('15s', '30s', '1m', '2m', '3m', '5m', '15m', '30m', '1h', '2h', '4h'));

create index if not exists trade_confluences_trade_idx on public.trade_confluences (trade_id);
create index if not exists trade_confluences_confluence_idx on public.trade_confluences (confluence_id);

alter table public.trade_confluences enable row level security;

drop policy if exists "select own trade confluences" on public.trade_confluences;
create policy "select own trade confluences" on public.trade_confluences
  for select using (auth.uid() = user_id);
drop policy if exists "insert own trade confluences" on public.trade_confluences;
create policy "insert own trade confluences" on public.trade_confluences
  for insert with check (auth.uid() = user_id);
drop policy if exists "delete own trade confluences" on public.trade_confluences;
create policy "delete own trade confluences" on public.trade_confluences
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- patterns — a specific COMBINATION of confluences. The app auto-creates a
-- row here (via pattern_confluences below) the first time a trade is tagged
-- with a confluence set that hasn't been seen before; matching that same
-- combination again just reuses the existing pattern. Gradeable B- to A++,
-- same scale as trades.
-- =========================================================================
create table if not exists public.patterns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  grade text check (grade in ('B-', 'B', 'B+', 'A-', 'A', 'A+', 'A++')),
  created_at timestamptz not null default now()
);

alter table public.patterns enable row level security;

drop policy if exists "select own patterns" on public.patterns;
create policy "select own patterns" on public.patterns
  for select using (auth.uid() = user_id);
drop policy if exists "insert own patterns" on public.patterns;
create policy "insert own patterns" on public.patterns
  for insert with check (auth.uid() = user_id);
drop policy if exists "update own patterns" on public.patterns;
create policy "update own patterns" on public.patterns
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "delete own patterns" on public.patterns;
create policy "delete own patterns" on public.patterns
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- pattern_confluences — many-to-many: which confluences make up a pattern
-- =========================================================================
create table if not exists public.pattern_confluences (
  pattern_id uuid not null references public.patterns (id) on delete cascade,
  confluence_id uuid not null references public.confluences (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  primary key (pattern_id, confluence_id)
);

create index if not exists pattern_confluences_pattern_idx on public.pattern_confluences (pattern_id);
create index if not exists pattern_confluences_confluence_idx on public.pattern_confluences (confluence_id);

alter table public.pattern_confluences enable row level security;

drop policy if exists "select own pattern confluences" on public.pattern_confluences;
create policy "select own pattern confluences" on public.pattern_confluences
  for select using (auth.uid() = user_id);
drop policy if exists "insert own pattern confluences" on public.pattern_confluences;
create policy "insert own pattern confluences" on public.pattern_confluences
  for insert with check (auth.uid() = user_id);
drop policy if exists "delete own pattern confluences" on public.pattern_confluences;
create policy "delete own pattern confluences" on public.pattern_confluences
  for delete using (auth.uid() = user_id);
