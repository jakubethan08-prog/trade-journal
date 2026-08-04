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

-- App-wide appearance overrides (Settings tab), added after the initial
-- targets table — nullable, empty means "use the theme default".
alter table public.targets add column if not exists selected_tab_color text;
alter table public.targets add column if not exists add_trade_color text;
alter table public.targets add column if not exists welcome_banner_color text;

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
  insert into public.profiles (id, email, display_name, subscription_status, created_at)
  values (new.id, new.email, new.raw_user_meta_data->>'display_name', 'trialing', now());
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
-- No composite primary key here on purpose — the same confluence can be
-- tagged onto one trade more than once (e.g. IFVG on the 5m AND the 1h), so
-- each row needs its own surrogate id instead of being unique per
-- (trade_id, confluence_id).
create table if not exists public.trade_confluences (
  id uuid primary key default gen_random_uuid(),
  trade_id uuid not null references public.trades (id) on delete cascade,
  confluence_id uuid not null references public.confluences (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  timeframe text
);

-- Migrate a pre-existing table (created before repeat-tagging was
-- supported) from its old (trade_id, confluence_id) primary key to the new
-- surrogate id — guarded so it only runs once.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'trade_confluences' and column_name = 'id'
  ) then
    alter table public.trade_confluences add column id uuid default gen_random_uuid();
    update public.trade_confluences set id = gen_random_uuid() where id is null;
    alter table public.trade_confluences alter column id set not null;
    alter table public.trade_confluences drop constraint if exists trade_confluences_pkey;
    alter table public.trade_confluences add constraint trade_confluences_pkey primary key (id);
  end if;
end $$;

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
-- target_tags — atomic, user-named tags, same shape/purpose as confluences
-- but a separate category selected in its own Add Trade field. (Named
-- "target_tags" rather than "targets" to avoid colliding with the existing
-- `targets` table, which is the unrelated profit-target/max-loss settings.)
-- =========================================================================
create table if not exists public.target_tags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

alter table public.target_tags enable row level security;

drop policy if exists "select own target tags" on public.target_tags;
create policy "select own target tags" on public.target_tags
  for select using (auth.uid() = user_id);
drop policy if exists "insert own target tags" on public.target_tags;
create policy "insert own target tags" on public.target_tags
  for insert with check (auth.uid() = user_id);
drop policy if exists "delete own target tags" on public.target_tags;
create policy "delete own target tags" on public.target_tags
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- trade_target_tags — many-to-many: which target tags were selected on a
-- trade. Unlike trade_confluences, one row per (trade, tag) — no repeats.
-- =========================================================================
create table if not exists public.trade_target_tags (
  trade_id uuid not null references public.trades (id) on delete cascade,
  target_tag_id uuid not null references public.target_tags (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  primary key (trade_id, target_tag_id)
);

create index if not exists trade_target_tags_trade_idx on public.trade_target_tags (trade_id);
create index if not exists trade_target_tags_tag_idx on public.trade_target_tags (target_tag_id);

alter table public.trade_target_tags enable row level security;

drop policy if exists "select own trade target tags" on public.trade_target_tags;
create policy "select own trade target tags" on public.trade_target_tags
  for select using (auth.uid() = user_id);
drop policy if exists "insert own trade target tags" on public.trade_target_tags;
create policy "insert own trade target tags" on public.trade_target_tags
  for insert with check (auth.uid() = user_id);
drop policy if exists "delete own trade target tags" on public.trade_target_tags;
create policy "delete own trade target tags" on public.trade_target_tags
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

-- =========================================================================
-- trades.duration migrates from whole minutes to whole seconds, so the app
-- can show/edit duration as hours + minutes + seconds instead of just
-- minutes. Wrapped in a DO block because "change the column's unit and drop
-- the old one" isn't naturally idempotent with plain create/alter
-- statements — this guards re-runs after `duration` is already gone.
-- =========================================================================
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'trades' and column_name = 'duration'
  ) then
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'trades' and column_name = 'duration_seconds'
    ) then
      alter table public.trades add column duration_seconds integer;
    end if;
    update public.trades set duration_seconds = coalesce(duration, 0) * 60 where duration_seconds is null;
    alter table public.trades drop column duration;
  elsif not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'trades' and column_name = 'duration_seconds'
  ) then
    alter table public.trades add column duration_seconds integer not null default 0;
  end if;
