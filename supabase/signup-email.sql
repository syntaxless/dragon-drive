-- Email Burnout whenever someone new picks their @handle (that's when their profile row is created).
-- Subject: "@handle has signed up!"  Body: a link to their profile in the app.
-- Sent through Resend's API straight from the database (pg_net), so there's no Edge Function to deploy.
--
-- Before running this, store your Resend API key in the Vault once (its own query, so the key never
-- lands in this file or the repo):
--   select vault.create_secret('re_YOUR_KEY_HERE', 'resend_api_key');
-- Then run this whole file in the Supabase SQL editor. Running it again is safe.
-- If the key is missing or Resend is down, the signup still goes through; only the email is skipped.

create extension if not exists pg_net;

create or replace function public.email_burnout_on_signup() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  k text;
  url text := 'https://dragondrive.turboloser.co/#u/' || new.handle;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if k is null then return new; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Burnout from Dragon Drive <burnout@turboloser.co>',
      'to', jsonb_build_array('burnout@turboloser.co'),
      'subject', '@' || new.handle || ' has signed up!',
      'text', url,
      'html', '<a href="' || url || '">' || url || '</a>'
    )
  );
  return new;
exception when others then
  return new; -- never block a signup over an email
end $$;

revoke all on function public.email_burnout_on_signup() from public, anon, authenticated;

drop trigger if exists email_burnout_on_signup on public.profiles;
create trigger email_burnout_on_signup after insert on public.profiles
  for each row execute function public.email_burnout_on_signup();

-- To check it worked after a signup (Resend's answer; 200 means sent):
--   select status_code, content, created from net._http_response order by created desc limit 5;
