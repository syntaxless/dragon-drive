-- Everyone follows @burnout: new accounts follow him the moment they pick a handle, and this
-- also signs up everyone who already has one. Run once in the Supabase SQL editor (after social.sql).
-- People can still unfollow him if they want to.
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
