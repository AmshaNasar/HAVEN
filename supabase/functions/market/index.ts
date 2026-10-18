// Haven · live market data.
//
// POST /functions/v1/market  { "household_id": "<uuid>" }   (signed-in user's JWT required)
// POST /functions/v1/market  { "cron": true }  + header x-haven-cron: <CRON_SECRET>
//      (sent by pg_cron every 15 minutes: refreshes every household, no browser needed)
//
// Refreshes prices for the symbols held, then updates today's net-worth snapshot.
//   Finnhub      quotes (60 s cache) and analyst recommendation trends (12 h cache)
//   Twelve Data  month-end closes for the 1-year return and 12-month chart (12 h cache)
//                and the USD -> household currency exchange rate (6 h cache)
// API keys live only here as secrets (FINNHUB_API_KEY, TWELVEDATA_API_KEY) and are
// sent in headers, never in URLs. Results are written with the service role into
// tables clients can read but never write. No third-party imports.

const FINNHUB = Deno.env.get("FINNHUB_BASE_URL") ?? "https://finnhub.io/api/v1";
const TWELVE = Deno.env.get("TWELVEDATA_BASE_URL") ?? "https://api.twelvedata.com";
const FINNHUB_KEY = Deno.env.get("FINNHUB_API_KEY") ?? "";
const TWELVE_KEY = Deno.env.get("TWELVEDATA_API_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "*").split(",").map((s) => s.trim());

const QUOTE_TTL = 60e3, RATINGS_TTL = 12 * 3600e3, HISTORY_TTL = 12 * 3600e3, FX_TTL = 6 * 3600e3;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TICKER = /^[A-Z0-9][A-Z0-9.\-]{0,11}$/;

function cors(req: Request) {
  const origin = req.headers.get("origin") ?? "";
  const allow = ORIGINS.includes("*") ? "*" : ORIGINS.includes(origin) ? origin : ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

function sameSecret(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

const stale = (ts: string | null | undefined, ttl: number) => !ts || Date.now() - new Date(ts).getTime() > ttl;

async function getJson(url: string, headers: Record<string, string>) {
  const r = await fetch(url, { headers, signal: AbortSignal.timeout(8000) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return await r.json();
}
const finnhub = (path: string) => getJson(`${FINNHUB}${path}`, { "X-Finnhub-Token": FINNHUB_KEY });
const twelve = (path: string) => getJson(`${TWELVE}${path}`, { Authorization: `apikey ${TWELVE_KEY}` });

// Minimal PostgREST client. "jwt" decides whose permissions apply.
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
async function rest(jwt: string, path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: jwt === SERVICE ? SERVICE : ANON, Authorization: `Bearer ${jwt}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`db ${r.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}
const upsert = (table: string, rows: unknown) =>
  rest(SERVICE, table, { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(rows) });

// Fetch whatever is stale for these symbols and currencies. Caches keep provider calls low.
async function refresh(symbols: string[], currencies: string[]) {
  const errors: string[] = [];
  if (!FINNHUB_KEY) errors.push("FINNHUB_API_KEY is not set");
  if (!TWELVE_KEY) errors.push("TWELVEDATA_API_KEY is not set (1-year return, 12-month chart and live FX are off)");

  const existing: any[] = symbols.length ? await rest(SERVICE, `market_quotes?symbol=in.(${symbols.map((s) => `"${s}"`).join(",")})`) : [];
  const bySym = new Map(existing.map((q) => [q.symbol, q]));
  let refreshed = 0;

  for (const sym of symbols) {
    const cur = bySym.get(sym) ?? {};
    const row: Record<string, unknown> = { symbol: sym };
    const enc = encodeURIComponent(sym);

    if (FINNHUB_KEY && stale(cur.fetched_at, QUOTE_TTL)) {
      try {
        const q = await finnhub(`/quote?symbol=${enc}`);
        if (!(q.c > 0)) throw new Error("no price");
        Object.assign(row, {
          price: q.c, change_pct: q.dp ?? null, prev_close: q.pc ?? null, currency: "USD",
          quoted_at: q.t ? new Date(q.t * 1000).toISOString() : null, fetched_at: new Date().toISOString(), source: "Finnhub",
        });
        refreshed++;
      } catch (e) { errors.push(`${sym} quote: ${(e as Error).message}`); }
    }

    if (FINNHUB_KEY && stale(cur.ratings_fetched_at, RATINGS_TTL)) {
      try {
        const rec = await finnhub(`/stock/recommendation?symbol=${enc}`);
        const [now, prev] = Array.isArray(rec) ? rec : [];
        const pick = (r: any, p: string) => r ? {
          [`${p}rating_strong_buy`]: r.strongBuy, [`${p}rating_buy`]: r.buy, [`${p}rating_hold`]: r.hold,
          [`${p}rating_sell`]: r.sell, [`${p}rating_strong_sell`]: r.strongSell,
        } : {
          [`${p}rating_strong_buy`]: null, [`${p}rating_buy`]: null, [`${p}rating_hold`]: null,
          [`${p}rating_sell`]: null, [`${p}rating_strong_sell`]: null,
        };
        Object.assign(row, pick(now, ""), pick(prev, "prev_"), { rating_period: now?.period ?? null, ratings_fetched_at: new Date().toISOString() });
      } catch (e) { errors.push(`${sym} ratings: ${(e as Error).message}`); }
    }

    if (TWELVE_KEY && stale(cur.history_fetched_at, HISTORY_TTL)) {
      try {
        const ts = await twelve(`/time_series?symbol=${enc}&interval=1month&outputsize=14`);
        if (ts.status === "error" || !Array.isArray(ts.values)) throw new Error(ts.message ?? "no data");
        const rows = ts.values
          .map((v: any) => ({ symbol: sym, month: `${String(v.datetime).slice(0, 7)}-01`, close: Number(v.close) }))
          .filter((v: any) => /^\d{4}-\d{2}-01$/.test(v.month) && v.close > 0);
        await upsert("market_history", rows);
        row.history_fetched_at = new Date().toISOString();
      } catch (e) { errors.push(`${sym} history: ${(e as Error).message}`); }
    }

    if (Object.keys(row).length > 1) {
      try { await upsert("market_quotes", row); } catch (e) { errors.push(`${sym} save: ${(e as Error).message}`); }
    }
  }

  // FX: USD -> each household currency
  for (const ccy of currencies.filter((c) => c !== "USD" && /^[A-Z]{3}$/.test(c))) {
    if (!TWELVE_KEY) break;
    const [fx] = await rest(SERVICE, `fx_rates?base=eq.USD&quote=eq.${ccy}&select=fetched_at`);
    if (!fx || stale(fx.fetched_at, FX_TTL)) {
      try {
        const r = await twelve(`/exchange_rate?symbol=USD/${ccy}`);
        if (!(Number(r.rate) > 0)) throw new Error(r.message ?? "no rate");
        await upsert("fx_rates", { base: "USD", quote: ccy, rate: Number(r.rate), source: "Twelve Data", fetched_at: new Date().toISOString() });
      } catch (e) { errors.push(`FX USD/${ccy}: ${(e as Error).message}`); }
    }
  }
  return { refreshed, errors };

}

async function finishHousehold(householdId: string, refreshed: number) {
  if (refreshed) {
    const [last] = await rest(SERVICE, `activity_log?household_id=eq.${householdId}&icon=eq.pulse&select=created_at&order=created_at.desc&limit=1`);
    if (stale(last?.created_at, 3 * 3600e3)) {
      await rest(SERVICE, "activity_log", { method: "POST", body: JSON.stringify(
        { household_id: householdId, icon: "pulse", message: `Refreshed live prices for ${refreshed} holding${refreshed > 1 ? "s" : ""}` }) });
    }
  }
  await rest(SERVICE, "rpc/refresh_snapshot", { method: "POST", body: JSON.stringify({ p_household: householdId }) });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "POST only" }, 405);

  let body: any = {};
  try { body = await req.json(); } catch { /* empty body */ }

  // Scheduled run from pg_cron: every household, authorised by the shared secret.
  const cronHeader = req.headers.get("x-haven-cron") ?? "";
  if (cronHeader) {
    if (!CRON_SECRET || !sameSecret(cronHeader, CRON_SECRET)) return json(req, { error: "bad cron secret" }, 401);
    const houses: { id: string; currency: string }[] = await rest(SERVICE, "households?select=id,currency");
    const held: { household_id: string; symbol: string }[] = await rest(SERVICE, "holdings?select=household_id,symbol");
    const symbols = [...new Set(held.map((h) => h.symbol))].filter((s) => TICKER.test(s)).slice(0, 50);
    const { refreshed, errors } = await refresh(symbols, [...new Set(houses.map((h) => h.currency))]);
    for (const h of houses) {
      const n = held.filter((x) => x.household_id === h.id).length;
      try { await finishHousehold(h.id, refreshed ? n : 0); } catch (e) { errors.push(`snapshot ${h.id}: ${(e as Error).message}`); }
    }
    return json(req, { mode: "cron", households: houses.length, symbols, refreshed, errors });
  }

  // A signed-in user opening the dashboard.
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json(req, { error: "sign in first" }, 401);
  const householdId = String(body.household_id ?? "");
  if (!UUID.test(householdId)) return json(req, { error: "household_id must be a uuid" }, 400);

  const jwt = auth.slice(7);
  const who = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: ANON, Authorization: auth } });
  if (!who.ok) return json(req, { error: "sign in first" }, 401);

  // Membership is checked through RLS with the caller's own token: a non-member gets no rows.
  const [house] = await rest(jwt, `households?id=eq.${householdId}&select=currency`);
  if (!house) return json(req, { error: "not a member of this household" }, 403);
  const held: { symbol: string }[] = await rest(jwt, `holdings?household_id=eq.${householdId}&select=symbol`);
  const symbols = [...new Set(held.map((h) => h.symbol))].filter((s) => TICKER.test(s)).slice(0, 25);

  const { refreshed, errors } = await refresh(symbols, [house.currency]);
  await finishHousehold(householdId, refreshed);
  return json(req, { symbols, refreshed, errors });
});
