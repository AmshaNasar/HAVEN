-- Haven · upgrade 3 (run once in SQL Editor on a project that already ran setup.sql)
-- Adds the Foresight risk advisor: weekly risk reports with causes, consequences,
-- severity, suggested actions, and a scenario to model each fix.
-- Same content as supabase/migrations/20261018000500_foresight.sql. Safe to run more than once.

-- Haven · Foresight: financial risk advisor.
--
-- A weekly look ahead. The engine reads what the household already has — bills,
-- income, balances, debts, subscriptions, holdings, claims and goals — and writes
-- a report of the risks it can see forming, each with its cause, what it leads to,
-- how severe it is, and what can be done about it.
--
-- The analysis is deterministic and written in SQL on purpose: every number in a
-- report can be traced back to a row the household can see, and the same inputs
-- always produce the same report. Nothing here invents a figure.
--
-- Each finding names a scenario preset, so the dashboard can load the suggested
-- fix straight into the Scenario lab and project it over ten years.
--
-- Safe to run more than once (also shipped as upgrade-3.sql).

-- ---------------------------------------------------------------------------
-- Severity
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.risk_severity as enum ('low', 'medium', 'high', 'critical');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Reports and their findings
-- ---------------------------------------------------------------------------
create table if not exists public.risk_reports (
  id              uuid primary key default gen_random_uuid(),
  household_id    uuid not null references public.households (id) on delete cascade,
  period_start    date not null,                       -- Monday of the week the report covers
  generated_at    timestamptz not null default now(),
  -- 0 (nothing to flag) .. 100 (several critical risks). Derived, never set by a client.
  risk_score      smallint not null default 0 check (risk_score between 0 and 100),
  top_severity    public.risk_severity,
  headline        public.safe_text not null,
  acknowledged_at timestamptz,                         -- set when someone opens the report
  acknowledged_by uuid references auth.users (id) on delete set null,
  unique (household_id, period_start)
);
create index if not exists risk_reports_household_idx
  on public.risk_reports (household_id, period_start desc);

create table if not exists public.risk_findings (
  id            bigint generated always as identity primary key,
  report_id     uuid not null references public.risk_reports (id) on delete cascade,
  household_id  uuid not null references public.households (id) on delete cascade,
  code          text not null check (code ~ '^[a-z][a-z0-9_]{2,39}$'),
  severity      public.risk_severity not null,
  title         public.safe_text not null,
  cause         public.safe_text not null,             -- why this is happening, in the household's own numbers
  consequence   public.safe_text not null,             -- what it leads to if nothing changes
  actions       text[] not null default '{}',          -- what can be done about it
  metrics       jsonb not null default '{}'::jsonb,    -- the figures the finding was built from
  horizon_days  smallint,                              -- when it bites, null = no deadline
  scenario      text check (scenario is null or scenario ~ '^[a-z][a-z0-9_]{0,23}$'),
  sort_order    smallint not null default 0,
  check (cardinality(actions) between 0 and 6
         and array_position(actions, null) is null
         and char_length(array_to_string(actions, '|')) <= 1200
         and array_to_string(actions, '|') !~ '[<>`]')
);
create index if not exists risk_findings_report_idx on public.risk_findings (report_id, sort_order);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- Monday of the week a date falls in.
create or replace function private.week_start(d date)
returns date language sql immutable set search_path = '' as $$
  select (d - ((extract(isodow from d)::int - 1)))::date;
$$;

-- The household's own calendar date. Uses households.timezone when that column
-- exists (it may not, depending on which upgrades have been run), else UTC.
create or replace function private.foresight_today(hh uuid)
returns date language plpgsql stable security definer set search_path = '' as $$
declare tz text := 'UTC';
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'households' and column_name = 'timezone') then
    execute 'select coalesce(h.timezone, ''UTC'') from public.households h where h.id = $1'
      into tz using hh;
  end if;
  return (now() at time zone coalesce(tz, 'UTC'))::date;
exception when others then
  return (now() at time zone 'UTC')::date;
end $$;

-- Text the safe_text domain will accept (no markup, no javascript:, 1..300 chars).
create or replace function private.rsafe(t text)
returns text language sql immutable set search_path = '' as $$
  select left(regexp_replace(regexp_replace(coalesce(nullif(trim(t), ''), '-'), '[<>`]', '', 'g'),
                             'javascript:', 'javascript', 'gi'), 300);
