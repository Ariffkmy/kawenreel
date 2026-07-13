-- Stripe billing state. Written only by the stripe-webhook edge function
-- (service role); clients may read their own row.
create table if not exists public.billing_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  stripe_customer_id text unique,
  stripe_subscription_id text,
  tier text not null default 'none' check (tier in ('none', 'pro', 'max')),
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  purchased_credits integer not null default 0,
  spent_credits_this_period integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.billing_accounts enable row level security;

drop policy if exists "billing_accounts_select_own" on public.billing_accounts;
create policy "billing_accounts_select_own" on public.billing_accounts
  for select using (auth.uid() = user_id);

-- Plan catalog shown in the app. Edit prices/budgets here; stripe_price_id is
-- the Price on the matching Stripe product (test vs live mode have different ids).
create table if not exists public.available_plans (
  tier text primary key check (tier in ('pro', 'max')),
  monthly_price_cents integer not null,
  discounted_monthly_price_cents integer,
  currency text not null default 'myr',
  monthly_budget_credits integer not null,
  stripe_price_id text not null unique
);

alter table public.available_plans enable row level security;

drop policy if exists "available_plans_select_authenticated" on public.available_plans;
create policy "available_plans_select_authenticated" on public.available_plans
  for select to authenticated using (true);

insert into public.available_plans (tier, monthly_price_cents, monthly_budget_credits, stripe_price_id)
values
  ('pro', 8990, 1000, 'price_1TseiK2NOktmyAyMomFqP0O5'),
  ('max', 29900, 4000, 'price_1TsejL2NOktmyAyMcZFlHmOv')
on conflict (tier) do nothing;