end $$;

update public.trades set duration_seconds = 0 where duration_seconds is null;
alter table public.trades alter column duration_seconds set default 0;
alter table public.trades alter column duration_seconds set not null;

-- =========================================================================
-- Groups — a set of friends who share confluences/targets (built the same
-- way as the personal ones) and see a pooled "trading patterns" view built
-- from whichever trades any member tags into the group, plus a simple chat.
-- =========================================================================
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index if not exists group_members_user_idx on public.group_members (user_id);

-- SECURITY DEFINER helper: policies below check group membership through
-- this function instead of querying group_members directly from a policy
-- ON group_members itself, which Postgres rejects as infinite recursion.
create or replace function public.is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.group_members gm
    where gm.group_id = p_group_id and gm.user_id = p_user_id
  );
$$;
grant execute on function public.is_group_member(uuid, uuid) to authenticated;

alter table public.groups enable row level security;
drop policy if exists "select groups you're in" on public.groups;
create policy "select groups you're in" on public.groups
  for select using (public.is_group_member(id, auth.uid()));
drop policy if exists "update groups you're in" on public.groups;
create policy "update groups you're in" on public.groups
  for update using (public.is_group_member(id, auth.uid())) with check (public.is_group_member(id, auth.uid()));
-- Deliberately no insert policy: rows are only created through
-- create_group() below, which also seeds the creator's own membership row.

alter table public.group_members enable row level security;
drop policy if exists "select own group memberships" on public.group_members;
create policy "select own group memberships" on public.group_members
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "leave group" on public.group_members;
create policy "leave group" on public.group_members
  for delete using (auth.uid() = user_id);

-- Let group members see each other's profiles (name/email), even if two
-- members aren't directly friends with each other.
drop policy if exists "select group member profiles" on public.profiles;
create policy "select group member profiles" on public.profiles
  for select using (
    exists (
      select 1 from public.group_members gm
      where gm.user_id = profiles.id and public.is_group_member(gm.group_id, auth.uid())
    )
  );

-- Creates a group, adds the caller as a member, and adds any of the given
-- member ids who are the caller's accepted friends — enforces "groups are
-- built from friends" at the database level, not just in the UI.
create or replace function public.create_group(p_name text, p_member_ids uuid[])
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  new_group public.groups;
  m uuid;
begin
  if p_name is null or trim(p_name) = '' then
    raise exception 'Group name is required.';
  end if;

  insert into public.groups (creator_id, name) values (auth.uid(), trim(p_name))
  returning * into new_group;

  insert into public.group_members (group_id, user_id) values (new_group.id, auth.uid());

  if p_member_ids is not null then
    foreach m in array p_member_ids loop
      if m <> auth.uid() and exists (
        select 1 from public.friendships f
        where f.status = 'accepted'
          and ((f.requester_id = auth.uid() and f.addressee_id = m)
            or (f.addressee_id = auth.uid() and f.requester_id = m))
      ) then
        insert into public.group_members (group_id, user_id) values (new_group.id, m)
        on conflict do nothing;
      end if;
    end loop;
  end if;

  return new_group;
end;
$$;
grant execute on function public.create_group(text, uuid[]) to authenticated;

-- =========================================================================
-- group_messages — plain-text group chat, live via Supabase Realtime
-- =========================================================================
create table if not exists public.group_messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists group_messages_group_idx on public.group_messages (group_id, created_at);

