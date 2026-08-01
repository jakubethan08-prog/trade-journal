// Vercel serverless function: POST /api/stripe-webhook
// Stripe calls this directly (not the browser) whenever a checkout completes
// or a subscription changes, and this is the ONLY thing allowed to write the
// subscription columns on `profiles` (see supabase/schema.sql — the
// authenticated role has its UPDATE grant restricted to display_name only).
// Requires (Vercel project env vars): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const Stripe = require("stripe");
const { createClient } = require("@supabase/supabase-js");

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const supabaseAdmin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// Stripe's signature check needs the exact raw request body, so the default
// JSON body parser has to be turned off for this route.
module.exports.config = { api: { bodyParser: false } };

function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function mapStripeStatus(stripeStatus) {
  switch (stripeStatus) {
    case "active":
    case "trialing":
      return stripeStatus;
    case "past_due":
    case "unpaid":
      return "past_due";
    default:
      // canceled, incomplete, incomplete_expired, paused, etc.
      return "canceled";
  }
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).end();
    return;
  }

  let event;
  try {
    const rawBody = await readRawBody(req);
    event = stripe.webhooks.constructEvent(rawBody, req.headers["stripe-signature"], process.env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error("stripe-webhook signature verification failed:", err.message);
    res.status(400).send(`Webhook signature verification failed: ${err.message}`);
    return;
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object;
        const customerId = session.customer;
        const subscriptionId = session.subscription;
        let periodEnd = null;
        let status = "active";
        if (subscriptionId) {
          const sub = await stripe.subscriptions.retrieve(subscriptionId);
          periodEnd = sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null;
          status = mapStripeStatus(sub.status);
        }
        await supabaseAdmin
          .from("profiles")
          .update({ subscription_status: status, stripe_subscription_id: subscriptionId, current_period_end: periodEnd })
          .eq("stripe_customer_id", customerId);
        break;
      }
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object;
        const status = event.type === "customer.subscription.deleted" ? "canceled" : mapStripeStatus(sub.status);
        const periodEnd = sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null;
        await supabaseAdmin
          .from("profiles")
          .update({ subscription_status: status, stripe_subscription_id: sub.id, current_period_end: periodEnd })
          .eq("stripe_customer_id", sub.customer);
        break;
      }
      default:
        break;
    }
    res.status(200).json({ received: true });
  } catch (err) {
    console.error("stripe-webhook handler error:", err);
    res.status(500).json({ error: "Webhook handler failed" });
  }
};
