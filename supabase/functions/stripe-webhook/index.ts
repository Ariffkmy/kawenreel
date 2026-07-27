import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import Stripe from "npm:stripe@18";

// Stripe webhook: the only writer of billing_accounts. Verifies the event
// signature, then updates tier / credits / period state via the service role.
// Deploy with --no-verify-jwt (Stripe cannot send a Supabase JWT).

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!);
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const CREDITS_PER_DOLLAR = parseInt(Deno.env.get("CREDITS_PER_DOLLAR") ?? "100", 10);

serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  if (!signature) return new Response("Missing signature", { status: 400 });

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      await req.text(),
      signature,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!,
      undefined,
      cryptoProvider,
    );
  } catch (err) {
    return new Response(`Signature verification failed: ${err.message}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.mode === "payment" && session.payment_status === "paid") {
          await grantPurchasedCredits(session);
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated": {
        await syncSubscription(event.data.object as Stripe.Subscription);
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const userId = await userIdForSubscription(sub);
        if (userId) {
          await patchAccount(userId, {
            tier: "none",
            stripe_subscription_id: null,
            current_period_end: null,
            cancel_at_period_end: false,
          });
        }
        break;
      }
      case "invoice.paid": {
        const invoice = event.data.object as Stripe.Invoice;
        if (invoice.billing_reason === "subscription_cycle") {
          const userId = await userIdForCustomer(customerIdOf(invoice.customer));
          if (userId) await patchAccount(userId, { spent_credits_this_period: 0 });
        } else if (invoice.billing_reason === "subscription_create") {
          await awardAffiliateCommission(invoice);
        }
        break;
      }
      case "charge.refunded": {
        const charge = event.data.object as Stripe.Charge;
        await reverseAffiliateCommission(invoiceIdOf(charge.invoice), "refund");
        break;
      }
      case "charge.dispute.created": {
        const dispute = event.data.object as Stripe.Dispute;
        const chargeId = typeof dispute.charge === "string" ? dispute.charge : dispute.charge?.id;
        if (chargeId) {
          const charge = await stripe.charges.retrieve(chargeId);
          await reverseAffiliateCommission(invoiceIdOf(charge.invoice), "chargeback");
        }
        break;
      }
    }
    return new Response(JSON.stringify({ received: true }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    // Non-2xx makes Stripe retry the event later.
    return new Response(`Handler error: ${err.message}`, { status: 500 });
  }
});

function customerIdOf(customer: string | Stripe.Customer | Stripe.DeletedCustomer | null): string | null {
  if (typeof customer === "string") return customer;
  return customer?.id ?? null;
}

function invoiceIdOf(invoice: string | Stripe.Invoice | null | undefined): string | null {
  if (typeof invoice === "string") return invoice;
  return invoice?.id ?? null;
}

// Affiliate commission is earned on the referred user's first subscription
// invoice only. The RPC is idempotent on the invoice id, so Stripe retries and
// redelivered events cannot pay twice.
async function awardAffiliateCommission(invoice: Stripe.Invoice) {
  const userId = await userIdForCustomer(customerIdOf(invoice.customer));
  if (!userId || !invoice.id) return;
  const amount = invoice.amount_paid ?? 0;
  if (amount <= 0) return;

  const outcome = await callRpc("record_affiliate_commission", {
    p_referred_user_id: userId,
    p_stripe_invoice_id: invoice.id,
    p_amount_cents: amount,
    p_currency: invoice.currency ?? "myr",
  });
  console.log(`affiliate commission ${outcome} for invoice ${invoice.id}`);
}

// Any refund or chargeback on a commissioned invoice reverses the whole
// commission while it is still pending; once paid out it is absorbed.
async function reverseAffiliateCommission(invoiceId: string | null, reason: string) {
  if (!invoiceId) return;
  const outcome = await callRpc("reverse_affiliate_commission", {
    p_stripe_invoice_id: invoiceId,
    p_reason: reason,
  });
  if (outcome === "absorbed") {
    console.warn(`affiliate commission already paid out, absorbing ${reason} on ${invoiceId}`);
  } else {
    console.log(`affiliate commission ${outcome} for invoice ${invoiceId} (${reason})`);
  }
}

async function callRpc(name: string, params: Record<string, unknown>): Promise<string | null> {
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders(),
    body: JSON.stringify(params),
  });
  if (!res.ok) throw new Error(`${name} failed: ${await res.text()}`);
  const text = (await res.text()).trim();
  return text.replace(/^"|"$/g, "") || null;
}

async function syncSubscription(sub: Stripe.Subscription) {
  const userId = await userIdForSubscription(sub);
  if (!userId) return;

  const active = sub.status === "active" || sub.status === "trialing" || sub.status === "past_due";
  let tier = "none";
  if (active) {
    const priceId = sub.items.data[0]?.price?.id;
    tier = priceId ? (await tierForPriceId(priceId)) ?? "none" : "none";
  }

  const periodEnd = sub.items.data[0]?.current_period_end ?? null;
  await patchAccount(userId, {
    tier,
    stripe_subscription_id: sub.id,
    stripe_customer_id: customerIdOf(sub.customer),
    current_period_end: periodEnd ? new Date(periodEnd * 1000).toISOString() : null,
    cancel_at_period_end: sub.cancel_at_period_end ?? false,
  });
}

async function grantPurchasedCredits(session: Stripe.Checkout.Session) {
  const userId = session.metadata?.user_id;
  const dollars = parseInt(session.metadata?.credit_dollars ?? "0", 10);
  if (!userId || dollars <= 0) return;

  const row = await getAccount(userId);
  const current = row?.purchased_credits ?? 0;
  await patchAccount(userId, { purchased_credits: current + dollars * CREDITS_PER_DOLLAR });
}

async function userIdForSubscription(sub: Stripe.Subscription): Promise<string | null> {
  const fromMetadata = sub.metadata?.user_id;
  if (typeof fromMetadata === "string" && fromMetadata.length > 0) return fromMetadata;
  return await userIdForCustomer(customerIdOf(sub.customer));
}

function serviceHeaders(): Record<string, string> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return {
    Authorization: `Bearer ${key}`,
    apikey: key,
    "Content-Type": "application/json",
  };
}

async function getAccount(userId: string): Promise<Record<string, unknown> | null> {
  const res = await fetch(
    `${Deno.env.get("SUPABASE_URL")}/rest/v1/billing_accounts?user_id=eq.${userId}&select=*`,
    { headers: serviceHeaders() },
  );
  if (!res.ok) throw new Error(`billing_accounts read failed: ${await res.text()}`);
  const rows = await res.json();
  return rows[0] ?? null;
}

async function userIdForCustomer(customerId: string | null): Promise<string | null> {
  if (!customerId) return null;
  const res = await fetch(
    `${Deno.env.get("SUPABASE_URL")}/rest/v1/billing_accounts?stripe_customer_id=eq.${customerId}&select=user_id`,
    { headers: serviceHeaders() },
  );
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0]?.user_id ?? null;
}

async function tierForPriceId(priceId: string): Promise<string | null> {
  const res = await fetch(
    `${Deno.env.get("SUPABASE_URL")}/rest/v1/available_plans?stripe_price_id=eq.${priceId}&select=tier`,
    { headers: serviceHeaders() },
  );
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0]?.tier ?? null;
}

async function patchAccount(userId: string, fields: Record<string, unknown>) {
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/billing_accounts`, {
    method: "POST",
    headers: {
      ...serviceHeaders(),
      Prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify({ user_id: userId, updated_at: new Date().toISOString(), ...fields }),
  });
  if (!res.ok) throw new Error(`billing_accounts write failed: ${await res.text()}`);
}
