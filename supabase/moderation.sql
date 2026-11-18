-- Moderation queries for reports (see safety.sql). Run them one at a time in the Supabase SQL editor.
-- Apple expects reports to be acted on promptly; aim to handle each one within 24 hours.

-- 1. Open reports, newest first.
select r.id, r.created_at, r.kind, r.reason, r.target_handle, r.target_id, r.excerpt, r.details,
       (select handle from public.profiles where id = r.reporter) as reporter
from public.reports r where r.status = 'open' order by r.created_at desc;

-- 2. Remove the reported content (pick the line for its kind), then mark the report.
-- delete from public.comments where id = <target_id>;
-- delete from public.drives where id = '<target_id>';          -- drives and announcements ('post')
-- delete from public.routes where id = '<target_id>';
-- delete from public.vehicles where user_id = '<target_user>' and name = '<target_id>';
-- update public.reports set status = 'removed' where id = <report id>;

-- 3. Nothing wrong with it:
-- update public.reports set status = 'dismissed' where id = <report id>;

-- 4. Ban someone who keeps posting abusive content (they can't sign in again), and hide what they shared.
-- update auth.users set banned_until = 'infinity' where id = (select id from public.profiles where handle = '<handle>');
-- delete from public.drives where user_id = (select id from public.profiles where handle = '<handle>');
-- delete from public.comments where user_id = (select id from public.profiles where handle = '<handle>');
