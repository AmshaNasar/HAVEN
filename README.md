# Haven on Supabase

The dashboard (`haven-dashboard/index.html`) now loads every number from Supabase. Nothing is hardcoded or simulated in the page any more.

- **Household figures** (balances, bills, debts, claims, goals, plan ticks) are rows in your database. For now that's the demo household; edit the rows to use real figures.
- **Market figures** are live. Finnhub supplies prices and analyst ratings. Twelve Data supplies month-end closes (for the 1-year return and the 12-month chart) and the USD→AED rate. Both have free plans.
- **History is real.** Net worth is snapshotted every day from the day you start, and the activity feed lists events the database actually recorded, with real times.

## Set it up (about 10 minutes, all in the browser)

### 1. Create the database
Supabase dashboard → **SQL Editor** → New query → paste all of [`setup.sql`](setup.sql) → **Run**. Run it once, on a fresh project.

### 2. Get the two market API keys (free)
- Finnhub: sign up at finnhub.io and copy your API key.
- Twelve Data: sign up at twelvedata.com and copy your API key.

### 3. Add the market function
Supabase dashboard → **Edge Functions** → **Deploy a new function** → **Via editor**.
- Name it exactly `market`.
- Replace the sample code with [`supabase/functions/market/index.ts`](supabase/functions/market/index.ts), then deploy.
- Turn **Verify JWT** off for this function (it checks sign-ins itself).
- **Edge Functions → Secrets**: add `FINNHUB_API_KEY`, `TWELVEDATA_API_KEY` and `CRON_SECRET` (any long random string). Optionally add `ALLOWED_ORIGINS` with the address your dashboard is served from (for example `https://haven.example.com`) to lock the function to your site.

### 4. Turn on background price refresh
In the SQL Editor run, with your project ref and the same `CRON_SECRET`:
```sql
select private.schedule_market_refresh('https://<ref>.supabase.co/functions/v1/market', '<CRON_SECRET>');
```
Prices, FX and net-worth snapshots then refresh every 15 minutes even when nobody has the page open. Both values are stored in Vault, not in the job text.

### Already ran an older setup.sql?
Run [`upgrade-1.sql`](upgrade-1.sql) once instead of setup.sql. It is safe to run twice.

### 5. Connect the dashboard
Supabase dashboard → **Project Settings → API**. Copy the **Project URL** and the **publishable (anon) key**, and paste them into `HAVEN_CONFIG` near the top of the script in `haven-dashboard/index.html`. Both are meant to be public; the database's security rules protect the data. **Never paste the secret or service_role key into the page.**

### 6. Lock down sign-in
In **Authentication**:
- Sign In / Providers → **turn off "Allow new users to sign up"**. Haven is invite-only; add people under Users.
- Passwords: minimum length 12 with lower, upper, digits and symbols. Turn on leaked-password protection if your plan has it.
- URL Configuration → set **Site URL** to wherever the dashboard is hosted.
- **Change the demo passwords**, or delete the demo users, before you show this to anyone.

Demo sign-ins: `maya@haven.demo` (owner) and `advisor@haven.demo` (read only), both `HavenDemo!2026`.

## Where each number comes from

| On screen | Source |
|---|---|
| Accounts, bills, income, spending, subscriptions, debts, claims | Tables of the same names |
| Investment account balance, holding values | Units held × live Finnhub price × USD/AED (`holdings_live`, `accounts_live`) |
| 1-year return, 12-month value chart | Twelve Data month-end closes (`market_history`, `portfolio_history`) |
| Market pulse (Buy / Hold / Sell) | Finnhub recommendation trends. ETFs usually have none and show none. |
| Net worth history, "since last month" | Daily snapshots (`net_worth_snapshots`). The line appears after the second day. |
| Cash flow chart | Your recorded transactions per month (`monthly_cash_flow`) |
| Agent activity | `activity_log`, written by the database and the market function |
| Briefing and alerts | Worked out from the data: missing claim documents, the next 7 days of bills, flagged subscriptions, holdings over your guideline |
| Goals and the 30-day plan | `goals`, `goal_logs`, `plan_items`, `plan_progress` |
| Scenario presets | Built from your subscriptions, bank fees, debts, holdings and pending payouts |

The scenario lab's starting assumptions come from the `households` row: `expected_return_pct`, `home_growth_pct`, and `fallback_volatility_pct` (used only until a year of price history exists; otherwise volatility is measured from your holdings' real monthly closes). The currency shown is the household's `currency`.

The demo holdings are real tickers: VT, FUTU (Futu Holdings, a Chinese fintech broker listed in the US), BND, GLD and SGOV. Change `symbol` and `quantity` in `holdings` to your own. Finnhub's free plan covers US-listed symbols.

## Security
- Row level security on every table, and no access at all without signing in.
- Owner, member and viewer roles per household.
- Least-privilege column grants. Prices, the activity feed and goal progress can't be written by any browser.
- API keys stay server side in the edge function and travel in headers, never in URLs.
- The database rejects markup in any stored text (the dashboard renders text as HTML).
- An append-only audit log of every change.
- The page pins supabase-js with a subresource-integrity hash and sets a Content-Security-Policy that only allows connections to Supabase.

38 automated security tests cover this (`supabase test db`).

## For developers (optional CLI route)
```bash
supabase link --project-ref <ref>
supabase db push --include-seed
supabase functions deploy market
supabase secrets set FINNHUB_API_KEY=... TWELVEDATA_API_KEY=...
supabase config push
```
