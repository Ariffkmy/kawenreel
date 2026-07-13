import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import Stripe from "npm:stripe@18";

// Creates a Stripe Checkout Session for the signed-in user: subscription mode
// for { tier: "pro" | "max" }, one-time payment mode for { dollars: 5..1000 }
// credit top-offs. Returns { url } for the app to open in the browser.

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!);
const TOPOFF_CURRENCY = Deno.env.get("STRIPE_TOPOFF_CURRENCY") ?? "myr";
const MIN_TOPOFF_DOLLARS = 5;
const MAX_TOPOFF_DOLLARS = 1000;

serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "POST only" }, 405);

    const user = await authedUser(req);
    if (!user) return json({ error: "Sign in required" }, 401);

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json({ error: "Invalid JSON body" }, 400);
    }

    const customerId = await getOrCreateCustomer(user.id, user.email);
    const returnBase = `${Deno.env.get("SUPABASE_URL")}/functions/v1/stripe-return`;

    let session: Stripe.Checkout.Session;
    if (typeof body.tier === "string") {
      const plan = await planForTier(body.tier);
      if (!plan) return json({ error: `Unknown tier: ${body.tier}` }, 400);

      session = await stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customerId,
        line_items: [{ price: plan.stripe_price_id, quantity: 1 }],
        subscription_data: { metadata: { user_id: user.id } },
        metadata: { user_id: user.id },
        success_url: `${returnBase}?state=success`,
        cancel_url: `${returnBase}?state=cancel`,
      });
    } else if (typeof body.dollars === "number") {
      const dollars = Math.floor(body.dollars);
      if (dollars < MIN_TOPOFF_DOLLARS || dollars > MAX_TOPOFF_DOLLARS) {
        return json({ error: `dollars must be ${MIN_TOPOFF_DOLLARS}-${MAX_TOPOFF_DOLLARS}` }, 400);
      }
      session = await stripe.checkout.sessions.create({
        mode: "payment",
        customer: customerId,
        line_items: [{
          quantity: 1,
          price_data: {
            currency: TOPOFF_CURRENCY,
            unit_amount: dollars * 100,
            product_data: { name: "Kawenreel Credits" },
          },
        }],
        metadata: { user_id: user.id, credit_dollars: String(dollars) },
        success_url: `${returnBase}?state=success`,
        cancel_url: `${returnBase}?state=cancel`,
      });
    } else {
      return json({ error: "Body must include tier or dollars" }, 400);
    }

    return json({ url: session.url }, 200);
  } catch (err) {
    return json({ error: err.message }, 500);
  }
});

function json(payload: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Resolves the bearer token to a real signed-in user; the shipped anon key alone is rejected.
async function authedUser(req: Request): Promise<{ id: string; email?: string } | null> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: Deno.env.get("SUPABASE_ANON_KEY")!,
    },
  });
  if (!res.ok) return null;
  const user = await res.json();
  return typeof user?.id === "string" ? { id: user.id, email: user.email } : null;
}

function serviceHeaders(): Record<string, string> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return {
    Authorization: `Bearer ${key}`,
    apikey: key,
    "Content-Type": "application/json",
  };
}

async function planForTier(
  tier: string,
): Promise<{ stripe_price_id: string } | null> {
  const res = await fetch(
    `${Deno.env.get("SUPABASE_URL")}/rest/v1/available_plans?tier=eq.${tier}&select=stripe_price_id`,
    { headers: serviceHeaders() },
  );
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0] ?? null;
}

// Reuses the stored Stripe customer or creates one tagged with the Supabase user id.
async function getOrCreateCustomer(userId: string, email?: string): Promise<string> {
  const base = Deno.env.get("SUPABASE_URL")!;
  const res = await fetch(
    `${base}/rest/v1/billing_accounts?user_id=eq.${userId}&select=stripe_customer_id`,
    { headers: serviceHeaders() },
  );
  if (res.ok) {
    const rows = await res.json();
    const existing = rows[0]?.stripe_customer_id;
    if (typeof existing === "string" && existing.length > 0) return existing;
  }

  const customer = await stripe.customers.create({
    email,
    metadata: { user_id: userId },
  });

  const upsert = await fetch(`${base}/rest/v1/billing_accounts`, {
    method: "POST",
    headers: {
      ...serviceHeaders(),
      Prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify({ user_id: userId, stripe_customer_id: customer.id }),
  });
  if (!upsert.ok) throw new Error(`Failed to store customer id: ${await upsert.text()}`);
  return customer.id;
}
