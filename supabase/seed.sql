-- Haven · temporary demo household. Replace it with your real figures when ready.
-- Household figures (balances, bills, debts, goals) are demo data you enter here.
-- Market figures are NOT seeded: prices, returns and analyst ratings are fetched
-- live by the "market" edge function. Dates are relative to the day the seed runs.
--
-- Demo sign-ins (DEMO ONLY, delete these users before real use):
--   maya@haven.demo     / HavenDemo!2026   owner
--   advisor@haven.demo  / HavenDemo!2026   viewer (read only)

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
values
  ('00000000-0000-0000-0000-000000000000', 'a1a1a1a1-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
   'maya@haven.demo', extensions.crypt('HavenDemo!2026', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"display_name":"Maya"}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a1a1a1a1-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
   'advisor@haven.demo', extensions.crypt('HavenDemo!2026', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"display_name":"Advisor (read only)"}', now(), now(), '', '', '', '');

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email',
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), now(), now(), now()
from auth.users u where u.email in ('maya@haven.demo', 'advisor@haven.demo');
-- profiles are created by the on_auth_user_created trigger

-- ---------------------------------------------------------------------------
-- Household
-- ---------------------------------------------------------------------------
insert into public.households (id, name, members_label, currency, created_by) values
  ('b2b2b2b2-0000-4000-8000-000000000001', 'Maya''s household', 'Maya, Sami (9) and Lina (6)', 'AED',
   'a1a1a1a1-0000-4000-8000-000000000001');

insert into public.household_members (household_id, user_id, role) values
  ('b2b2b2b2-0000-4000-8000-000000000001', 'a1a1a1a1-0000-4000-8000-000000000001', 'owner'),
  ('b2b2b2b2-0000-4000-8000-000000000001', 'a1a1a1a1-0000-4000-8000-000000000002', 'viewer');

-- Everything below belongs to household b2b2b2b2-0000-4000-8000-000000000001.

-- ---------------------------------------------------------------------------
-- Accounts (D.accounts)
-- ---------------------------------------------------------------------------
insert into public.accounts (household_id, name, institution, kind, balance, monthly_fees, card_style, icon, note, flag, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('Joint current account', 'Northstar Bank', 'current'::public.account_kind, 18420, 120,
   'radial-gradient(60% 60% at 20% 20%,#5fb7a6,transparent),radial-gradient(60% 60% at 90% 80%,#2d5d6e,transparent),#1d3a3c',
   'card', 'Bills are paid from here.', null, 1),
  ('Family savings', 'Northstar Bank', 'savings', 64900, 60,
   'radial-gradient(60% 60% at 20% 20%,#9ad0b0,transparent),radial-gradient(60% 60% at 80% 90%,#3c6e57,transparent),#28473a',
   'wallet', 'Emergency reserve.', null, 2),
  ('Investment portfolio', 'Brokerage · Daniel’s name', 'investment', 0, 0,
   'radial-gradient(60% 60% at 20% 20%,#f4a26b,transparent),radial-gradient(60% 60% at 85% 75%,#c2457a,transparent),#4a2a2a',
   'chart', null, 'Ownership transfer needed', 3),
  ('Retirement fund', 'Pension provider · Daniel', 'retirement', 96400, 0,
   'radial-gradient(60% 60% at 25% 20%,#b8a8ff,transparent),radial-gradient(60% 60% at 85% 85%,#5a4fb0,transparent),#2b2648',
   'shield', null, 'Beneficiary not yet updated', 4),
  ('Family home (estimate)', 'Property', 'property', 1650000, 0,
   'radial-gradient(60% 60% at 20% 25%,#9cc4f0,transparent),radial-gradient(60% 60% at 85% 85%,#e0b073,transparent),#2a3a50',
   'home', 'Estimated value. Not sold.', null, 5)
) as v(name, institution, kind, balance, monthly_fees, card_style, icon, note, flag, sort_order);

