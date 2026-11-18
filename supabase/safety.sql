-- Dragon Drive safety: account deletion, blocking and reporting (needed for the App Store).
-- Run once in the Supabase SQL editor, after social.sql (and routes.sql). Running it again is safe.
--
-- Apple's rules this covers:
--   5.1.1(v)  people who can create an account must be able to delete it from inside the app.
--   1.2       apps with user content need a way to report it, a way to block abusive users,
--             and the developer must act on reports (aim: within 24 hours).
-- Reports email burnout@turboloser.co through Resend, using the same Vault key as signup-email.sql
-- (resend_api_key). Without the key, reports are still saved; only the email is skipped.

create extension if not exists pg_net;

-- ---------------------------------------------------------------- terms

-- When someone accepted the Terms (the app asks before they pick a @handle).
alter table public.profiles add column if not exists terms_at timestamptz;

-- ---------------------------------------------------------------- blocking

create table if not exists public.blocks (
  blocker uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  blocked uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.blocks enable row level security;
drop policy if exists "own blocks" on public.blocks;
create policy "own blocks" on public.blocks for all to authenticated
  using (blocker = auth.uid()) with check (blocker = auth.uid());
grant select, insert, delete on public.blocks to authenticated;

-- True when either person blocked the other. Security definer so it can see the other side's block
-- (people can only read their own rows in blocks).
create or replace function public.blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks
    where (blocker = a and blocked = b) or (blocker = b and blocked = a));
$$;
revoke all on function public.blocked_between(uuid, uuid) from public, anon;
grant execute on function public.blocked_between(uuid, uuid) to authenticated;

-- A block hides both people's drives, posts, routes, comments, kudos and garages from each other, and
-- stops new follows, comments and kudos between them. These are RESTRICTIVE policies: they are added
-- on top of the existing ones (both must pass), so social.sql's rules are unchanged.
drop policy if exists "not blocked" on public.drives;
create policy "not blocked" on public.drives as restrictive for select to authenticated
  using (not public.blocked_between(auth.uid(), user_id));
drop policy if exists "not blocked" on public.comments;
create policy "not blocked" on public.comments as restrictive for select to authenticated
  using (not public.blocked_between(auth.uid(), user_id));
drop policy if exists "not blocked post" on public.comments;
create policy "not blocked post" on public.comments as restrictive for insert to authenticated
  with check (not exists (select 1 from public.drives d where d.id = drive_id and public.blocked_between(auth.uid(), d.user_id)));
drop policy if exists "not blocked" on public.kudos;
create policy "not blocked" on public.kudos as restrictive for select to authenticated
  using (not public.blocked_between(auth.uid(), user_id));
drop policy if exists "not blocked give" on public.kudos;
create policy "not blocked give" on public.kudos as restrictive for insert to authenticated
  with check (not exists (select 1 from public.drives d where d.id = drive_id and public.blocked_between(auth.uid(), d.user_id)));
drop policy if exists "not blocked" on public.routes;
create policy "not blocked" on public.routes as restrictive for select to authenticated
  using (not public.blocked_between(auth.uid(), user_id));
drop policy if exists "not blocked" on public.vehicles;
create policy "not blocked" on public.vehicles as restrictive for select to authenticated
  using (not public.blocked_between(auth.uid(), user_id));
drop policy if exists "not blocked follow" on public.follows;
create policy "not blocked follow" on public.follows as restrictive for insert to authenticated
  with check (not public.blocked_between(follower, followee));

-- Blocking also ends any follow between the two, both ways.
create or replace function public.block_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or target = auth.uid() then raise exception 'not allowed'; end if;
  insert into public.blocks (blocker, blocked) values (auth.uid(), target) on conflict do nothing;
  delete from public.follows where (follower = auth.uid() and followee = target) or (follower = target and followee = auth.uid());
end $$;
revoke all on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;

-- ---------------------------------------------------------------- reports

create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter uuid references public.profiles(id) on delete set null default auth.uid(),
  target_user uuid references public.profiles(id) on delete set null,
  target_handle text not null default '',
  kind text not null check (kind in ('drive','post','comment','profile','route','vehicle')),
  target_id text not null default '',
  reason text not null check (reason in ('spam','harassment','sexual','violence','dangerous','other')),
  details text not null default '' check (char_length(details) <= 1000),
  excerpt text not null default '' check (char_length(excerpt) <= 300),
  status text not null default 'open' check (status in ('open','removed','dismissed')),
  created_at timestamptz not null default now()
);
create index if not exists reports_open on public.reports (status, created_at desc);
alter table public.reports enable row level security;
drop policy if exists "file reports" on public.reports;
create policy "file reports" on public.reports for insert to authenticated with check (reporter = auth.uid());
drop policy if exists "see own reports" on public.reports;
create policy "see own reports" on public.reports for select to authenticated using (reporter = auth.uid());
grant select, insert on public.reports to authenticated;

create or replace function public.email_burnout_on_report() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  k text;
  who text;
  link text := 'https://dragondrive.turboloser.co/#u/' || new.target_handle;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if k is null then return new; end if;
  select '@' || handle into who from public.profiles where id = new.reporter;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Burnout from Dragon Drive <burnout@turboloser.co>',
      'to', jsonb_build_array('burnout@turboloser.co'),
      'subject', 'Report #' || new.id || ': ' || new.kind || ' by @' || new.target_handle || ' (' || new.reason || ')',
      'text', 'Reported by ' || coalesce(who, 'someone') || E'\n' ||
              'What: ' || new.kind || ' ' || new.target_id || E'\n' ||
              'Content: ' || new.excerpt || E'\n' ||
              'Details: ' || new.details || E'\n' ||
              'Profile: ' || link || E'\n\n' ||
              'Handle it within 24 hours with supabase/moderation.sql.'
    )
  );
  return new;
exception when others then
  return new; -- never lose a report over an email
end $$;
revoke all on function public.email_burnout_on_report() from public, anon, authenticated;
drop trigger if exists email_burnout_on_report on public.reports;
create trigger email_burnout_on_report after insert on public.reports
  for each row execute function public.email_burnout_on_report();

-- ---------------------------------------------------------------- account deletion

-- Deletes the signed-in person's account and everything stored for it. Removing the auth user
-- cascades to snapshots, profiles, and from profiles to follows, drives, posts, kudos, comments,
-- vehicles, routes and blocks. Reports they filed are kept with the reporter cleared.
-- Storage files can't be deleted from SQL, so the app removes them through the Storage API first
-- (photos/<uid>/, avatars/<uid>/, drive-photos/<uid>/) and then calls this.
-- The app calls it with dry_run = true first, so a missing function stops it before any photo is removed.
drop function if exists public.delete_account();
create or replace function public.delete_account(dry_run boolean default false) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if dry_run then return; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_account(boolean) from public, anon;
grant execute on function public.delete_account(boolean) to authenticated;
