# A+ Trades — multi-user app

Hosted, multi-user version of the trading journal: Supabase for auth/database/file storage, Stripe for the monthly subscription, deployed to Vercel. `index.html` has no build step (same as the original file) — the only things Vercel actually builds are the two small `/api` functions that Stripe needs.

## 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com) → New project. Pick any name/region/password (the DB password isn't used anywhere in this app).
2. Once it's created: **SQL Editor → New query**, paste the entire contents of [`supabase/schema.sql`](supabase/schema.sql), and run it. This creates all five tables, every RLS policy, the `trade-media` storage bucket, and the trigger that auto-creates a `profiles` row on signup.
3. **Project Settings → API**. You'll need two values from here in step 3 below: **Project URL** and the **`anon` `public`** key. (Don't use the `service_role` key here — that one's secret and goes in Vercel, not the HTML file.)
4. **Authentication → Providers → Email**: by default Supabase requires email confirmation before a new signup can log in. That's fine for real use; if you want to test faster, you can turn "Confirm email" off temporarily (Authentication → Sign In / Providers).

## 2. Paste your Supabase keys into `index.html`

Open `index.html` and find this near the top of the `<script type="text/babel">` block:

```js
const SUPABASE_URL = "YOUR_SUPABASE_PROJECT_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Replace both with the values from step 1.3. These are **public** values — safe to commit, safe to ship to the browser. Access control comes entirely from the RLS policies in `schema.sql`, not from hiding this key.

At this point you can already open `index.html` directly in a browser (double-click it, or `python3 -m http.server` from this folder) and sign up / log in / add trades / journal entries / photos — everything except Subscribe works with zero deployment.

## 3. Create the Stripe product + price

1. [Stripe Dashboard](https://dashboard.stripe.com) (use **test mode** first) → Product catalog → **Add product**. Set it to recurring, monthly, whatever price you want.
2. Copy the **Price ID** (looks like `price_1AbC...`) — you'll set this as `STRIPE_PRICE_ID` in Vercel below.
3. Copy your **Secret key** (Developers → API keys) — this is `STRIPE_SECRET_KEY`. Never put this in `index.html`.
4. You'll add the webhook endpoint in step 5, *after* you have a deployed URL (Stripe needs a real URL to send events to).

## 4. Deploy to Vercel

No git or GitHub required — this project is small enough to deploy directly:

```bash
npm i -g vercel   # one-time, needs Node.js/npm installed
cd a-plus-trades-app
vercel
```

Follow the prompts (link or create a project). Vercel will detect `index.html` as a static file and the two files in `/api` as serverless functions automatically — no build configuration needed. Note the URL it gives you (e.g. `https://a-plus-trades.vercel.app`).

If you'd rather not install anything locally: push this folder to a new GitHub repo and use **vercel.com → Add New Project → Import** instead — same result.

## 5. Set the secret environment variables

In the Vercel dashboard: **Project → Settings → Environment Variables**. Add:

| Name | Value |
|---|---|
| `SUPABASE_URL` | same Project URL as step 1.3 |
| `SUPABASE_SERVICE_ROLE_KEY` | Project Settings → API → `service_role` key (Supabase) — **secret**, bypasses RLS |
| `STRIPE_SECRET_KEY` | from step 3.3 — **secret** |
| `STRIPE_PRICE_ID` | from step 3.2 |
| `STRIPE_WEBHOOK_SECRET` | from step 6 below (you'll come back and add this one) |
| `SITE_URL` | your deployed URL, e.g. `https://a-plus-trades.vercel.app` (no trailing slash) |

After adding/changing env vars, redeploy (`vercel --prod`, or Deployments → Redeploy) so the functions pick them up.

## 6. Create the Stripe webhook

1. Stripe Dashboard → **Developers → Webhooks → Add endpoint**.
2. Endpoint URL: `https://<your-site>/api/stripe-webhook`.
3. Events to send: `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`.
4. After creating it, copy the **Signing secret** (`whsec_...`) and set it as `STRIPE_WEBHOOK_SECRET` in Vercel (step 5), then redeploy.

## 7. Importing your existing data

In the old single-file app, click **Export** to download your `trading-journal-backup-*.json`. In this new app, once logged in, click **Import** and pick that same file — it inserts your trades and journal entries into your Supabase account (linked correctly, including the 🔗 trade↔journal links) and refreshes the view. Note: photos/videos attached to trades were never part of the export format (before or after this migration) — only trade/journal data round-trips through Export/Import.

## 8. Test checklist

**Supabase (no Stripe needed yet):**
- Sign up → confirm email if required → log in.
- Add a trade, a journal entry, set a profit target/max loss/colors → refresh the page → confirm everything is still there (i.e. it's coming from Supabase, not `localStorage`).
- Upload a photo to a trade, view it, delete it.
- Sign up a *second* test account and confirm it sees none of the first account's data.
- Export, then Import the same file back in, and confirm trades/journal entries appear twice with links intact (Import always adds new rows — it doesn't dedupe).

**Stripe (test mode):**
- New accounts start in a 7-day trial (`profiles.subscription_status = 'trialing'`) — you'll only see the paywall once that expires, or you can flip a test row's `subscription_status` to `'canceled'` directly in the Supabase table editor to see the paywall immediately.
- Click **Subscribe** → complete Checkout with Stripe's test card `4242 4242 4242 4242`, any future expiry/CVC.
- You should land back on the app with "Activating your account…", then the paywall should clear within a few seconds.
- In Stripe Dashboard → Webhooks → your endpoint, confirm the events show as succeeded (200).
- Cancel the subscription from the Stripe dashboard (as if the customer canceled) and confirm the app shows the paywall again on next load.

Only after all of this works in Stripe test mode should you switch the Stripe keys to live mode.

## Notes

- `index.html` has zero build step by design — same as the original file, just with a Supabase script tag added. There's nothing to `npm install` for the frontend.
- `package.json` and `/api` exist only for the two Stripe serverless functions.
- The `profiles` table's subscription columns can only be written by the webhook (using the service-role key) — see the `revoke`/`grant` statements in `schema.sql`. A logged-in user cannot grant themselves a subscription by calling the Supabase API directly.