$$;

-- Money formatted for a sentence, e.g. "AED 1,480".
create or replace function private.rmoney(v numeric, ccy text)
returns text language sql immutable set search_path = '' as $$
  select ccy || ' ' || to_char(round(coalesce(v, 0)), 'FM999,999,999,990');
$$;

-- Days from `today` to the next occurrence of a day-of-month, in 0..31.
create or replace function private.days_until(day_of_month int, today date)
returns int language sql immutable set search_path = '' as $$
  select case
    when day_of_month >= extract(day from today)::int
      then day_of_month - extract(day from today)::int
    else (date_trunc('month', today) + interval '1 month')::date
         + (least(day_of_month, extract(day from (date_trunc('month', today) + interval '2 month' - interval '1 day'))::int) - 1)
         - today
  end::int;
$$;

-- ---------------------------------------------------------------------------
-- The engine. One row per risk it can see, worst first.
-- ---------------------------------------------------------------------------
create or replace function private.detect_risks(hh uuid)
returns table (
  code text, severity public.risk_severity, title text, cause text, consequence text,
  actions text[], metrics jsonb, horizon_days smallint, scenario text
)
language plpgsql stable security definer set search_path = '' as $$
declare
  s          record;                 -- household_summary
  ccy        text;
  today      date := private.foresight_today(hh);
  main_bal   numeric := 0;
  due7       numeric := 0;
  due30      numeric := 0;
  has_closed boolean;