alter table public.group_messages enable row level security;
drop policy if exists "select group messages" on public.group_messages;
create policy "select group messages" on public.group_messages
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert group messages" on public.group_messages;
create policy "insert group messages" on public.group_messages
  for insert with check (public.is_group_member(group_id, auth.uid()) and auth.uid() = user_id);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_messages'
  ) then
    alter publication supabase_realtime add table public.group_messages;
  end if;
end $$;

-- =========================================================================
-- group_confluences / group_target_tags — same idea as the personal
-- confluences/target_tags, scoped to a group instead of a user
-- =========================================================================
create table if not exists public.group_confluences (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (group_id, name)
);

alter table public.group_confluences enable row level security;
drop policy if exists "select group confluences" on public.group_confluences;
create policy "select group confluences" on public.group_confluences
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert group confluences" on public.group_confluences;
create policy "insert group confluences" on public.group_confluences
  for insert with check (public.is_group_member(group_id, auth.uid()));
drop policy if exists "delete group confluences" on public.group_confluences;
create policy "delete group confluences" on public.group_confluences
  for delete using (public.is_group_member(group_id, auth.uid()));

create table if not exists public.group_target_tags (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (group_id, name)
);

alter table public.group_target_tags enable row level security;
drop policy if exists "select group target tags" on public.group_target_tags;
create policy "select group target tags" on public.group_target_tags
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert group target tags" on public.group_target_tags;
create policy "insert group target tags" on public.group_target_tags
  for insert with check (public.is_group_member(group_id, auth.uid()));
drop policy if exists "delete group target tags" on public.group_target_tags;
create policy "delete group target tags" on public.group_target_tags
  for delete using (public.is_group_member(group_id, auth.uid()));