-- ---------------------------------------------------------------------------
-- Debts (D.debts)
-- ---------------------------------------------------------------------------
insert into public.debts (household_id, name, rate_pct, original_amount, balance, monthly_payment, chart_color, note, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('Mortgage',    3.9, 1420000, 1184000, 9800, '#8db7e6', 'Ask the lender whether life cover clears this loan.', 1),
  ('Car loan',    4.9,  118000,   74200, 1650, '#ec8fae', 'Ask the lender and insurer how the claim affects this loan.', 2),
  ('Credit card', 22,    12000,    8640,  430, '#f4a26b', 'Highest rate. Usually the first to clear if extra cash appears.', 3)
) as v(name, rate_pct, original_amount, balance, monthly_payment, chart_color, note, sort_order);

-- ---------------------------------------------------------------------------
-- Income and bills (D.inflows, D.bills)
-- ---------------------------------------------------------------------------
insert into public.cash_flows (household_id, direction, name, amount, day_of_month, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('inflow'::public.flow_direction, 'Salary · Maya', 18500, 25, 1),
  ('inflow', 'Rent · Unit 4B',          4200,  1, 2),
  ('bill',   'Mortgage',                9800, 24, 1),
  ('bill',   'Car loan',                1650, 20, 2),
  ('bill',   'Credit card minimum',      430,  9, 3),
  ('bill',   'School fees',             4600, 28, 4),
  ('bill',   'Internet & phone',         420,  1, 5),
  ('bill',   'Insurance premiums',       540,  5, 6),
  ('bill',   'Utilities',                780, 12, 7)
) as v(direction, name, amount, day_of_month, sort_order);

-- ---------------------------------------------------------------------------
-- Monthly spending (D.spend). Subscriptions = null, summed from the list.
-- ---------------------------------------------------------------------------
insert into public.spending (household_id, name, monthly_amount, category, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('School fees',        4600::numeric, 'Essentials'::public.spend_group, 1),
  ('Groceries',          2400, 'Essentials', 2),
  ('Utilities',           780, 'Essentials', 3),
  ('Internet & phone',    420, 'Essentials', 4),
  ('Insurance premiums',  540, 'Essentials', 5),
  ('Transport',           900, 'Essentials', 6),
  ('Healthcare',          350, 'Essentials', 7),
  ('Subscriptions',      null, 'Lifestyle',  8),
  ('Miscellaneous',      1400, 'Lifestyle',  9)
) as v(name, monthly_amount, category, sort_order);

-- ---------------------------------------------------------------------------
-- Subscriptions (D.subs)
-- ---------------------------------------------------------------------------
insert into public.subscriptions (household_id, name, monthly_amount, usage, flagged, note, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('Streaming video',            55, 'Daily',               false, null, 1),
  ('Music',                      35, 'Weekly',              false, null, 2),
  ('Cloud storage',              30, 'Monthly',             false, null, 3),
  ('Gym membership',            450, 'Rarely (2 months)',   true,  'Check the notice period first.', 4),
  ('News subscription',          90, 'Rarely',              true,  null, 5),
  ('Meal kit delivery',         600, 'Unused for 60 days',  true,  'Most plans can be paused.', 6),
  ('Premium productivity app',  120, 'Weekly',              false, null, 7),
  ('Car telematics',             80, 'Tied to Daniel’s car', true, 'Can end once the car claim settles.', 8)
) as v(name, monthly_amount, usage, flagged, note, sort_order);

-- ---------------------------------------------------------------------------
-- Holdings: what the household owns. Prices, returns and analyst ratings are
-- live from the market API, never stored here. The investment account's
-- balance is the live value of these holdings.
-- ---------------------------------------------------------------------------
insert into public.holdings (household_id, symbol, name, asset_type, quantity, guideline_pct, note, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('VT',   'Vanguard Total World Stock ETF',     'Equity',       240, null::numeric, 'Core holding. Broad and low cost.', 1),
  ('FUTU', 'Futu Holdings (single stock)',       'Single stock',  85, 10,           'One company. Large gains, large risk.', 2),
  ('BND',  'Vanguard Total Bond Market ETF',     'Bonds',        150, null,         'Steadier ballast for the family.', 3),
  ('GLD',  'SPDR Gold Shares',                   'Commodity',      8, null,         'Small diversifier.', 4),
  ('SGOV', 'iShares 0-3 Month Treasury Bond ETF','Cash-like',      3, null,         'Parking spot for cash.', 5)
) as v(symbol, name, asset_type, quantity, guideline_pct, note, sort_order);

