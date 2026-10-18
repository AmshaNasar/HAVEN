-- Haven · household wealth agent
-- Schema: every table mirrors a structure the dashboard already renders
-- (D.accounts, D.debts, D.bills, GOALS, PLAN, ...). Security lives in the next migration.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Domains. The dashboard writes most stored strings straight into innerHTML,
-- so the database refuses anything that could become markup or break out of
-- an attribute. This is the backend half of the XSS defence.
-- ---------------------------------------------------------------------------
create domain public.safe_text as text
  check (value !~ '[<>`]' and value !~* 'javascript:' and char_length(value) between 1 and 300);

create domain public.short_text as text
  check (value !~ '[<>`"]' and char_length(value) between 1 and 80);

create domain public.hex_color as text
  check (value ~ '^#[0-9a-fA-F]{6}$');

-- CSS gradients for account cards are written into a style attribute.
create domain public.css_gradient as text
  check (value ~ '^[a-z0-9#%.,() -]+$' and char_length(value) <= 400);

create domain public.money as numeric(14,2)
  check (value >= 0 and value < 1000000000000);

create domain public.currency_code as text
  check (value ~ '^[A-Z]{3}$');

create type public.household_role as enum ('owner', 'member', 'viewer');
create type public.account_kind   as enum ('current', 'savings', 'investment', 'retirement', 'property', 'other');
create type public.flow_direction as enum ('inflow', 'bill');
create type public.spend_group    as enum ('Essentials', 'Lifestyle');
create type public.goal_kind      as enum ('short', 'long');
create type public.goal_mode      as enum ('amount', 'count');
create type public.sub_status     as enum ('active', 'paused', 'cancelled');

-- ---------------------------------------------------------------------------
-- People and households
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  public.short_text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.households (
  id            uuid primary key default gen_random_uuid(),
  name          public.short_text not null,
  members_label public.safe_text,                        -- D.user.household
  currency      public.currency_code not null default 'AED',
  -- Scenario-lab assumptions. Volatility is measured from real prices when there is
  -- enough history; fallback_volatility_pct is used only until then.
  expected_return_pct     numeric(5,2) not null default 6 check (expected_return_pct between 0 and 20),
  fallback_volatility_pct numeric(5,2) not null default 14 check (fallback_volatility_pct between 1 and 60),
  home_growth_pct         numeric(5,2) not null default 3 check (home_growth_pct between -10 and 20),
  created_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  role         public.household_role not null default 'member',
  created_at   timestamptz not null default now(),
  primary key (household_id, user_id)
);
create index on public.household_members (user_id);

