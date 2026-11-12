-- Dragon Drive stats. Paste into the Supabase SQL Editor and press Run (read-only, safe any time).
-- Save it as a snippet ("Save" in the editor) to rerun later.
with d as (  -- every recorded drive, including private ones, from each account's synced copy
  select s.user_id, (x->>'start')::bigint as start_ms, coalesce((x->'stats'->>'dist')::float, 0) as m, x->>'source' as source
  from public.snapshots s, jsonb_array_elements(coalesce(s.data->'drives', '[]'::jsonb)) x
  where coalesce((x->>'sample')::boolean, false) = false
), dd as (select *, to_timestamp(start_ms / 1000.0) as at from d)
select metric, value from (
  select 1 o, 'Accounts (signed up)' metric, count(*)::text value from auth.users
  union all select 2, 'New accounts, last 7 days', count(*)::text from auth.users where created_at > now() - interval '7 days'
  union all select 3, 'Signed in, last 7 days', count(*)::text from auth.users where last_sign_in_at > now() - interval '7 days'
  union all select 4, 'Profiles with a @handle', count(*)::text from public.profiles
  union all select 5, 'Drivers with at least one drive', count(distinct user_id)::text from dd
  union all select 6, 'Active drivers, last 7 days', count(distinct user_id)::text from dd where at > now() - interval '7 days'
  union all select 7, 'Active drivers, last 30 days', count(distinct user_id)::text from dd where at > now() - interval '30 days'
  union all select 8, 'Drives recorded (all time)', count(*)::text from dd
  union all select 9, 'Drives, last 7 days', count(*)::text from dd where at > now() - interval '7 days'
  union all select 10, 'Miles driven (all time)', round((sum(m) / 1609.344)::numeric, 0)::text from dd
  union all select 11, 'Drives shared to the feed', count(*)::text from public.drives where kind = 'drive'
  union all select 12, 'Follows', count(*)::text from public.follows
  union all select 13, 'Kudos given', count(*)::text from public.kudos
  union all select 14, 'Comments', count(*)::text from public.comments
  union all select 15, 'Vehicles in garages', count(*)::text from public.vehicles
  union all select 16, 'Planned routes shared', count(*)::text from public.routes
  union all select 17, 'Drives by source: ' || coalesce(nullif(string_agg(source || ' ' || n, ', ' order by n desc), ''), 'none'), '' from (select coalesce(source, 'phone') source, count(*) n from dd group by 1) s
) t order by o;
