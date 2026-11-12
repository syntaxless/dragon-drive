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