-- ---------------------------------------------------------------------------
-- Money (D.accounts, D.inflows, D.bills, D.spend, D.subs, D.tx)
-- ---------------------------------------------------------------------------
create table public.accounts (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  name         public.short_text not null,
  institution  public.short_text not null,               -- "bank" in the UI
  kind         public.account_kind not null,
  balance      public.money not null default 0,      -- investment accounts: live sum of holdings (see accounts_live)
  monthly_fees public.money not null default 0,      -- what the bank charges each month
  card_style   public.css_gradient,                      -- "g"
  icon         text not null default 'card'
               check (icon in ('card','wallet','chart','shield','home','bank')),
  note         public.safe_text,
  flag         public.safe_text,
  sort_order   smallint not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.accounts (household_id, sort_order);

create table public.cash_flows (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  direction    public.flow_direction not null,
  name         public.short_text not null,
  amount       public.money not null check (amount > 0),
  day_of_month smallint not null check (day_of_month between 1 and 31),
  sort_order   smallint not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.cash_flows (household_id, direction, sort_order);

create table public.spending (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references public.households (id) on delete cascade,
  name           public.short_text not null,
  monthly_amount public.money,                           -- null = sum of subscriptions
  category       public.spend_group not null,
  sort_order     smallint not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.spending (household_id, sort_order);

create table public.subscriptions (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references public.households (id) on delete cascade,
  name           public.short_text not null,
  monthly_amount public.money not null,
  usage          public.short_text not null,             -- "used"
  flagged        boolean not null default false,
  note           public.safe_text,
  status         public.sub_status not null default 'active',
  sort_order     smallint not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.subscriptions (household_id, sort_order);

create table public.transactions (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  posted_on    date not null,
  description  public.short_text not null,
  amount       numeric(14,2) not null check (amount <> 0 and abs(amount) < 1000000000000),
  created_at   timestamptz not null default now()
);
create index on public.transactions (household_id, posted_on desc);

-- ---------------------------------------------------------------------------
-- Investments. The household stores only what it owns (symbol + quantity).
-- Prices, 1-year return and analyst ratings come from live market data
-- (market_quotes / market_history, filled by the "market" edge function).
-- ---------------------------------------------------------------------------
create domain public.ticker as text
  check (value ~ '^[A-Z0-9][A-Z0-9.\-]{0,11}$');

create table public.holdings (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households (id) on delete cascade,
  symbol        public.ticker not null,
  name          public.short_text not null,
  asset_type    public.short_text not null,
  quantity      numeric(18,6) not null check (quantity > 0 and quantity < 1000000000),
  guideline_pct numeric(5,2) check (guideline_pct between 0 and 100),   -- personal max share of portfolio
  note          public.safe_text,
  sort_order    smallint not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (household_id, symbol)
);
create index on public.holdings (household_id, sort_order);

-- ---------------------------------------------------------------------------
-- Debts and insurance (D.debts, D.claims)
-- ---------------------------------------------------------------------------
create table public.debts (
  id              uuid primary key default gen_random_uuid(),
  household_id    uuid not null references public.households (id) on delete cascade,
  name            public.short_text not null,
  rate_pct        numeric(5,2) not null check (rate_pct between 0 and 100),
  original_amount public.money not null,
  balance         public.money not null,
  monthly_payment public.money not null,
  chart_color     public.hex_color not null,
  note            public.safe_text,
  sort_order      smallint not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (balance <= original_amount)
);
create index on public.debts (household_id, sort_order);

create table public.insurance_claims (
  id                uuid primary key default gen_random_uuid(),
  household_id      uuid not null references public.households (id) on delete cascade,
  name              public.short_text not null,
  steps             text[],                              -- null = no tracker (active cover)
  current_step      smallint,
  status            public.safe_text not null,
  missing_documents text[] not null default '{}',
  documents_due_on  date,                                -- "due" in days, from this date
  expected_payout   public.money,                        -- what the claim pays if approved
  sort_order        smallint not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (steps is null or (cardinality(steps) between 1 and 12 and array_to_string(steps, '|') !~ '[<>`"]')),
  check (array_to_string(missing_documents, '|') !~ '[<>`"]' and cardinality(missing_documents) <= 20),
  check (current_step is null or (steps is not null and current_step between 0 and cardinality(steps) - 1))
);
create index on public.insurance_claims (household_id, sort_order);

-- ---------------------------------------------------------------------------
-- Goals & challenges (GOALS + g.log). "progress" is derived by trigger from
-- start_progress + logs, so a client can never set it directly.
-- ---------------------------------------------------------------------------
create table public.goals (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references public.households (id) on delete cascade,
  name           public.short_text not null,
  kind           public.goal_kind not null,
  mode           public.goal_mode not null,
  unit           text not null check (unit ~ '^[A-Za-z][A-Za-z -]{0,23}$'),
  target         numeric(14,2) not null check (target > 0 and target < 1000000000000),
  start_progress numeric(14,2) not null default 0 check (start_progress >= 0),
  progress       numeric(14,2) not null default 0,
  started_on     date not null default current_date,
  due_on         date not null,
  color          public.hex_color not null,
  created_by     uuid references auth.users (id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (mode = 'count' or unit = 'AED' or unit ~ '^[A-Z]{3}$'),
  check (due_on <= started_on + 3650)
);
create index on public.goals (household_id, created_at);

create table public.goal_logs (
  id           bigint generated always as identity primary key,
  goal_id      uuid not null references public.goals (id) on delete cascade,
  household_id uuid not null references public.households (id) on delete cascade,
  logged_on    date not null default current_date,
  amount       numeric(14,2) not null check (amount > 0 and amount < 1000000000000),
  created_by   uuid references auth.users (id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now()
);
create index on public.goal_logs (goal_id, id desc);

-- ---------------------------------------------------------------------------
-- 30-day plan (PLAN is a shared catalogue; ticks are per household)
-- ---------------------------------------------------------------------------
create table public.plan_items (
  id         text primary key check (id ~ '^p[0-9]{1,3}$'),
  group_name text not null check (group_name in ('This week', 'This month', 'When ready')),
  title      public.safe_text not null,
  note       public.safe_text not null,
  sort_order smallint not null default 0
);

create table public.plan_progress (
  household_id uuid not null references public.households (id) on delete cascade,
  plan_item_id text not null references public.plan_items (id) on delete cascade,
  completed_by uuid references auth.users (id) on delete set null default auth.uid(),
  completed_at timestamptz not null default now(),
  primary key (household_id, plan_item_id)
);

-- ---------------------------------------------------------------------------
-- Append-only audit trail of every change to household data.
-- ---------------------------------------------------------------------------
create table public.audit_log (
  id           bigint generated always as identity primary key,
  household_id uuid,
  actor        uuid,
  table_name   text not null,
  row_id       text,
  action       text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data     jsonb,
  new_data     jsonb,
  at           timestamptz not null default now()
);
create index on public.audit_log (household_id, at desc);

-- ---------------------------------------------------------------------------
-- Live market data (shared, public information). Written only by the
-- "market" edge function with the service role; clients can only read.
-- ---------------------------------------------------------------------------
create table public.market_quotes (
  symbol              public.ticker primary key,
  currency            public.currency_code not null default 'USD',
  price               numeric(18,6) check (price > 0),
  change_pct          numeric(9,4),
  prev_close          numeric(18,6),
  quoted_at           timestamptz,                       -- exchange timestamp of the price
  fetched_at          timestamptz,                       -- when Haven last asked the provider
  rating_strong_buy   smallint, rating_buy smallint, rating_hold smallint, rating_sell smallint, rating_strong_sell smallint,
  rating_period       date,
  prev_rating_strong_buy smallint, prev_rating_buy smallint, prev_rating_hold smallint, prev_rating_sell smallint, prev_rating_strong_sell smallint,
  ratings_fetched_at  timestamptz,
  history_fetched_at  timestamptz,
  source              text not null default 'Finnhub'
);

-- Month-end closes, used for the 1-year return and the 12-month value chart.
create table public.market_history (
  symbol public.ticker not null,
  month  date not null check (extract(day from month) = 1),
  close  numeric(18,6) not null check (close > 0),
  primary key (symbol, month)
);

create table public.fx_rates (
  base       public.currency_code not null,
  quote      public.currency_code not null,
  rate       numeric(18,8) not null check (rate > 0),
  source     text not null,
  fetched_at timestamptz not null default now(),
  primary key (base, quote)
);

-- ---------------------------------------------------------------------------
-- What Haven actually did, with real timestamps ("Agent activity").
-- Written by triggers and the edge function, never by clients.
-- ---------------------------------------------------------------------------
create table public.activity_log (
  id           bigint generated always as identity primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  icon         text not null check (icon in ('loop','cal','eye','target','pulse','doc','list','chart','shield','check')),
  message      public.safe_text not null,
  created_at   timestamptz not null default now()
);
create index on public.activity_log (household_id, created_at desc);

-- Daily net-worth snapshots (real history, starts the day the household starts).
create table public.net_worth_snapshots (
  household_id    uuid not null references public.households (id) on delete cascade,
  taken_on        date not null default current_date,
  net_worth       numeric(16,2) not null,
  total_assets    numeric(16,2) not null,
  total_debt      numeric(16,2) not null,
  liquid_cash     numeric(16,2) not null,
  portfolio_value numeric(16,2) not null,
  updated_at      timestamptz not null default now(),
  primary key (household_id, taken_on)
);