begin
  select * into s from public.household_summary where household_id = hh;
  if not found then return; end if;
  ccy := s.currency;

  -- Balance of the account bills are paid from: the first current account, else the first account.
  select coalesce((select a.balance from public.accounts_live a
                   where a.household_id = hh and a.kind = 'current' order by a.sort_order limit 1),
                  (select a.balance from public.accounts_live a
                   where a.household_id = hh order by a.sort_order limit 1), 0)
    into main_bal;

  -- Bills falling due in the next 7 and 30 days, by day of month.
  select coalesce(sum(f.amount) filter (where private.days_until(f.day_of_month, today) <= 7), 0),
         coalesce(sum(f.amount) filter (where private.days_until(f.day_of_month, today) <= 30), 0)
    into due7, due30
  from public.cash_flows f
  where f.household_id = hh and f.direction = 'bill';

  -- ---- 1. The next week's bills are larger than the account they come out of ----
  if due7 > 0 and main_bal < due7 then
    return query select
      'bills_exceed_balance',
      case when main_bal < due7 * 0.75 then 'critical' else 'high' end::public.risk_severity,
      'Next week''s bills are larger than the account they come from',
      private.rsafe(format('%s is due in the next 7 days and the account holds %s, short by %s.',
        private.rmoney(due7, ccy), private.rmoney(main_bal, ccy), private.rmoney(due7 - main_bal, ccy))),
      private.rsafe('A direct debit can be refused. That usually means a returned-payment fee and, on a loan, a late mark that is reported for months.'),
      array['Move money from savings into the account bills are paid from before the first due date',
            'Ask the lender or provider to move one due date later in the month',
            'Pause a flagged subscription to free up the difference'],
      jsonb_build_object('due_7d', round(due7, 2), 'account_balance', round(main_bal, 2),
                         'shortfall', round(due7 - main_bal, 2), 'currency', ccy),
      7::smallint, 'subs';
  end if;

  -- ---- 2. Spending more than the household earns ----
  if s.monthly_gap < 0 then
    return query select
      'negative_cash_flow',
      case when s.liquid_cash <= 0 or -s.monthly_gap > s.income * 0.25 then 'critical'
           when -s.monthly_gap > s.income * 0.10 then 'high' else 'medium' end::public.risk_severity,
      'Outgoings are larger than income every month',
      private.rsafe(format('Income is %s a month and outgoings are %s, so %s leaves the household every month.',
        private.rmoney(s.income, ccy), private.rmoney(s.outgoings, ccy), private.rmoney(-s.monthly_gap, ccy))),
      private.rsafe(format('Savings cover this for about %s months at the current rate. After that the shortfall has to come from borrowing.',
        case when s.monthly_gap < 0 and s.liquid_cash > 0
             then to_char(floor(s.liquid_cash / -s.monthly_gap), 'FM999990') else '0' end)),
      array['Cut or pause the subscriptions flagged for review',
            'Move the bank fees to a lower-fee account',
            'Test each option in the Scenario lab before changing anything'],
      jsonb_build_object('income', round(s.income, 2), 'outgoings', round(s.outgoings, 2),
                         'monthly_gap', round(s.monthly_gap, 2), 'liquid_cash', round(s.liquid_cash, 2),
                         'months_of_cover', case when s.monthly_gap < 0 and s.liquid_cash > 0
                                                 then floor(s.liquid_cash / -s.monthly_gap) else 0 end,
                         'currency', ccy),
      case when s.monthly_gap < 0 and s.liquid_cash > 0
           then least(3650, floor(s.liquid_cash / -s.monthly_gap) * 30)::smallint else 0::smallint end,
      'subs';
  end if;

  -- ---- 3. Thin emergency fund ----
  if s.outgoings > 0 and s.runway_months is not null and s.runway_months < 6 then
    return query select
      'thin_emergency_fund',
      case when s.runway_months < 1 then 'critical' when s.runway_months < 3 then 'high'
           else 'medium' end::public.risk_severity,
      'Savings would not cover six months without income',
      private.rsafe(format('Liquid cash of %s covers about %s months of the %s that goes out each month.',
        private.rmoney(s.liquid_cash, ccy), to_char(s.runway_months, 'FM999990.0'), private.rmoney(s.outgoings, ccy))),
      private.rsafe('If income stops, bills still arrive. A short reserve usually means borrowing at short notice, which is the most expensive kind.'),
      array['Set a six-month safety-net goal and pay into it monthly',
            'Direct any insurance payout to the reserve first',
            'Close the monthly gap so the reserve can grow'],
      jsonb_build_object('runway_months', s.runway_months, 'liquid_cash', round(s.liquid_cash, 2),
                         'six_month_target', round(s.outgoings * 6, 2), 'currency', ccy),
      null::smallint, 'subs';
  end if;

  -- ---- 4. Expensive debt ----
  return query
  select 'expensive_debt',
         case when d.rate_pct >= 20 then 'high' when d.rate_pct >= 12 then 'medium'
              else 'low' end::public.risk_severity,
         private.rsafe(format('The %s is charging %s%% a year', lower(d.name), to_char(d.rate_pct, 'FM999990.0'))),
         private.rsafe(format('%s is outstanding at %s%%, which is about %s of interest this month alone.',
           private.rmoney(d.balance, ccy), to_char(d.rate_pct, 'FM999990.0'),
           private.rmoney(d.balance * d.rate_pct / 100 / 12, ccy))),
         private.rsafe(format('At %s a month this costs about %s in interest over the next year, before any new spending on it.',
           private.rmoney(d.monthly_payment, ccy), private.rmoney(d.balance * d.rate_pct / 100, ccy))),
         array['Pay this one down before any lower-rate debt',
               'Ask the lender what rate they would offer to keep you',
               'Model clearing it in the Scenario lab'],
         jsonb_build_object('name', d.name, 'balance', round(d.balance, 2), 'rate_pct', d.rate_pct,
                            'monthly_interest', round(d.balance * d.rate_pct / 100 / 12, 2), 'currency', ccy),
         null::smallint, 'cc'
  from public.debts d
  where d.household_id = hh and d.balance > 0 and d.rate_pct >= 12
  order by d.balance * d.rate_pct desc
  limit 2;

  -- ---- 5. One holding is a large part of the portfolio ----
  return query
  select 'holding_concentration', 'medium'::public.risk_severity,
         private.rsafe(format('%s is %s%% of the portfolio', split_part(v.name, ' (', 1),
           to_char(v.value / nullif(s.portfolio_value, 0) * 100, 'FM999990'))),
         private.rsafe(format('%s of %s sits in one holding, against a guideline of %s%%.',
           private.rmoney(v.value, ccy), private.rmoney(s.portfolio_value, ccy), to_char(v.guideline_pct, 'FM999990'))),
         private.rsafe('A single company can fall much further than a broad fund. At this weight, one bad year there moves the household''s net worth noticeably.'),
         array['Trim it back toward your own guideline',
               'Direct new contributions to the broad fund until the weight falls',
               'Model the trim in the Scenario lab before selling anything'],
         jsonb_build_object('symbol', v.symbol, 'value', round(v.value, 2),
                            'share_pct', round(v.value / nullif(s.portfolio_value, 0) * 100, 1),
                            'guideline_pct', v.guideline_pct, 'currency', ccy),
         null::smallint, 'rebal'
  from public.holdings_live v
  where v.household_id = hh and v.guideline_pct is not null and v.value is not null
    and s.portfolio_value > 0 and v.value / s.portfolio_value * 100 > v.guideline_pct
  order by v.value desc
  limit 2;

  -- ---- 6. Subscriptions nobody uses ----
  return query
  select 'subscription_drift', 'low'::public.risk_severity,
         private.rsafe(format('%s subscriptions are flagged for review', count(*)::text)),
         private.rsafe(format('%s a month across %s: %s.',
           private.rmoney(sum(x.monthly_amount), ccy), count(*)::text,
           string_agg(x.name, ', ' order by x.monthly_amount desc))),
         private.rsafe(format('Left alone this is about %s a year for things already marked as barely used.',
           private.rmoney(sum(x.monthly_amount) * 12, ccy))),
         array['Check the notice period, then pause rather than cancel where you can',
               'Model the saving in the Scenario lab first'],
         jsonb_build_object('count', count(*), 'monthly_total', round(sum(x.monthly_amount), 2),
                            'annual_total', round(sum(x.monthly_amount) * 12, 2), 'currency', ccy),
         null::smallint, 'subs'
  from public.subscriptions x
  where x.household_id = hh and x.status = 'active' and x.flagged
  having count(*) > 0;

  -- ---- 7. A claim is holding up money, and its documents are overdue ----
  select exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'insurance_claims' and column_name = 'closed')
    into has_closed;
  return query
  execute format($q$
    select 'claim_documents_overdue',
           case when c.documents_due_on < $2 then 'high' else 'medium' end::public.risk_severity,
           private.rsafe(format('%%s is waiting on %%s document(s)', c.name, cardinality(c.missing_documents)::text)),
           private.rsafe(format('%%s has been on hold since the insurer asked for %%s.',
             c.name, array_to_string(c.missing_documents, ' and '))),
           private.rsafe(case when c.expected_payout > 0
             then format('A payout of %%s stays out of reach until these arrive, and insurers can close a file that goes unanswered.',
                         private.rmoney(c.expected_payout, %L))
             else 'The claim cannot move until these arrive, and insurers can close a file that goes unanswered.' end),
           array['Send certified copies rather than originals, and keep a receipt of what was sent',
                 'Ask the insurer to confirm in writing exactly what is outstanding'],
           jsonb_build_object('claim', c.name, 'missing', cardinality(c.missing_documents),
                              'due_on', c.documents_due_on, 'expected_payout', round(coalesce(c.expected_payout, 0), 2),
                              'currency', %L),
           case when c.documents_due_on is null then null
                else greatest(-999, least(999, (c.documents_due_on - $2)))::smallint end,
           null::text
    from public.insurance_claims c
    where c.household_id = $1 and cardinality(c.missing_documents) > 0 %s
    order by coalesce(c.expected_payout, 0) desc
    limit 2
  $q$, ccy, ccy, case when has_closed then 'and not c.closed' else '' end)
  using hh, today;

  -- ---- 8. A goal is behind the pace it needs ----
  return query
  select 'goal_off_pace', 'low'::public.risk_severity,
         private.rsafe(format('%s is behind the pace it needs', g.name)),
         private.rsafe(format('%s of %s done with %s days left, so it needs about %s a day from here.',
           to_char(g.progress, 'FM999,999,990.99'), to_char(g.target, 'FM999,999,990.99'),
           (g.due_on - today)::text,
           to_char((g.target - g.progress) / greatest(1, g.due_on - today), 'FM999,999,990.99'))),
         private.rsafe('Missing a goal costs nothing by itself, but a target that was never reachable is worth resetting rather than carrying.'),
         array['Extend the deadline, or lower the target to something reachable',
               'Break the remainder into a weekly amount and check in against that'],
         jsonb_build_object('goal', g.name, 'progress', g.progress, 'target', g.target,
                            'days_left', g.due_on - today),
         greatest(0, least(999, g.due_on - today))::smallint, null::text
  from public.goals g
  where g.household_id = hh and g.due_on > today and g.progress < g.target
    and g.due_on > g.started_on
    -- behind where an even pace would have put it, by more than a tenth of the target
    and g.progress < g.target * ((today - g.started_on)::numeric / (g.due_on - g.started_on)) - g.target * 0.1
  order by (g.due_on - today) asc
  limit 2;

  -- ---- 9. Net worth is falling month on month ----
  return query
  with points as (
    select n.net_worth as now_nw,
           (select m.net_worth from public.net_worth_snapshots m
            where m.household_id = hh and m.taken_on <= n.taken_on - 30
            order by m.taken_on desc limit 1) as then_nw
    from public.net_worth_snapshots n
    where n.household_id = hh order by n.taken_on desc limit 1)
  select 'net_worth_falling',
         case when (then_nw - now_nw) / nullif(abs(then_nw), 0) > 0.05 then 'high'
              else 'medium' end::public.risk_severity,
         'Net worth has fallen over the past month',
         private.rsafe(format('Net worth is %s, down %s from %s a month ago.',
           private.rmoney(now_nw, ccy), private.rmoney(then_nw - now_nw, ccy), private.rmoney(then_nw, ccy))),
         private.rsafe('One month is not a trend, but repeated falls while income is steady usually mean spending or debt interest is outrunning what comes in.'),
         array['Check the cash-flow chart for the month that changed',
               'Confirm the fall is spending rather than a market move in the portfolio'],
         jsonb_build_object('net_worth', round(now_nw, 2), 'net_worth_30d_ago', round(then_nw, 2),
                            'change', round(now_nw - then_nw, 2), 'currency', ccy),
         null::smallint, null::text
  from points
  where then_nw is not null and now_nw < then_nw
    and (then_nw - now_nw) / nullif(abs(then_nw), 0) > 0.01;

  -- ---- 10. Prices are missing, so the figures are not trustworthy ----
  return query
  select 'stale_market_data', 'low'::public.risk_severity,
         private.rsafe(format('%s holding(s) have no live price', count(*)::text)),
         private.rsafe(format('No price has arrived for %s, so they count as zero in the portfolio and in net worth.',
           string_agg(v.symbol, ', ' order by v.symbol))),
         private.rsafe('Every figure that includes the portfolio is understated until prices arrive, and the net-worth history skips days while they are missing.'),
         array['Check the market function has both API keys set',
               'Confirm the ticker is one the provider covers'],
         jsonb_build_object('unpriced', count(*), 'symbols', array_agg(v.symbol order by v.symbol)),
         null::smallint, null::text
  from public.holdings_live v
  where v.household_id = hh and v.value is null
  having count(*) > 0;