-- ---------------------------------------------------------------------------
-- Insurance claims (D.claims)
-- ---------------------------------------------------------------------------
insert into public.insurance_claims (household_id, name, steps, current_step, status, missing_documents, documents_due_on, expected_payout, sort_order)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.* from (values
  ('Life insurance · Daniel', array['Submitted','Documents','Assessment','Payout'], 1::smallint, 'Waiting on two documents',
   array['Certified death certificate (three copies)','Original policy document'], current_date + 6, 1500000::numeric, 1),
  ('Car insurance claim', array['Submitted','Assessment','Settlement'], 1::smallint, 'Assessor visit next week',
   '{}'::text[], null::date, null, 2),
  ('Family health cover', null::text[], null::smallint, 'Active · children covered', '{}'::text[], null::date, null, 3)
) as v(name, steps, current_step, status, missing_documents, documents_due_on, expected_payout, sort_order);

-- ---------------------------------------------------------------------------
-- Recent transactions (D.tx; d = days ago)
-- ---------------------------------------------------------------------------
insert into public.transactions (household_id, posted_on, description, amount)
select 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, current_date + v.d, v.t, v.a from (values
  (-1,  'Fresh Market · groceries',   -412),
  (-2,  'Salary · Maya',              18500),
  (-3,  'Meal kit delivery',          -150),
  (-4,  'Rent received · Unit 4B',    4200),
  (-6,  'School fees · installment',  -4600),
  (-7,  'Fuel',                       -260),
  (-9,  'Credit card repayment',      -430),
  (-11, 'Pharmacy',                   -96)
) as v(d, t, a);

-- ---------------------------------------------------------------------------
-- Goals (GOAL_SEED). progress = start_progress + check-ins (computed by trigger).
-- The emergency-fund target uses the same formula as the dashboard: 6 x outgoings.
-- ---------------------------------------------------------------------------
insert into public.goals (id, household_id, name, kind, mode, unit, target, start_progress, started_on, due_on, color, created_by, created_at)
select v.id, 'b2b2b2b2-0000-4000-8000-000000000001'::uuid, v.name, v.kind::public.goal_kind, v.mode::public.goal_mode, v.unit, v.target, v.startp,
       current_date + v.s, current_date + v.e, v.color, 'a1a1a1a1-0000-4000-8000-000000000001', now() - (6 - v.n) * interval '1 minute'
from (values
  ('c3c3c3c3-0000-4000-8000-000000000001'::uuid, 'Clear the credit card', 'long', 'amount', 'AED', 12000::numeric, 2930::numeric, -120, 150, '#f2542d', 1),
  ('c3c3c3c3-0000-4000-8000-000000000002', 'No-spend weekends', 'short', 'count', 'weekends', 4, 0, -6, 24, '#f5d22e', 2),
  ('c3c3c3c3-0000-4000-8000-000000000003', 'Six-month emergency fund', 'long', 'amount', 'AED',
     (select round(6 * outgoings / 1000) * 1000 from public.household_summary where household_id = 'b2b2b2b2-0000-4000-8000-000000000001'::uuid),
     (select liquid_cash from public.household_summary where household_id = 'b2b2b2b2-0000-4000-8000-000000000001'::uuid), -30, 365, '#a99cf2', 3),
  ('c3c3c3c3-0000-4000-8000-000000000004', 'Pause unused subscriptions', 'short', 'count', 'subscriptions', 4, 0, 0, 14, '#7ab894', 4),
  ('c3c3c3c3-0000-4000-8000-000000000005', 'Cook at home', 'short', 'count', 'dinners', 10, 5, -10, 9, '#ec8fae', 5)
) as v(id, name, kind, mode, unit, target, startp, s, e, color, n);

insert into public.goal_logs (goal_id, logged_on, amount, created_by) values
  ('c3c3c3c3-0000-4000-8000-000000000001', current_date - 9, 430, 'a1a1a1a1-0000-4000-8000-000000000001'),
  ('c3c3c3c3-0000-4000-8000-000000000002', current_date - 1, 1,   'a1a1a1a1-0000-4000-8000-000000000001'),
  ('c3c3c3c3-0000-4000-8000-000000000005', current_date,     1,   'a1a1a1a1-0000-4000-8000-000000000001');

select private.snapshot('b2b2b2b2-0000-4000-8000-000000000001'::uuid);
