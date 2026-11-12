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