-- =========================================================================
-- group_trade_confluences / group_trade_target_tags — a member tags one of
-- THEIR OWN trades with a group confluence/target. This is also what makes
-- that trade visible to the rest of the group (see the trades policy at the
-- bottom) — only trades explicitly tagged in, never a member's full history.
-- =========================================================================
create table if not exists public.group_trade_confluences (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  trade_id uuid not null references public.trades (id) on delete cascade,
  group_confluence_id uuid not null references public.group_confluences (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  timeframe text,
  created_at timestamptz not null default now()
);

create index if not exists group_trade_confluences_group_idx on public.group_trade_confluences (group_id);
create index if not exists group_trade_confluences_trade_idx on public.group_trade_confluences (trade_id);

alter table public.group_trade_confluences enable row level security;
drop policy if exists "select group trade confluences" on public.group_trade_confluences;
create policy "select group trade confluences" on public.group_trade_confluences
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert own group trade confluences" on public.group_trade_confluences;
create policy "insert own group trade confluences" on public.group_trade_confluences
  for insert with check (auth.uid() = user_id and public.is_group_member(group_id, auth.uid()));
drop policy if exists "delete own group trade confluences" on public.group_trade_confluences;
create policy "delete own group trade confluences" on public.group_trade_confluences
  for delete using (auth.uid() = user_id);

create table if not exists public.group_trade_target_tags (
  group_id uuid not null references public.groups (id) on delete cascade,
  trade_id uuid not null references public.trades (id) on delete cascade,
  group_target_tag_id uuid not null references public.group_target_tags (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  primary key (trade_id, group_target_tag_id)
);

alter table public.group_trade_target_tags enable row level security;
drop policy if exists "select group trade target tags" on public.group_trade_target_tags;
create policy "select group trade target tags" on public.group_trade_target_tags
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert own group trade target tags" on public.group_trade_target_tags;
create policy "insert own group trade target tags" on public.group_trade_target_tags
  for insert with check (auth.uid() = user_id and public.is_group_member(group_id, auth.uid()));
drop policy if exists "delete own group trade target tags" on public.group_trade_target_tags;
create policy "delete own group trade target tags" on public.group_trade_target_tags
  for delete using (auth.uid() = user_id);

-- =========================================================================
-- group_patterns / group_pattern_confluences — same auto-created-combination
-- idea as personal patterns, scoped to the group and pooling every member's
-- tagged trades together.
-- =========================================================================
create table if not exists public.group_patterns (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  grade text check (grade in ('B-', 'B', 'B+', 'A-', 'A', 'A+', 'A++')),
  created_at timestamptz not null default now()
);

alter table public.group_patterns enable row level security;
drop policy if exists "select group patterns" on public.group_patterns;
create policy "select group patterns" on public.group_patterns
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert group patterns" on public.group_patterns;
create policy "insert group patterns" on public.group_patterns
  for insert with check (public.is_group_member(group_id, auth.uid()));
drop policy if exists "update group patterns" on public.group_patterns;
create policy "update group patterns" on public.group_patterns
  for update using (public.is_group_member(group_id, auth.uid())) with check (public.is_group_member(group_id, auth.uid()));
drop policy if exists "delete group patterns" on public.group_patterns;
create policy "delete group patterns" on public.group_patterns
  for delete using (public.is_group_member(group_id, auth.uid()));

create table if not exists public.group_pattern_confluences (
  group_pattern_id uuid not null references public.group_patterns (id) on delete cascade,
  group_confluence_id uuid not null references public.group_confluences (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  primary key (group_pattern_id, group_confluence_id)
);

alter table public.group_pattern_confluences enable row level security;
drop policy if exists "select group pattern confluences" on public.group_pattern_confluences;
create policy "select group pattern confluences" on public.group_pattern_confluences
  for select using (public.is_group_member(group_id, auth.uid()));
drop policy if exists "insert group pattern confluences" on public.group_pattern_confluences;
create policy "insert group pattern confluences" on public.group_pattern_confluences
  for insert with check (public.is_group_member(group_id, auth.uid()));
drop policy if exists "delete group pattern confluences" on public.group_pattern_confluences;
create policy "delete group pattern confluences" on public.group_pattern_confluences
  for delete using (public.is_group_member(group_id, auth.uid()));

-- Additional select policy on trades (OR'd with the existing ones) — a
-- group member can see a trade ONLY if it's been explicitly tagged into a
-- group they're also in, never a co-member's full trade history.
drop policy if exists "select group-tagged trades for group members" on public.trades;
create policy "select group-tagged trades for group members" on public.trades
  for select using (
    exists (
      select 1 from public.group_trade_confluences gtc
      where gtc.trade_id = trades.id and public.is_group_member(gtc.group_id, auth.uid())
    )
  );

-- =========================================================================
-- Group chat background — a solid color and/or an uploaded image, set from
-- the group's Settings view.
-- =========================================================================
alter table public.groups add column if not exists background_color text;
alter table public.groups add column if not exists background_image_path text;

-- Private bucket — same signed-URL pattern as trade-media. Path convention:
-- {group_id}/{random}-{filename}
insert into storage.buckets (id, name, public)
values ('group-backgrounds', 'group-backgrounds', false)
on conflict (id) do nothing;

drop policy if exists "select group background images" on storage.objects;
create policy "select group background images" on storage.objects
  for select using (
    bucket_id = 'group-backgrounds'
    and public.is_group_member(((storage.foldername(name))[1])::uuid, auth.uid())
  );
drop policy if exists "insert group background images" on storage.objects;
create policy "insert group background images" on storage.objects
  for insert with check (
    bucket_id = 'group-backgrounds'
    and public.is_group_member(((storage.foldername(name))[1])::uuid, auth.uid())
  );
drop policy if exists "delete group background images" on storage.objects;
create policy "delete group background images" on storage.objects
  for delete using (
    bucket_id = 'group-backgrounds'
    and public.is_group_member(((storage.foldername(name))[1])::uuid, auth.uid())
  );
