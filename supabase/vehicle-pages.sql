-- Dragon Drive vehicle pages: run once in the Supabase SQL editor (after social.sql).
-- Adds a description (specs and mods) and extra photos to each public vehicle.
alter table public.vehicles add column if not exists about text not null default '' check (char_length(about) <= 2000);
alter table public.vehicles add column if not exists photos jsonb not null default '[]'::jsonb;
notify pgrst, 'reload schema';
