-- Haven · upgrade 1 (run once in SQL Editor on a project that already ran setup.sql)
-- 1. Scenario assumptions move into the database (households table)
-- 2. Prices refresh every 15 minutes in the background via pg_cron, even with the page closed
-- 3. Tighter permissions on internal helper functions
-- Safe to run more than once.

alter table public.households
  add column if not exists expected_return_pct     numeric(5,2) not null default 6  check (expected_return_pct between 0 and 20),
  add column if not exists fallback_volatility_pct numeric(5,2) not null default 14 check (fallback_volatility_pct between 1 and 60),
  add column if not exists home_growth_pct         numeric(5,2) not null default 3  check (home_growth_pct between -10 and 20);
grant update (name, members_label, currency, expected_return_pct, fallback_volatility_pct, home_growth_pct) on public.households to authenticated;

-- pg_net and pg_cron are not available on every project or plan. Guarded so a
-- project without them still gets the rest of this upgrade.
do $$
begin
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
exception when others then
  raise notice 'pg_net/pg_cron unavailable (%); enable them under Database > Extensions, then run the schedule_market_refresh line below', sqlerrm;
end $$;

create or replace function private.schedule_market_refresh(p_url text, p_secret text)
returns text language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if p_url !~ '^https?://[^ ]+/functions/v1/market$' then raise exception 'p_url must end in /functions/v1/market'; end if;
  if char_length(p_secret) < 24 then raise exception 'use a secret of at least 24 characters'; end if;
  select id into sid from vault.secrets where name = 'haven_market_url';
  if sid is null then perform vault.create_secret(p_url, 'haven_market_url'); else perform vault.update_secret(sid, p_url); end if;
  sid := null;
  select id into sid from vault.secrets where name = 'haven_cron_secret';
  if sid is null then perform vault.create_secret(p_secret, 'haven_cron_secret'); else perform vault.update_secret(sid, p_secret); end if;
  perform cron.schedule('haven-market-refresh', '*/15 * * * *', $job$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'haven_market_url'),
      headers := jsonb_build_object('Content-Type', 'application/json',
                   'x-haven-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'haven_cron_secret')),
      body    := '{"cron": true}'::jsonb,
      timeout_milliseconds := 60000)
  $job$);
  return 'scheduled every 15 minutes';
end $$;
revoke all on function private.schedule_market_refresh(text, text) from public, anon, authenticated;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_member(uuid), private.has_role(uuid, public.household_role[]),
  private.can_edit(uuid), private.is_owner(uuid), private.shares_household(uuid) to authenticated;

-- Last step, run separately. Replace <ref> with your project ref and <CRON_SECRET> with
-- the same value you saved under Edge Functions > Secrets (at least 24 characters), then
-- run this one line on its own in the SQL Editor:
--
--   select private.schedule_market_refresh('https://<ref>.supabase.co/functions/v1/market', '<CRON_SECRET>');
--
-- It is deliberately left commented out: run as written, the placeholder secret is
-- rejected, and because the SQL Editor runs a script in one transaction that failure
-- would roll back everything above.
