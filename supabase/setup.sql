-- Dragon Drive cloud sync: run once in the Supabase SQL editor.
-- One JSON snapshot per user, plus a private bucket for drive photos and avatars.

create table if not exists public.snapshots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.snapshots enable row level security;
drop policy if exists "own snapshot" on public.snapshots;
create policy "own snapshot" on public.snapshots
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

insert into storage.buckets (id, name, public) values ('photos', 'photos', false)
  on conflict (id) do nothing;
drop policy if exists "own photos" on storage.objects;
create policy "own photos" on storage.objects
  for all using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
