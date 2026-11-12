-- Dragon Drive social: run once in the Supabase SQL editor (after setup.sql).
-- Profiles, following, shared drives, kudos, comments, avatars and drive photos.
-- Who can see a drive is decided here, in the database, not in the app.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text unique not null check (handle ~ '^[a-z0-9_]{3,20}$'),
  name text not null default '' check (char_length(name) <= 40),
  avatar_url text,
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists verified boolean not null default false;
alter table public.profiles enable row level security;

-- Official names (Burnout, Dragon Drive, staff words) can't be claimed from the app, including
-- look-alikes such as burn0ut or b_u_r_n_o_u_t. Only the project owner can create them from this
-- SQL editor, and only the editor can set the verified badge.
create or replace function public.guard_profile() returns trigger language plpgsql as $$
declare n text;
begin
  if auth.uid() is null then return new; end if; -- SQL editor / dashboard
  n := regexp_replace(translate(lower(new.handle), '0134578', 'oieastb'), '[^a-z]', '', 'g');
  if n ~ '(burnout|dragondrive|dragon(drive)?team|admin|support|official|staff|moderator)' then
    if tg_op = 'UPDATE' and old.handle = new.handle then null;
    else raise exception 'That handle is reserved' using errcode = '23505'; end if;
  end if;
  if tg_op = 'INSERT' then new.verified := false; else new.verified := old.verified; end if;
  return new;
end $$;
drop trigger if exists guard_profile on public.profiles;
create trigger guard_profile before insert or update on public.profiles for each row execute function public.guard_profile();
drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

