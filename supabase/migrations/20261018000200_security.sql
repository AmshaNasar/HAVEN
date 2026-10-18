-- Haven · security: membership helpers, integrity triggers, row level security,
-- least-privilege grants, the API functions the dashboard needs, and auditing.
--
-- Access model
--   owner  : reads and edits everything in the household, manages members
--   member : reads everything, edits goals, goal check-ins and plan ticks
--   viewer : read only (for example a licensed advisor)
--   anon   : nothing at all

-- ---------------------------------------------------------------------------
-- Membership helpers (private schema: not exposed through the API)
-- ---------------------------------------------------------------------------
create or replace function private.is_member(hh uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hh and m.user_id = (select auth.uid()));
$$;

create or replace function private.has_role(hh uuid, roles public.household_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hh and m.user_id = (select auth.uid()) and m.role = any (roles));
$$;

create or replace function private.can_edit(hh uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_role(hh, array['owner','member']::public.household_role[]);
$$;

create or replace function private.is_owner(hh uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_role(hh, array['owner']::public.household_role[]);
$$;

create or replace function private.shares_household(other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.household_members a
    join public.household_members b on b.household_id = a.household_id
    where a.user_id = (select auth.uid()) and b.user_id = other);
$$;

grant usage on schema private to authenticated;
revoke all on all functions in schema private from public, anon;
grant execute on function private.is_member(uuid), private.has_role(uuid, public.household_role[]),
  private.can_edit(uuid), private.is_owner(uuid), private.shares_household(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Integrity triggers
-- ---------------------------------------------------------------------------
create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- A row can never be moved to another household.
create or replace function private.lock_household()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.household_id is distinct from old.household_id then
    raise exception 'household_id cannot be changed' using errcode = '42501';
  end if;
  return new;
end $$;

-- progress = least(target, start_progress + sum(check-ins)). Clients cannot set it.
create or replace function private.goal_compute_progress()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
  end if;
  new.progress := least(new.target, new.start_progress + coalesce(
    (select sum(l.amount) from public.goal_logs l where l.goal_id = new.id), 0));
  return new;
end $$;

create or replace function private.goal_log_prepare()
returns trigger language plpgsql security definer set search_path = '' as $$
declare g public.goals;
begin
  select * into g from public.goals where id = new.goal_id;
  if not found then raise exception 'goal not found' using errcode = 'P0002'; end if;
  new.household_id := g.household_id;           -- never trust the client for this
  new.created_by   := coalesce(auth.uid(), new.created_by);
  if new.logged_on > current_date + 1 then
    raise exception 'check-ins cannot be in the future' using errcode = '22023';
  end if;
  if g.mode = 'count' and new.amount <> trunc(new.amount) then
    raise exception 'count goals take whole numbers' using errcode = '22023';
  end if;
  return new;
end $$;

create or replace function private.goal_log_refresh()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.goals set updated_at = now()     -- re-runs goal_compute_progress
  where id = coalesce(new.goal_id, old.goal_id);
  return null;
end $$;

create or replace function private.plan_progress_prepare()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.completed_by := coalesce(auth.uid(), new.completed_by);
  new.completed_at := now();
  return new;
end $$;

-- Every change to household data lands in audit_log (append only).
create or replace function private.audit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
begin
  insert into public.audit_log (household_id, actor, table_name, row_id, action, old_data, new_data)
  values (
    coalesce((r->>'household_id')::uuid, case when tg_table_name = 'households' then (r->>'id')::uuid end),
    auth.uid(), tg_table_name, coalesce(r->>'id', r->>'plan_item_id', r->>'user_id'), tg_op, o, n);
  return null;
end $$;

-- New sign-up -> profile row. Display name is sanitised before it is stored.
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare nm text;
begin
  nm := left(regexp_replace(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
                                     split_part(new.email, '@', 1), 'Member'), '[<>`"]', '', 'g'), 80);
  insert into public.profiles (id, display_name) values (new.id, coalesce(nullif(nm, ''), 'Member'))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

do $$
declare t text;
begin
  foreach t in array array['profiles','households','accounts','cash_flows','spending','subscriptions',
                           'holdings','debts','insurance_claims','goals'] loop
    execute format('create trigger touch_updated_at before update on public.%I
                    for each row execute function private.touch_updated_at()', t);
  end loop;

  foreach t in array array['household_members','accounts','cash_flows','spending','subscriptions',
                           'transactions','holdings','debts','insurance_claims','goals',
                           'goal_logs','plan_progress'] loop
    execute format('create trigger lock_household before update on public.%I
                    for each row execute function private.lock_household()', t);
  end loop;

  foreach t in array array['households','household_members','accounts','cash_flows','spending',
                           'subscriptions','transactions','holdings','debts','insurance_claims',
                           'goals','goal_logs','plan_progress'] loop
    execute format('create trigger audit after insert or update or delete on public.%I
                    for each row execute function private.audit()', t);
  end loop;
end $$;

create trigger compute_progress before insert or update on public.goals
  for each row execute function private.goal_compute_progress();
create trigger prepare before insert on public.goal_logs
  for each row execute function private.goal_log_prepare();
create trigger refresh_goal after insert or delete on public.goal_logs
  for each row execute function private.goal_log_refresh();
create trigger prepare before insert on public.plan_progress
  for each row execute function private.plan_progress_prepare();

-- ---------------------------------------------------------------------------
-- Row level security: on for every table, deny by default
-- ---------------------------------------------------------------------------
alter table public.profiles          enable row level security;
alter table public.households        enable row level security;
alter table public.household_members enable row level security;
alter table public.accounts          enable row level security;
alter table public.cash_flows        enable row level security;
alter table public.spending          enable row level security;
alter table public.subscriptions     enable row level security;
alter table public.transactions      enable row level security;
alter table public.holdings          enable row level security;
alter table public.debts             enable row level security;
alter table public.insurance_claims  enable row level security;
alter table public.goals             enable row level security;
alter table public.goal_logs         enable row level security;
alter table public.plan_items        enable row level security;
alter table public.plan_progress     enable row level security;
alter table public.audit_log         enable row level security;
alter table public.market_quotes     enable row level security;
alter table public.market_history    enable row level security;
alter table public.fx_rates          enable row level security;
alter table public.activity_log      enable row level security;
alter table public.net_worth_snapshots enable row level security;

-- profiles: yourself, plus the names of people you share a household with
create policy "read own and co-member profiles" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.shares_household(id));
create policy "update own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- households: created only through create_household()
create policy "members read household" on public.households for select to authenticated
  using (private.is_member(id));
create policy "owners update household" on public.households for update to authenticated
  using (private.is_owner(id)) with check (private.is_owner(id));

-- members: owners manage others; anyone but an owner may leave
create policy "members read membership" on public.household_members for select to authenticated
  using (private.is_member(household_id));
create policy "owners add members" on public.household_members for insert to authenticated
  with check (private.is_owner(household_id) and user_id <> (select auth.uid()));
create policy "owners change roles" on public.household_members for update to authenticated
  using (private.is_owner(household_id) and user_id <> (select auth.uid()))
  with check (private.is_owner(household_id) and user_id <> (select auth.uid()));
create policy "owners remove members, members leave" on public.household_members for delete to authenticated
  using ((private.is_owner(household_id) and user_id <> (select auth.uid()))
         or (user_id = (select auth.uid()) and role <> 'owner'));

-- financial records: everyone in the household reads, only owners write
do $$
declare t text;
begin
  foreach t in array array['accounts','cash_flows','spending','subscriptions','transactions',
                           'holdings','debts','insurance_claims'] loop
    execute format('create policy "members read" on public.%I for select to authenticated
                    using (private.is_member(household_id))', t);
    execute format('create policy "owners insert" on public.%I for insert to authenticated
                    with check (private.is_owner(household_id))', t);
    execute format('create policy "owners update" on public.%I for update to authenticated
                    using (private.is_owner(household_id)) with check (private.is_owner(household_id))', t);
    execute format('create policy "owners delete" on public.%I for delete to authenticated
                    using (private.is_owner(household_id))', t);
  end loop;
end $$;

-- goals, check-ins, plan ticks: owners and members
create policy "members read goals" on public.goals for select to authenticated
  using (private.is_member(household_id));
create policy "editors create goals" on public.goals for insert to authenticated
  with check (private.can_edit(household_id));
create policy "editors update goals" on public.goals for update to authenticated
  using (private.can_edit(household_id)) with check (private.can_edit(household_id));
create policy "editors delete goals" on public.goals for delete to authenticated
  using (private.can_edit(household_id));

create policy "members read check-ins" on public.goal_logs for select to authenticated
  using (private.is_member(household_id));
create policy "editors add check-ins" on public.goal_logs for insert to authenticated
  with check (private.can_edit(household_id));
create policy "editors undo check-ins" on public.goal_logs for delete to authenticated
  using (private.can_edit(household_id));

create policy "signed-in users read the plan" on public.plan_items for select to authenticated
  using (true);

create policy "members read plan ticks" on public.plan_progress for select to authenticated
  using (private.is_member(household_id));
create policy "editors tick plan" on public.plan_progress for insert to authenticated
  with check (private.can_edit(household_id));
create policy "editors untick plan" on public.plan_progress for delete to authenticated
  using (private.can_edit(household_id));

-- audit trail: owners read, nobody writes through the API
create policy "owners read audit" on public.audit_log for select to authenticated
  using (household_id is not null and private.is_owner(household_id));

-- market data is public information: any signed-in user reads, nobody writes via the API
create policy "signed-in users read quotes"  on public.market_quotes  for select to authenticated using (true);
create policy "signed-in users read history" on public.market_history for select to authenticated using (true);
create policy "signed-in users read fx"      on public.fx_rates       for select to authenticated using (true);

create policy "members read activity"  on public.activity_log        for select to authenticated using (private.is_member(household_id));
create policy "members read snapshots" on public.net_worth_snapshots for select to authenticated using (private.is_member(household_id));

-- ---------------------------------------------------------------------------
-- Live views. security_invoker makes every view obey the caller's RLS.
-- ---------------------------------------------------------------------------
-- Holdings priced from live quotes: value = quantity x price x FX.
create view public.holdings_live with (security_invoker = true) as
select h.id, h.household_id, h.symbol, h.name, h.asset_type, h.quantity, h.guideline_pct, h.note, h.sort_order,
  q.currency as quote_currency, q.price, q.change_pct, q.quoted_at, q.fetched_at,
  case when coalesce(q.currency, 'USD') = hh.currency then 1 else fx.rate end as fx_rate,
  round(h.quantity * q.price * case when coalesce(q.currency, 'USD') = hh.currency then 1 else fx.rate end, 2) as value,
  round((q.price / y.close - 1) * 100, 2) as return_1y_pct,
  q.rating_strong_buy, q.rating_buy, q.rating_hold, q.rating_sell, q.rating_strong_sell, q.rating_period,
  round((2 * q.prev_rating_strong_buy + q.prev_rating_buy - q.prev_rating_sell - 2 * q.prev_rating_strong_sell)::numeric
        / nullif(2 * (q.prev_rating_strong_buy + q.prev_rating_buy + q.prev_rating_hold + q.prev_rating_sell + q.prev_rating_strong_sell), 0), 4)
    as prev_consensus_score
from public.holdings h
join public.households hh on hh.id = h.household_id
left join public.market_quotes q on q.symbol = h.symbol
left join public.fx_rates fx on fx.base = coalesce(q.currency, 'USD') and fx.quote = hh.currency
left join lateral (
  select m.close from public.market_history m
  where m.symbol = h.symbol and m.month <= (date_trunc('month', current_date) - interval '12 months')::date
  order by m.month desc limit 1) y on true;

-- Accounts, with any investment account valued from the live holdings.
create view public.accounts_live with (security_invoker = true) as
-- The holdings belong to the household, not to one account row, so the live value is
-- attributed to a single investment account (the first by sort_order). Any other
-- investment account keeps its own stored balance; otherwise the same portfolio would
-- be counted once per account and inflate total_assets, net_worth and the snapshots.
select a.id, a.household_id, a.name, a.institution, a.kind,
  case when a.kind = 'investment'
        and a.id = (select x.id from public.accounts x
                    where x.household_id = a.household_id and x.kind = 'investment'
                    order by x.sort_order, x.id limit 1)
       then coalesce((select sum(v.value) from public.holdings_live v where v.household_id = a.household_id), 0)
       else a.balance end as balance,
  a.monthly_fees, a.card_style, a.icon, a.note, a.flag, a.sort_order
from public.accounts a;

-- What today's holdings were worth at each of the last 12 month-ends (real closes).
create view public.portfolio_history with (security_invoker = true) as
select h.household_id, m.month,
  round(sum(h.quantity * m.close * case when coalesce(q.currency, 'USD') = hh.currency then 1 else fx.rate end), 2) as value,
  count(*)::int as holdings_priced,
  (select count(*)::int from public.holdings x where x.household_id = h.household_id) as holdings_total
from public.holdings h
join public.households hh on hh.id = h.household_id
join public.market_history m on m.symbol = h.symbol
left join public.market_quotes q on q.symbol = h.symbol
left join public.fx_rates fx on fx.base = coalesce(q.currency, 'USD') and fx.quote = hh.currency
where m.month > (date_trunc('month', current_date) - interval '12 months')::date
group by h.household_id, m.month;

-- Money in and out per month, from recorded transactions only.
create view public.monthly_cash_flow with (security_invoker = true) as
select household_id, date_trunc('month', posted_on)::date as month,
  coalesce(sum(amount) filter (where amount > 0), 0)  as money_in,
  coalesce(-sum(amount) filter (where amount < 0), 0) as money_out
from public.transactions
where posted_on >= (date_trunc('month', current_date) - interval '5 months')::date
group by household_id, date_trunc('month', posted_on);

-- The dashboard's derived figures (INCOME, OUT, GAP, CASH, NW, PORT, RUNWAY, PAYOUT).
create view public.household_summary with (security_invoker = true) as
with s as (
  select h.id as household_id, h.currency,
    (select coalesce(sum(amount), 0) from public.cash_flows f where f.household_id = h.id and f.direction = 'inflow') as income,
    (select coalesce(sum(monthly_amount), 0) from public.subscriptions x where x.household_id = h.id and x.status = 'active') as subscriptions_total,
    (select coalesce(sum(monthly_payment), 0) from public.debts d where d.household_id = h.id) as debt_payments,
    (select coalesce(sum(balance), 0) from public.debts d where d.household_id = h.id) as total_debt,
    (select coalesce(sum(balance), 0) from public.accounts_live a where a.household_id = h.id and a.kind in ('current','savings')) as liquid_cash,
    (select coalesce(sum(balance), 0) from public.accounts_live a where a.household_id = h.id) as total_assets,
    (select coalesce(sum(value), 0) from public.holdings_live p where p.household_id = h.id) as portfolio_value,
    (select coalesce(sum(expected_payout), 0) from public.insurance_claims c where c.household_id = h.id) as pending_payouts,
    (select coalesce(sum(monthly_amount), 0) from public.spending sp where sp.household_id = h.id) as listed_spending,
    (select count(*) from public.spending sp where sp.household_id = h.id and sp.monthly_amount is null) as subs_lines
  from public.households h
)
select household_id, currency, income, subscriptions_total,
  listed_spending + subs_lines * subscriptions_total                         as non_debt_spending,
  debt_payments,
  listed_spending + subs_lines * subscriptions_total + debt_payments          as outgoings,
  income - (listed_spending + subs_lines * subscriptions_total + debt_payments) as monthly_gap,
  liquid_cash, total_assets, total_debt, total_assets - total_debt          as net_worth,
  portfolio_value, pending_payouts,
  round(liquid_cash / nullif(listed_spending + subs_lines * subscriptions_total + debt_payments, 0), 2) as runway_months
from s;

-- ---------------------------------------------------------------------------
-- Net-worth snapshots: today's row is refreshed on every visit and price
-- update, and a nightly job records every household.
-- ---------------------------------------------------------------------------
create or replace function private.snapshot(hh uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.net_worth_snapshots (household_id, taken_on, net_worth, total_assets, total_debt, liquid_cash, portfolio_value, updated_at)
  select household_id, current_date, net_worth, total_assets, total_debt, liquid_cash, portfolio_value, now()
  from public.household_summary where household_id = hh
  on conflict (household_id, taken_on) do update set
    net_worth = excluded.net_worth, total_assets = excluded.total_assets, total_debt = excluded.total_debt,
    liquid_cash = excluded.liquid_cash, portfolio_value = excluded.portfolio_value, updated_at = now();
$$;

create or replace function private.snapshot_all()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select id from public.households loop perform private.snapshot(r.id); end loop;
end $$;

create or replace function public.refresh_snapshot(p_household uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() <> 'service_role' and not private.is_member(p_household) then
    raise exception 'not a member of this household' using errcode = '42501';
  end if;
  perform private.snapshot(p_household);
end $$;

do $$
begin
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
  perform cron.schedule('haven-nightly-snapshots', '55 23 * * *', 'select private.snapshot_all()');
exception when others then
  raise notice 'pg_cron unavailable (%); enable it under Database > Extensions to record nightly snapshots', sqlerrm;
end $$;

-- Background price refresh: pg_cron calls the market function every 15 minutes,
-- so prices, history and snapshots stay current even when nobody has the page open.
-- Run once:  select private.schedule_market_refresh('https://<ref>.supabase.co/functions/v1/market', '<CRON_SECRET>');
-- The URL and secret are kept in Supabase Vault, never in plain tables.
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

-- ---------------------------------------------------------------------------
-- Activity feed: real events, written by the database itself.
-- ---------------------------------------------------------------------------
create or replace function private.log_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare msg text; ic text;
begin
  case tg_table_name
    when 'transactions' then
      ic := 'loop';
      msg := 'Recorded ' || case when new.amount > 0 then 'money in' else 'a payment' end || ': ' || new.description;
    when 'goals' then
      ic := 'target'; msg := 'Started tracking “' || new.name || '”';
    when 'goal_logs' then
      ic := 'target'; msg := 'Logged progress on “' || (select g.name from public.goals g where g.id = new.goal_id) || '”';
    when 'plan_progress' then
      ic := 'list'; msg := 'Ticked off: ' || (select p.title from public.plan_items p where p.id = new.plan_item_id);
    when 'insurance_claims' then
      if tg_op = 'UPDATE' and new.status is not distinct from old.status
         and new.missing_documents is not distinct from old.missing_documents
         and new.current_step is not distinct from old.current_step then
        return null;
      end if;
      ic := 'doc'; msg := new.name || ': ' || new.status;
    else return null;
  end case;
  -- activity_log.message is safe_text, which also rejects 'javascript:'. The source
  -- columns are short_text, which allows it, so strip both here or the user's own
  -- insert fails with a confusing domain violation.
  msg := regexp_replace(msg, '[<>`]', '', 'g');
  msg := regexp_replace(msg, 'javascript:', 'javascript', 'gi');
  insert into public.activity_log (household_id, icon, message)
  values (new.household_id, ic, left(msg, 300));
  return null;
end $$;

create trigger activity after insert on public.transactions     for each row execute function private.log_activity();
create trigger activity after insert on public.goals            for each row execute function private.log_activity();
create trigger activity after insert on public.goal_logs        for each row execute function private.log_activity();
create trigger activity after insert on public.plan_progress    for each row execute function private.log_activity();
create trigger activity after update on public.insurance_claims for each row execute function private.log_activity();

-- ---------------------------------------------------------------------------
-- API functions
-- ---------------------------------------------------------------------------
-- Start a household; the caller becomes its owner. Capped to stop abuse.
create or replace function public.create_household(p_name text, p_members_label text default null, p_currency text default 'AED')
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); hh uuid;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if (select count(*) from public.household_members where user_id = uid and role = 'owner') >= 5 then
    raise exception 'household limit reached' using errcode = '54000';
  end if;
  insert into public.households (name, members_label, currency, created_by)
  values (p_name, p_members_label, p_currency, uid) returning id into hh;
  insert into public.household_members (household_id, user_id, role) values (hh, uid, 'owner');
  return hh;
end $$;

-- logGoal(id, v) in the dashboard
create or replace function public.log_goal_progress(p_goal uuid, p_amount numeric, p_on date default current_date)
returns public.goals language plpgsql security invoker set search_path = '' as $$
declare g public.goals;
begin
  insert into public.goal_logs (goal_id, amount, logged_on) values (p_goal, p_amount, p_on);
  select * into g from public.goals where id = p_goal;
  return g;
end $$;

-- undoGoal(id): removes the latest check-in
create or replace function public.undo_goal_log(p_goal uuid)
returns public.goals language plpgsql security invoker set search_path = '' as $$
declare g public.goals;
begin
  delete from public.goal_logs
  where id = (select id from public.goal_logs where goal_id = p_goal order by id desc limit 1);
  select * into g from public.goals where id = p_goal;
  return g;
end $$;

-- togglePlan(id, on)
create or replace function public.set_plan_item(p_household uuid, p_item text, p_done boolean)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  -- RLS would silently filter the delete to zero rows for a viewer while the insert
  -- raises, so check once up front and fail the same way either way.
  if not private.can_edit(p_household) then
    raise exception 'your role in this household cannot change the plan' using errcode = '42501';
  end if;
  if p_done then
    insert into public.plan_progress (household_id, plan_item_id) values (p_household, p_item)
    on conflict do nothing;
  else
    delete from public.plan_progress where household_id = p_household and plan_item_id = p_item;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Grants: strip Supabase's broad defaults, then grant only what is used.
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;

grant select on public.households to authenticated;
grant update (name, members_label, currency, expected_return_pct, fallback_volatility_pct, home_growth_pct) on public.households to authenticated;

grant select, delete on public.household_members to authenticated;
grant insert (household_id, user_id, role) on public.household_members to authenticated;
grant update (role) on public.household_members to authenticated;

grant select, insert, update, delete on
  public.accounts, public.cash_flows, public.spending, public.subscriptions,
  public.transactions, public.holdings, public.debts, public.insurance_claims
  to authenticated;


grant select, delete on public.goals to authenticated;
grant insert (household_id, name, kind, mode, unit, target, start_progress, started_on, due_on, color)
  on public.goals to authenticated;
grant update (name, unit, target, due_on, color) on public.goals to authenticated;

grant select, delete on public.goal_logs to authenticated;
grant insert (goal_id, amount, logged_on) on public.goal_logs to authenticated;

grant select on public.plan_items to authenticated;
grant select, delete on public.plan_progress to authenticated;
grant insert (household_id, plan_item_id) on public.plan_progress to authenticated;

grant select on public.audit_log to authenticated;
grant select on public.market_quotes, public.market_history, public.fx_rates,
  public.activity_log, public.net_worth_snapshots to authenticated;
grant select on public.household_summary, public.holdings_live, public.accounts_live,
  public.portfolio_history, public.monthly_cash_flow to authenticated;

grant execute on function
  public.create_household(text, text, text),
  public.log_goal_progress(uuid, numeric, date),
  public.undo_goal_log(uuid),
  public.set_plan_item(uuid, text, boolean),
  public.refresh_snapshot(uuid)
  to authenticated;
grant execute on function public.refresh_snapshot(uuid) to service_role;

-- Schema access for the API roles (harmless if already present; restores it if the
-- public schema was ever dropped and recreated). The service role is used only by
-- the market edge function, which writes prices, activity and snapshots.
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- Private helpers: only the RLS membership checks are callable by signed-in users.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_member(uuid), private.has_role(uuid, public.household_role[]),
  private.can_edit(uuid), private.is_owner(uuid), private.shares_household(uuid) to authenticated;
