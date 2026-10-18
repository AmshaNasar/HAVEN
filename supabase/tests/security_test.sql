-- Run with:  supabase test db
-- Proves the access model against the seeded demo household.
begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

-- an outsider with a household of their own
insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000', 'eeeeeeee-0000-4000-8000-000000000009', 'authenticated', 'authenticated',
        'outsider@example.com', '{"display_name":"<b>Eve</b>"}');

create function pg_temp.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
end $$;

-- ---------------------------------------------------------------- anon
select pg_temp.as_anon();
select throws_ok('select * from public.accounts', '42501', null, 'anon cannot read accounts');
select throws_ok('select * from public.household_summary', '42501', null, 'anon cannot read the summary');
select throws_ok('select * from public.plan_items', '42501', null, 'anon cannot read the plan');
select throws_ok('select * from public.market_quotes', '42501', null, 'anon cannot read market data');
select throws_ok($$select public.create_household('x')$$, '42501', null, 'anon cannot create households');
reset role;

-- ---------------------------------------------------------------- owner (Maya)
select pg_temp.as_user('a1a1a1a1-0000-4000-8000-000000000001');
select is((select count(*)::int from public.accounts), 5, 'owner sees 5 accounts');
select results_eq(
  'select income, outgoings, monthly_gap, liquid_cash, subscriptions_total, pending_payouts from public.household_summary',
  $$values (22700::numeric, 24730::numeric, -2030::numeric, 83320::numeric, 1460::numeric, 1500000::numeric)$$,
  'summary figures (INCOME, OUT, GAP, CASH, SUBS_TOTAL, PAYOUT)');
select results_eq(
  'select name::text, progress, target from public.goals order by created_at',
  $$values ('Clear the credit card', 3360::numeric, 12000::numeric), ('No-spend weekends', 1, 4),
           ('Six-month emergency fund', 83320, 148000), ('Pause unused subscriptions', 0, 4), ('Cook at home', 6, 10)$$,
  'seeded goals match GOAL_SEED');
select is((public.log_goal_progress('c3c3c3c3-0000-4000-8000-000000000001', 500)).progress, 3860::numeric, 'check-in adds progress');
select is((public.undo_goal_log('c3c3c3c3-0000-4000-8000-000000000001')).progress, 3360::numeric, 'undo removes the latest check-in');
select is((public.log_goal_progress('c3c3c3c3-0000-4000-8000-000000000002', 99)).progress, 4::numeric, 'progress is capped at the target');
select throws_ok($$select public.log_goal_progress('c3c3c3c3-0000-4000-8000-000000000002', 1.5)$$, '22023', null, 'count goals reject fractions');
select throws_ok($$update public.goals set progress = 999999$$, '42501', null, 'progress cannot be written directly');
select throws_ok($$insert into public.goals (household_id, name, kind, mode, unit, target, due_on, color)
  values ('b2b2b2b2-0000-4000-8000-000000000001', '<img src=x onerror=alert(1)>', 'short', 'count', 'times', 3, current_date + 7, '#f5d22e')$$,
  '23514', null, 'markup in names is rejected');
select throws_ok($$insert into public.goals (household_id, name, kind, mode, unit, target, due_on, color)
  values ('b2b2b2b2-0000-4000-8000-000000000001', 'Ok', 'short', 'count', 'times', 3, current_date + 7, 'red;background:url(x)')$$,
  '23514', null, 'colours must be hex');
select throws_ok($$update public.accounts set card_style = 'red" onmouseover="alert(1)'$$, '23514', null, 'card styles cannot break out of the attribute');
select lives_ok($$select public.set_plan_item('b2b2b2b2-0000-4000-8000-000000000001', 'p1', true)$$, 'owner ticks a plan item');
select is((select count(*)::int from public.plan_progress), 1, 'tick is stored');
select ok((select count(*) from public.audit_log) > 0, 'owner can read the audit trail');
select throws_ok($$insert into public.audit_log (table_name, action) values ('x', 'INSERT')$$, '42501', null, 'nobody writes the audit trail');
select throws_ok($$insert into public.market_quotes (symbol, price) values ('FAKE', 1)$$, '42501', null, 'clients cannot write prices');
select throws_ok($$update public.market_quotes set price = 1$$, '42501', null, 'clients cannot change prices');
select throws_ok($$insert into public.activity_log (household_id, icon, message) values ('b2b2b2b2-0000-4000-8000-000000000001', 'loop', 'fake')$$, '42501', null, 'clients cannot write the activity feed');
select ok((select count(*) from public.activity_log) > 0, 'activity feed records real events');
select throws_ok($$insert into public.household_members (household_id, user_id, role)
  values ('b2b2b2b2-0000-4000-8000-000000000001', 'a1a1a1a1-0000-4000-8000-000000000001', 'viewer')$$,
  '42501', null, 'owner cannot demote themselves');
