# Haven

A household money dashboard. Every number comes from a Supabase backend, and market prices are live.

## Try it (for friends)

You don't need to set anything up. The owner will send you a **Project URL** and a **publishable key**.

1. Download [`dashboard/index.html`](dashboard/index.html).
2. Open it in a text editor and find `HAVEN_CONFIG` near the top of the script.
3. Paste the URL and key you were sent between the quotes, then save.
4. Open the file in your browser and sign in with the email and password the owner gave you.

The publishable key is meant to be shared. It only lets people sign in. The database's security rules decide what each person can see, and nobody can sign up on their own. Never paste a secret or service_role key into the page.

## What's in this repo

- `dashboard/index.html` is the page.
- `setup.sql`, `upgrade-1.sql` and `supabase/` are the backend. Only the owner needs these.

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
| Foresight (weekly risk report) | `risk_reports`, `risk_findings`, worked out from everything above |
| Scenario presets | Built from your subscriptions, bank fees, debts, holdings and pending payouts |

The scenario lab's starting assumptions come from the `households` row: `expected_return_pct`, `home_growth_pct`, and `fallback_volatility_pct` (used only until a year of price history exists; otherwise volatility is measured from your holdings' real monthly closes). The currency shown is the household's `currency`.

The demo holdings are real tickers: VT, FUTU (Futu Holdings, a Chinese fintech broker listed in the US), BND, GLD and SGOV. Change `symbol` and `quantity` in `holdings` to your own. Finnhub's free plan covers US-listed symbols.

## Foresight: the weekly risk report

Every Monday Haven looks a week ahead and writes a report of the risks it can see forming.
Each one says what is causing it, what it leads to if nothing changes, how severe it is, and
what would change it. Where a fix can be modelled, the report shows what it would be worth
over ten years and loads it straight into the Scenario lab.

It currently watches for: bills due in the next week that are larger than the account they
come from; spending above income; a thin emergency fund; debt at a high rate; a holding above
your own guideline; flagged subscriptions; claim documents going overdue; goals that have
fallen behind the pace they need; net worth falling month on month; and holdings with no live
price (which makes every other figure understated).

A new report raises an alert on the home page and in the bell. Opening Foresight clears it for
the whole household. **Re-check now** rebuilds the report against your latest numbers.

The analysis is deterministic, not a language model. Every figure in a report traces back to a
row you can open, the same inputs always produce the same report, and nothing is sent to a
third party. The report is written by the database itself, so it cannot be edited from a browser.

## Security
- Row level security on every table, and no access at all without signing in.
- Owner, member and viewer roles per household.
- Least-privilege column grants. Prices, the activity feed and goal progress can't be written by any browser.
- API keys stay server side in the edge function and travel in headers, never in URLs.
- The database rejects markup in any stored text (the dashboard renders text as HTML).
- An append-only audit log of every change.
- The page pins supabase-js with a subresource-integrity hash and sets a Content-Security-Policy that only allows connections to Supabase.

52 automated tests cover this (`supabase test db`).

## For the owner: setting up the backend (about 10 minutes, all in the browser)

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

### 7. Weekly foresight reports
`setup.sql` schedules them for Monday 06:00 if `pg_cron` is available. The dashboard also
rebuilds a report that is more than a week old whenever someone opens it, so an idle household
still gets one. Nothing extra to configure.

### Already ran an older setup.sql?
Run [`upgrade-1.sql`](upgrade-1.sql), then [`upgrade-3.sql`](upgrade-3.sql) for the Foresight
risk advisor. Both are safe to run more than once.
Its last line — the `schedule_market_refresh` call — is left commented out on purpose: run it
separately, on its own, with your project ref and your real `CRON_SECRET` filled in. The SQL
Editor runs a pasted script as one transaction, so a bad value there would roll back the whole
upgrade.

### 5. Connect the dashboard
Supabase dashboard → **Project Settings → API**. Copy the **Project URL** and the **publishable (anon) key**, and paste them into `HAVEN_CONFIG` near the top of the script in `dashboard/index.html`. Both are meant to be public; the database's security rules protect the data. **Never paste the secret or service_role key into the page.**

### 6. Lock down sign-in
In **Authentication**:
- Sign In / Providers → **turn off "Allow new users to sign up"**. Haven is invite-only; add people under Users.
- Passwords: minimum length 12 with lower, upper, digits and symbols. Turn on leaked-password protection if your plan has it.
- URL Configuration → set **Site URL** to wherever the dashboard is hosted.
- **Change the demo passwords**, or delete the demo users, before you show this to anyone.

Demo sign-ins: `maya@haven.demo` (owner) and `advisor@haven.demo` (read only), both `HavenDemo!2026`.
