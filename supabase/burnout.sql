-- Create Burnout's official account. Run this once in the Supabase SQL editor.
-- 1. In the app: You → Account → Sign out, then sign in with an email you control that isn't your
--    personal account (a "+burnout" alias of your own address works). Stop at "Pick your @handle".
-- 2. Put that email below and run this. It claims @burnout and gives it the verified badge.
-- 3. Reload the app. You're now Burnout; upload his avatar from the profile page.
--    Sign out and back in with your own email to switch back; each account's data stays separate.
insert into public.profiles (id, handle, name, verified)
select id, 'burnout', 'Burnout', true from auth.users where email = 'PUT-THE-BURNOUT-EMAIL-HERE'
on conflict (id) do update set handle = 'burnout', name = 'Burnout', verified = true;
