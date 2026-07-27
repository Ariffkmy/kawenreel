# Affiliate Program — Operations

Referral attribution, commission on a referred user's **first** paid subscription
invoice, and manual bank payouts.

## Terms

| Rule | Value | Where it lives |
|---|---|---|
| Commission rate | 10% of the first paid subscription invoice | `affiliate_program_settings.commission_rate` |
| Scope | First payment only — one commission per referred user, ever | unique index `affiliate_commissions_one_per_referral` |
| Hold period | 30 days, **advisory only** — flags commission as "clearing" | `affiliate_program_settings.hold_days` |
| Payouts | Manual bank transfer by the operator, recorded in the admin console | `mark_affiliate_commissions_paid` |
| Refund / chargeback | Reversed while pending; absorbed once marked paid | `reverse_affiliate_commission` |

Terms are read live by the app, so changing a row in `affiliate_program_settings`
changes both enforcement and the copy shown in Settings → Affiliate. Existing
commissions keep the rate they were earned at (`affiliate_commissions.commission_rate`).

## One-time setup

### 1. Apply the migrations

```bash
supabase db push
```

This creates the schema, generates the payout encryption key in Supabase Vault
(`affiliate_payout_key`, created only if missing), and runs a set of assertions
that fail the push if the permission model, RLS, encryption, or commission math
is wrong.

**Back up the Vault key with your other production secrets.** It is generated
inside the database and never stored in this repository. Losing it makes stored
account numbers undecryptable, and affiliates would have to re-enter them.

### 2. Enable the new Stripe webhook events

The `stripe-webhook` function now needs these in addition to what it already
subscribed to:

- `invoice.paid` — already enabled; now also awards commission when
  `billing_reason` is `subscription_create`
- `charge.refunded` — reverses commission
- `charge.dispute.created` — reverses commission

```bash
supabase functions deploy stripe-webhook --no-verify-jwt
```

### 3. Point the website at the app

The referral link is `https://kawenreel.com/?ref=<CODE>`. The landing page should
carry `ref` through the download and hand it to the app as
`kawenreel://refer?code=<CODE>`, which the app parks until the user signs in.
Users can also type a code into Settings → Affiliate directly, so attribution
still works if the web hand-off is not in place.

## Attribution rules

Enforced in `claim_referral`:

- One referrer per user, permanently — the first claim wins.
- Self-referral is rejected.
- A code cannot be applied once the user is already on a paid tier, so nobody can
  retro-attribute an existing subscriber.

## Paying affiliates

Affiliates cannot request payouts. They see what they have earned in the app;
you decide when to pay and record it afterwards.

The whole flow lives in the admin console (**kawenreel-landingpage** repo,
`/admin/affiliates`):

1. The table lists each affiliate with **Ready to pay**, **Clearing**, and **Paid**.
2. **Pay out** reveals that one affiliate's bank name, holder, and full account
   number, decrypted server-side for that request only.
3. Transfer the money from your bank.
4. Enter the bank reference and **Mark as paid**.

Marking paid settles only the matured (`ready`) commissions, so the amount shown
for transfer always equals the amount recorded. Only `pending` rows move, so a
double click cannot pay twice and a reversed commission can never become paid.

"Clearing" means the commission is still inside the refund window. Nothing stops
you paying early — the flag only tells you the money could still be refunded.

Setting this up requires running `supabase/admin_affiliates.sql` from the
landing-page repo once in the Supabase SQL Editor (same as the other
`admin_*.sql` files); it adds the admin-only policies and reporting views.

The console reads bank numbers through `api/admin-affiliate-bank.js` and settles
through `api/admin-affiliate-mark-paid.js`. Both run with the service-role key
and re-check the caller against the `admins` table. Raw account numbers are never
exposed to the browser's anon key.

## Granting privileges in this schema

Supabase runs `alter default privileges in schema public grant execute on
functions to anon, authenticated, service_role`. Every function created in
`public` therefore gets **explicit** grants to those roles, and
`revoke ... from public` does not remove them — it only drops the implicit
PUBLIC grant.

Any new affiliate function must be revoked from `public, anon, authenticated`
and then granted back only to the roles that need it. The assertions in
`20260727150000_affiliate_assertions.sql` enforce this at deploy time; a
migration that reopens one of these will fail the push.

## Handling bank details

- The raw account number is stored **only** in `affiliate_bank_details`, encrypted,
  with RLS enabled and no policies — no client role can read or write it.
- The app only ever receives the last four digits, mirrored onto
  `affiliate_accounts.bank_account_last4`.
- Account numbers and holder names are never logged.

Because you hold this data, the KYC, tax-reporting, and data-protection obligations
for affiliate payouts are yours. If that becomes burdensome, Stripe Connect Express
would move bank collection, verification, and payouts to Stripe; the commission
ledger here would not need to change, only the payout mechanism.

## Fraud notes

- One commission per referred user, and a reversed commission is never replaced,
  so subscribe → refund → resubscribe cannot be farmed.
- The 30-day hold covers the normal refund window before money leaves.
- A commission already paid out is absorbed on refund, not clawed back. Watch
  `affiliate commission already paid out, absorbing …` in the webhook logs; a
  pattern there means someone is gaming the hold window.
