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