reset role;

-- ---------------------------------------------------------------- viewer (advisor)
select pg_temp.as_user('a1a1a1a1-0000-4000-8000-000000000002');
select is((select count(*)::int from public.holdings), 5, 'viewer can read holdings');
update public.accounts set balance = 1;
select throws_ok($$select public.log_goal_progress('c3c3c3c3-0000-4000-8000-000000000001', 100)$$, '42501', null, 'viewer cannot check in');
select throws_ok($$insert into public.goals (household_id, name, kind, mode, unit, target, due_on, color)
  values ('b2b2b2b2-0000-4000-8000-000000000001', 'Hack', 'short', 'count', 'times', 3, current_date + 7, '#f5d22e')$$,
  '42501', null, 'viewer cannot create goals');
select is((select count(*)::int from public.audit_log), 0, 'viewer cannot read the audit trail');
reset role;
select is((select sum(balance) from public.accounts), 1829720::numeric, 'viewer update changed nothing');

-- ---------------------------------------------------------------- outsider
select pg_temp.as_user('eeeeeeee-0000-4000-8000-000000000009');
select isnt(public.create_household('Eve home'), null, 'outsider can start their own household');
select is((select count(*)::int from public.accounts), 0, 'outsider sees no accounts of other households');
select is((select count(*)::int from public.goals), 0, 'outsider sees no goals of other households');
select is((select count(*)::int from public.profiles), 1, 'outsider sees only their own profile');
select is((select display_name::text from public.profiles), 'bEve/b', 'markup stripped from sign-up name');
select throws_ok($$select public.log_goal_progress('c3c3c3c3-0000-4000-8000-000000000001', 100)$$, '42501', null, 'outsider cannot touch other goals');
select throws_ok($$insert into public.accounts (household_id, name, institution, kind, balance)
  values ('b2b2b2b2-0000-4000-8000-000000000001', 'Mine now', 'Bank', 'current', 1)$$, '42501', null, 'outsider cannot write into another household');
select throws_ok($$select public.refresh_snapshot('b2b2b2b2-0000-4000-8000-000000000001')$$, '42501', null, 'outsider cannot snapshot another household');
reset role;

-- ------------------------------------------------- regressions (owner)
select pg_temp.as_user('a1a1a1a1-0000-4000-8000-000000000001');
-- "javascript:" is legal in short_text, so the activity trigger must not fail the
-- user's own insert on activity_log.message (safe_text, which rejects it).
select lives_ok($$insert into public.transactions (household_id, posted_on, description, amount)
  values ('b2b2b2b2-0000-4000-8000-000000000001', current_date, 'Paid javascript: ltd', -10)$$,
  'text containing javascript: can still be saved');
select is((select message::text from public.activity_log order by id desc limit 1),
  'Recorded a payment: Paid javascript ltd', 'the activity message is sanitised, not rejected');
reset role;

-- a second investment account must not be handed the same portfolio again
insert into public.market_quotes (symbol, currency, price, fetched_at)
  select symbol, 'USD', 100, now() from public.holdings
  where household_id = 'b2b2b2b2-0000-4000-8000-000000000001';
insert into public.accounts (household_id, name, institution, kind, balance, sort_order)
  values ('b2b2b2b2-0000-4000-8000-000000000001', 'Second brokerage', 'Other', 'investment', 0, 9);
select pg_temp.as_user('a1a1a1a1-0000-4000-8000-000000000001');
select is((select count(*)::int from public.accounts_live
           where household_id = 'b2b2b2b2-0000-4000-8000-000000000001'
             and kind = 'investment' and balance > 0), 1,
  'the live portfolio is attributed to one investment account, not to every one');
reset role;

select * from finish();
rollback;