end $$;


-- ---------------------------------------------------------------------------
-- Writing a report
-- ---------------------------------------------------------------------------
-- min(severity) on the enum gives the wrong end of the scale, so the worst severity
-- is picked with an explicit ordering instead.
create or replace function private.build_report(hh uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  wk    date := private.week_start(private.foresight_today(hh));
  rid   uuid; n int := 0; worst public.risk_severity; score int := 0; head text;
begin
  insert into public.risk_reports (household_id, period_start, headline)
  values (hh, wk, 'Looking at this week')
  on conflict (household_id, period_start) do update set generated_at = now()
  returning id into rid;

  delete from public.risk_findings where report_id = rid;

  insert into public.risk_findings (report_id, household_id, code, severity, title, cause,
                                    consequence, actions, metrics, horizon_days, scenario, sort_order)
  select rid, hh, r.code, r.severity, r.title, r.cause, r.consequence, r.actions, r.metrics,
         r.horizon_days, r.scenario,
         (row_number() over (order by array_position(
            array['critical','high','medium','low']::public.risk_severity[], r.severity),
            coalesce(r.horizon_days, 9999)))::smallint
  from private.detect_risks(hh) r;

  select count(*),
         (select f.severity from public.risk_findings f where f.report_id = rid
          order by array_position(array['critical','high','medium','low']::public.risk_severity[], f.severity)
          limit 1),
         coalesce(sum(case severity when 'critical' then 40 when 'high' then 25
                                    when 'medium' then 12 else 5 end), 0)
    into n, worst, score
  from public.risk_findings where report_id = rid;

  head := case
    when n = 0 then 'Nothing needs you this week'
    when worst = 'critical' then format('%s urgent %s to look at', n, case when n = 1 then 'risk' else 'risks' end)
    when worst = 'high' then format('%s %s worth acting on', n, case when n = 1 then 'risk' else 'risks' end)
    else format('%s small %s to keep an eye on', n, case when n = 1 then 'thing' else 'things' end) end;

  update public.risk_reports
     set risk_score = least(100, score), top_severity = worst,
         headline = private.rsafe(head), generated_at = now(),
         acknowledged_at = case when n = 0 then now() else null end,
         acknowledged_by = case when n = 0 then acknowledged_by else null end
   where id = rid;

  if n > 0 then
    insert into public.activity_log (household_id, icon, message)
    values (hh, 'eye', private.rsafe('Foresight report ready: ' || head));
  end if;
  return rid;
end $$;

-- Every household, for the weekly job.
create or replace function private.build_all_reports()
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select id from public.households loop
    begin
      perform private.build_report(r.id); n := n + 1;
    exception when others then
      raise notice 'foresight failed for % (%)', r.id, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- What the dashboard calls
-- ---------------------------------------------------------------------------
-- Rebuilds this week's report if it is missing or older than p_max_age.
create or replace function public.refresh_risk_report(p_household uuid, p_max_age interval default interval '7 days')
returns uuid language plpgsql security definer set search_path = '' as $$
declare rid uuid; fresh timestamptz;
begin
  if auth.role() <> 'service_role' and not private.is_member(p_household) then
    raise exception 'not a member of this household' using errcode = '42501';
  end if;
  select id, generated_at into rid, fresh from public.risk_reports
   where household_id = p_household
     and period_start = private.week_start(private.foresight_today(p_household));
  -- A small floor stops a client rebuilding in a loop, but still allows a real
  -- "check again now" after the household has acted on something.
  if rid is not null and fresh > now() - greatest(p_max_age, interval '5 seconds') then
    return rid;
  end if;
  return private.build_report(p_household);
end $$;

-- "I have read this week's report" — clears the alert for the whole household.
create or replace function public.acknowledge_risk_report(p_report uuid)
returns timestamptz language plpgsql security invoker set search_path = '' as $$
declare t timestamptz;
begin
  update public.risk_reports
     set acknowledged_at = now(), acknowledged_by = auth.uid()
   where id = p_report and acknowledged_at is null
  returning acknowledged_at into t;
  if t is null then
    select acknowledged_at into t from public.risk_reports where id = p_report;
  end if;
  return t;
end $$;

-- The newest report per household, for the dashboard's banner.
create or replace view public.risk_report_latest with (security_invoker = true) as
select distinct on (r.household_id)
  r.id, r.household_id, r.period_start, r.generated_at, r.risk_score, r.top_severity,
  r.headline, r.acknowledged_at,
  (select count(*) from public.risk_findings f where f.report_id = r.id) as finding_count
from public.risk_reports r
order by r.household_id, r.period_start desc;

-- ---------------------------------------------------------------------------
-- Row level security: members read, nobody writes through the API
-- ---------------------------------------------------------------------------
alter table public.risk_reports  enable row level security;
alter table public.risk_findings enable row level security;

drop policy if exists "members read risk reports"  on public.risk_reports;
drop policy if exists "members read risk findings" on public.risk_findings;
drop policy if exists "members acknowledge risk reports" on public.risk_reports;
create policy "members read risk reports" on public.risk_reports for select to authenticated
  using (private.is_member(household_id));
-- Acknowledging is the only client write, and only that one column is granted.
create policy "members acknowledge risk reports" on public.risk_reports for update to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy "members read risk findings" on public.risk_findings for select to authenticated
  using (private.is_member(household_id));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
grant select on public.risk_reports, public.risk_findings, public.risk_report_latest to authenticated;
grant update (acknowledged_at, acknowledged_by) on public.risk_reports to authenticated;
grant execute on function public.refresh_risk_report(uuid, interval),
                 public.acknowledge_risk_report(uuid) to authenticated;
grant execute on function public.refresh_risk_report(uuid, interval) to service_role;
grant all on public.risk_reports, public.risk_findings to service_role;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_member(uuid), private.has_role(uuid, public.household_role[]),
  private.can_edit(uuid), private.is_owner(uuid), private.shares_household(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Weekly schedule: Monday 06:00. The dashboard also rebuilds a report older
-- than seven days when someone opens it, so this is a backstop, not the only path.
-- ---------------------------------------------------------------------------
do $$
begin
  perform cron.schedule('haven-weekly-foresight', '0 6 * * 1', 'select private.build_all_reports()');
exception when others then
  raise notice 'pg_cron unavailable (%); weekly foresight reports will be built when someone opens the dashboard', sqlerrm;
end $$;
