import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

// Streams OpenAI-compatible chat completions through to OpenRouter using the
// server-held OPENROUTER_API_KEY. Only signed-in users may call it, models are
// whitelisted, and each user gets a fixed number of requests per UTC day.

const DAILY_LIMIT = parseInt(Deno.env.get("LLM_DAILY_REQUEST_LIMIT") ?? "200", 10);
// Keep in sync with OpenRouterModelCatalog.swift.
const DEFAULT_ALLOWED_MODELS = [
  "anthropic/claude-sonnet-4.6",
  "anthropic/claude-sonnet-4.5",
  "anthropic/claude-sonnet-4",
].join(",");

const ALLOWED_MODELS = (Deno.env.get("LLM_ALLOWED_MODELS") ?? DEFAULT_ALLOWED_MODELS)
  .split(",")
  .map((m) => m.trim())
  .filter(Boolean);

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return json({ error: "POST only" }, 405);
    }

    const userId = await authedUserId(req);
    if (!userId) {
      return json({ error: "Sign in required" }, 401);
    }

    if (!(await hasRemainingCredits(userId))) {
      return json({ error: "Subscribe or buy credits to keep using the AI assistant." }, 402);
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json({ error: "Invalid JSON body" }, 400);
    }

    const model = body?.model;
    if (typeof model !== "string" || !ALLOWED_MODELS.includes(model)) {
      return json({ error: `Model not allowed. Allowed: ${ALLOWED_MODELS.join(", ")}` }, 400);
    }

    const used = await incrementUsage(userId);
    if (used === null) {
      return json({ error: "Usage tracking unavailable" }, 500);
    }
    if (used > DAILY_LIMIT) {
      return json({ error: "Daily request limit reached. Try again tomorrow." }, 429);
    }

    const upstream = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("OPENROUTER_API_KEY")!}`,
        "Content-Type": "application/json",
        Accept: "text/event-stream",
      },
      body: JSON.stringify(body),
    });

    // Pass the (possibly streaming) response through untouched.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.headers.get("content-type") ?? "application/json",
      },
    });
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

// Mirrors AccountService.hasCredits: a paid tier's monthly budget, plus any
// purchased top-up, minus what's been spent this billing period.
async function hasRemainingCredits(userId: string): Promise<boolean> {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const base = Deno.env.get("SUPABASE_URL")!;
  const headers = {
    Authorization: `Bearer ${serviceKey}`,
    apikey: serviceKey,
  };

  const billingRes = await fetch(
    `${base}/rest/v1/billing_accounts?user_id=eq.${userId}&select=tier,purchased_credits,spent_credits_this_period`,
    { headers },
  );
  if (!billingRes.ok) return false;
  const billingRows = await billingRes.json();
  const billing = billingRows[0] ?? { tier: "none", purchased_credits: 0, spent_credits_this_period: 0 };

  let monthlyBudget = 0;
  if (billing.tier === "pro" || billing.tier === "max") {
    const planRes = await fetch(
      `${base}/rest/v1/available_plans?tier=eq.${billing.tier}&select=monthly_budget_credits`,
      { headers },
    );
    if (planRes.ok) {
      const planRows = await planRes.json();
      monthlyBudget = planRows[0]?.monthly_budget_credits ?? 0;
    }
  }

  const budget = monthlyBudget + (billing.purchased_credits ?? 0);
  const remaining = budget - (billing.spent_credits_this_period ?? 0);
  return remaining > 0;
}

// Atomically bumps today's request count via the increment_llm_usage SQL function
// (service role; users cannot call it) and returns the new count.
async function incrementUsage(userId: string): Promise<number | null> {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/increment_llm_usage`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceKey}`,
      apikey: serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ uid: userId }),
  });
  if (!res.ok) return null;
  const count = await res.json();
  return typeof count === "number" ? count : null;
}
