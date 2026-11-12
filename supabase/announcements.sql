-- Dragon Drive announcements: short text posts that only verified accounts (like @burnout) can make.
-- They live in the drives table as kind = 'post', so kudos and comments work on them unchanged,
-- and every signed-in user sees them. Run once in the Supabase SQL editor (after social.sql).
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
notify pgrst, 'reload schema';