create table if not exists public.follows (
  follower uuid not null references public.profiles(id) on delete cascade,
  followee uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
alter table public.follows enable row level security;
drop policy if exists "follows readable" on public.follows;
create policy "follows readable" on public.follows for select to authenticated using (true);
drop policy if exists "own follows" on public.follows;
create policy "own follows" on public.follows for insert to authenticated with check (follower = auth.uid());
drop policy if exists "unfollow" on public.follows;
create policy "unfollow" on public.follows for delete to authenticated using (follower = auth.uid());

create table if not exists public.drives (
  id text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  visibility text not null default 'followers' check (visibility in ('public','followers')),
  title text not null check (char_length(title) <= 120),
  vehicle text not null default '',
  source text not null default '',
  start timestamptz not null,
  stats jsonb not null,
  pts jsonb not null,
  photo boolean not null default false,
  updated_at timestamptz not null default now()
);
create index if not exists drives_user_start on public.drives (user_id, start desc);
alter table public.drives enable row level security;
drop policy if exists "see drives" on public.drives;
create policy "see drives" on public.drives for select to authenticated using (
  user_id = auth.uid() or visibility = 'public'
  or exists (select 1 from public.follows f where f.follower = auth.uid() and f.followee = drives.user_id));
drop policy if exists "own drives" on public.drives;
create policy "own drives" on public.drives for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create table if not exists public.kudos (
  drive_id text not null references public.drives(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (drive_id, user_id)
);
alter table public.kudos enable row level security;
drop policy if exists "see kudos" on public.kudos;
create policy "see kudos" on public.kudos for select to authenticated using (exists (select 1 from public.drives d where d.id = drive_id));
drop policy if exists "give kudos" on public.kudos;
create policy "give kudos" on public.kudos for insert to authenticated with check (user_id = auth.uid() and exists (select 1 from public.drives d where d.id = drive_id and d.user_id <> auth.uid()));
drop policy if exists "take back kudos" on public.kudos;
create policy "take back kudos" on public.kudos for delete to authenticated using (user_id = auth.uid());

create table if not exists public.comments (
  id bigint generated always as identity primary key,
  drive_id text not null references public.drives(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  body text not null check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now()
);
create index if not exists comments_drive on public.comments (drive_id, created_at);
alter table public.comments enable row level security;
drop policy if exists "see comments" on public.comments;
create policy "see comments" on public.comments for select to authenticated using (exists (select 1 from public.drives d where d.id = drive_id));
drop policy if exists "post comments" on public.comments;
create policy "post comments" on public.comments for insert to authenticated with check (user_id = auth.uid() and exists (select 1 from public.drives d where d.id = drive_id));
drop policy if exists "delete own comments" on public.comments;
create policy "delete own comments" on public.comments for delete to authenticated using (user_id = auth.uid());

-- Avatars are public images; drive photos follow the drive's visibility.
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('drive-photos', 'drive-photos', false) on conflict (id) do nothing;
drop policy if exists "own avatar" on storage.objects;
create policy "own avatar" on storage.objects for all to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own drive photos" on storage.objects;
create policy "own drive photos" on storage.objects for all to authenticated
  using (bucket_id = 'drive-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'drive-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "see drive photos" on storage.objects;
create policy "see drive photos" on storage.objects for select to authenticated
  using (bucket_id = 'drive-photos' and exists (select 1 from public.drives d where d.id = split_part(name, '/', 2)));

-- Public garage: vehicles people chose to show on their profile (private ones never leave the phone).
create table if not exists public.vehicles (
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  name text not null check (char_length(name) between 1 and 60),
  photo_url text,
  pos int not null default 0,
  primary key (user_id, name)
);
alter table public.vehicles enable row level security;
drop policy if exists "vehicles readable" on public.vehicles;
create policy "vehicles readable" on public.vehicles for select to authenticated using (true);
drop policy if exists "own vehicles" on public.vehicles;
create policy "own vehicles" on public.vehicles for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Vehicle pages: specs/mods description and extra photos (same as vehicle-pages.sql).
alter table public.vehicles add column if not exists about text not null default '' check (char_length(about) <= 2000);
alter table public.vehicles add column if not exists photos jsonb not null default '[]'::jsonb;

-- Everyone follows @burnout (same as follow-burnout.sql).
create or replace function public.follow_burnout() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into follows (follower, followee)
  select new.id, b.id from profiles b where b.handle = 'burnout' and b.id <> new.id
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists follow_burnout on public.profiles;
create trigger follow_burnout after insert on public.profiles for each row execute function public.follow_burnout();

insert into public.follows (follower, followee)
select p.id, b.id from public.profiles p join public.profiles b on b.handle = 'burnout' where p.id <> b.id
on conflict do nothing;

-- Announcements from verified accounts (same as announcements.sql).
alter table public.drives add column if not exists kind text not null default 'drive' check (kind in ('drive','post'));
alter table public.drives add column if not exists body text not null default '' check (char_length(body) <= 1000);

create or replace function public.guard_post() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'post' then
    if auth.uid() is not null and not exists (select 1 from profiles where id = auth.uid() and verified) then
      raise exception 'Only official accounts can post announcements' using errcode = '42501';
    end if;
    new.visibility := 'public';
  end if;
  return new;
end $$;
drop trigger if exists guard_post on public.drives;
create trigger guard_post before insert or update on public.drives for each row execute function public.guard_post();

drop policy if exists "see drives" on public.drives;
create policy "see drives" on public.drives for select to authenticated using (
  user_id = auth.uid() or visibility = 'public' or kind = 'post'
  or exists (select 1 from public.follows f where f.follower = auth.uid() and f.followee = drives.user_id));

-- Planned routes: drawn ahead of time and shared so a whole cruise follows the same line.
-- Run once in the Supabase SQL Editor. Safe to run again.
create table if not exists public.routes (
  id text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  visibility text not null default 'public' check (visibility in ('public','followers')),
  title text not null check (char_length(title) <= 120),
  mode text not null default 'roads' check (mode in ('roads','straight')),
  pts jsonb not null,
  dist double precision not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists routes_user_created on public.routes (user_id, created_at desc);
alter table public.routes enable row level security;
drop policy if exists "see routes" on public.routes;
create policy "see routes" on public.routes for select to authenticated using (
  user_id = auth.uid() or visibility = 'public'
  or exists (select 1 from public.follows f where f.follower = auth.uid() and f.followee = routes.user_id));
drop policy if exists "own routes" on public.routes;
create policy "own routes" on public.routes for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.routes to authenticated;

-- App stats for verified accounts (Burnout): powers the Stats panel at the top of his feed.
-- Run once in the Supabase SQL Editor. Safe to run again. Anyone else calling it gets "not allowed".
create or replace function public.app_stats() returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare out jsonb;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and verified) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  with d as (
    select s.user_id, to_timestamp((x->>'start')::bigint / 1000.0) as at, coalesce((x->'stats'->>'dist')::float, 0) as m
    from public.snapshots s, jsonb_array_elements(coalesce(s.data->'drives', '[]'::jsonb)) x
    where coalesce((x->>'sample')::boolean, false) = false and x ? 'start'
  )
  select jsonb_build_object(
    'accounts', (select count(*) from auth.users),
    'new7', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'signin7', (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
    'handles', (select count(*) from public.profiles),
    'drivers', (select count(distinct user_id) from d),
    'active7', (select count(distinct user_id) from d where at > now() - interval '7 days'),
    'active30', (select count(distinct user_id) from d where at > now() - interval '30 days'),
    'drives', (select count(*) from d),
    'drives7', (select count(*) from d where at > now() - interval '7 days'),
    'meters', (select coalesce(sum(m), 0) from d),
    'shared', (select count(*) from public.drives where kind = 'drive'),
    'follows', (select count(*) from public.follows),
    'kudos', (select count(*) from public.kudos),
    'comments', (select count(*) from public.comments),
    'vehicles', (select count(*) from public.vehicles),
    'routes', (select count(*) from public.routes),
    'at', now()
  ) into out;
  return out;
end $$;
revoke all on function public.app_stats() from public, anon;
grant execute on function public.app_stats() to authenticated;
