import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import Stripe from "npm:stripe@18";

// Returns a Stripe Customer Portal { url } for the signed-in user so they can
// manage or cancel their subscription in the browser.

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!);

serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "POST only" }, 405);

    const userId = await authedUserId(req);
    if (!userId) return json({ error: "Sign in required" }, 401);

    const customerId = await customerIdFor(userId);
    if (!customerId) return json({ error: "No billing account yet" }, 404);

    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: `${Deno.env.get("SUPABASE_URL")}/functions/v1/stripe-return?state=portal`,
    });
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

async function authedUserId(req: Request): Promise<string | null> {
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
  return typeof user?.id === "string" ? user.id : null;
}

async function customerIdFor(userId: string): Promise<string | null> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const res = await fetch(
    `${Deno.env.get("SUPABASE_URL")}/rest/v1/billing_accounts?user_id=eq.${userId}&select=stripe_customer_id`,
    { headers: { Authorization: `Bearer ${key}`, apikey: key } },
  );
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0]?.stripe_customer_id ?? null;
}
