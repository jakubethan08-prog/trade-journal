// Vercel serverless function: POST /api/create-portal-session
// Creates a Stripe Billing Portal session for the caller's own account and
// returns its URL — this is how a user cancels their subscription: one
// button in Settings redirects here, then straight into Stripe's own
// hosted portal where "Cancel plan" is one click (plus Stripe's own
// confirm step, which we don't control and shouldn't bypass).
// Requires (Vercel project env vars, never exposed to the browser):
//   STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SITE_URL
//
// One-time setup: the Stripe Customer Portal must be activated in the
// Stripe Dashboard (Settings -> Billing -> Customer portal) in both test
// and live mode before this will work.

const Stripe = require("stripe");
const { createClient } = require("@supabase/supabase-js");

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const supabaseAdmin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const authHeader = req.headers.authorization || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!token) {
    res.status(401).json({ error: "Missing session token" });
    return;
  }

  // Same server-side session check as create-checkout-session.js -- stops
  // anyone from opening the billing portal for someone else's account.
  const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(token);
  if (userErr || !userData || !userData.user) {
    res.status(401).json({ error: "Invalid or expired session" });
    return;
  }
  const user = userData.user;

  const siteUrl = (process.env.SITE_URL || "").trim().replace(/\/+$/, "");
  if (!siteUrl) {
    res.status(500).json({ error: "Server misconfigured: SITE_URL is not set" });
    return;
  }

  try {
    const { data: profile, error: profileErr } = await supabaseAdmin
      .from("profiles")
      .select("stripe_customer_id")
      .eq("id", user.id)
      .single();
    if (profileErr) throw profileErr;

    if (!profile || !profile.stripe_customer_id) {
      res.status(400).json({ error: "No subscription found for this account yet." });
      return;
    }

    const portalSession = await stripe.billingPortal.sessions.create({
      customer: profile.stripe_customer_id,
      return_url: `${siteUrl}/`,
    });

    res.status(200).json({ url: portalSession.url });
  } catch (err) {
    console.error("create-portal-session error:", err);
    res.status(500).json({ error: `Could not open billing portal: ${err.message || err.type || "unknown error"}` });
  }
};
