-- Affiliate program: referral attribution, 10% commission on a referred user's
-- first paid subscription invoice, and manual bank payouts.
--
-- Ownership:
--   * Commissions are written only by the stripe-webhook edge function (service
--     role) through record_affiliate_commission / reverse_affiliate_commission.
--   * Clients never write these tables directly; every client mutation goes
--     through a SECURITY DEFINER RPC that validates the request.
--   * Raw bank account numbers live in affiliate_bank_details, encrypted, with
--     no RLS policy at all — unreachable via PostgREST. Clients only ever see
--     the last four digits mirrored onto affiliate_accounts.
--
-- One-time operator setup (required before payout details can be saved):
--   select vault.create_secret('<32+ random chars>', 'affiliate_payout_key',
--                              'Encrypts affiliate bank account numbers');

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- settings

-- Single-row program configuration so rates and thresholds can be tuned
-- without a migration. Readable by the app to render accurate terms.
create table if not exists public.affiliate_program_settings (
  id boolean primary key default true check (id),
  commission_rate numeric(5, 4) not null default 0.10
    check (commission_rate > 0 and commission_rate <= 1),
  hold_days integer not null default 30 check (hold_days >= 0),
  minimum_payout_cents integer not null default 10000 check (minimum_payout_cents > 0),
  payout_currency text not null default 'myr',
  updated_at timestamptz not null default now()
);

insert into public.affiliate_program_settings (id) values (true) on conflict (id) do nothing;

alter table public.affiliate_program_settings enable row level security;

drop policy if exists "affiliate_settings_select_authenticated" on public.affiliate_program_settings;
create policy "affiliate_settings_select_authenticated" on public.affiliate_program_settings
  for select to authenticated using (true);

-- ---------------------------------------------------------------- accounts

create table if not exists public.affiliate_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  referral_code text not null unique,
  bank_name text,
  bank_account_holder text,
  bank_account_last4 text check (bank_account_last4 ~ '^[0-9]{4}$'),
  payout_details_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.affiliate_accounts enable row level security;

-- Read-only for the owner. Creation and payout edits go through RPCs.
drop policy if exists "affiliate_accounts_select_own" on public.affiliate_accounts;
create policy "affiliate_accounts_select_own" on public.affiliate_accounts
  for select using (auth.uid() = user_id);

-- ------------------------------------------------------------ bank details

-- RLS enabled with zero policies: no client role can read or write this table.
-- Only SECURITY DEFINER functions and the service role reach it.
create table if not exists public.affiliate_bank_details (
  user_id uuid primary key references auth.users (id) on delete cascade,
  account_number_encrypted bytea not null,
  updated_at timestamptz not null default now()
);

alter table public.affiliate_bank_details enable row level security;
revoke all on public.affiliate_bank_details from public, anon, authenticated;

-- ----------------------------------------------------------------- payouts

create table if not exists public.affiliate_payouts (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references auth.users (id) on delete cascade,
  -- Zero is reachable only by reversal: a refund can drain a requested payout,
  -- which is then marked failed rather than sent to the bank.
  amount_cents integer not null check (amount_cents >= 0),
  currency text not null,
  status text not null default 'requested'
    check (status in ('requested', 'processing', 'paid', 'failed')),
  bank_reference text,
  failure_reason text,
  requested_at timestamptz not null default now(),
  paid_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists affiliate_payouts_referrer_idx
  on public.affiliate_payouts (referrer_user_id, requested_at desc);

-- At most one payout in flight per affiliate, so a double-tap cannot claim the
-- same commissions twice.
create unique index if not exists affiliate_payouts_one_open_per_user
  on public.affiliate_payouts (referrer_user_id)
  where status in ('requested', 'processing');

alter table public.affiliate_payouts enable row level security;

drop policy if exists "affiliate_payouts_select_own" on public.affiliate_payouts;
create policy "affiliate_payouts_select_own" on public.affiliate_payouts
  for select using (auth.uid() = referrer_user_id);

-- ------------------------------------------------------------- commissions

create table if not exists public.affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references auth.users (id) on delete cascade,
  referred_user_id uuid not null references auth.users (id) on delete cascade,
  stripe_invoice_id text not null unique,
  currency text not null,
  base_amount_cents integer not null check (base_amount_cents >= 0),
  commission_cents integer not null check (commission_cents >= 0),
  commission_rate numeric(5, 4) not null,
  status text not null default 'pending' check (status in ('pending', 'paid', 'reversed')),
  payout_id uuid references public.affiliate_payouts (id) on delete set null,
  mature_at timestamptz not null,
  reversed_reason text,
  reversed_at timestamptz,
  earned_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Commission is first-payment-only: one row per referred user, ever. A reversed
-- commission is not replaced, which also blocks subscribe/refund/resubscribe loops.
create unique index if not exists affiliate_commissions_one_per_referral
  on public.affiliate_commissions (referred_user_id);

create index if not exists affiliate_commissions_referrer_idx
  on public.affiliate_commissions (referrer_user_id, status);

alter table public.affiliate_commissions enable row level security;

drop policy if exists "affiliate_commissions_select_own" on public.affiliate_commissions;
create policy "affiliate_commissions_select_own" on public.affiliate_commissions
  for select using (auth.uid() = referrer_user_id);

-- --------------------------------------------------------------- referrals

create table if not exists public.affiliate_referrals (
  referred_user_id uuid primary key references auth.users (id) on delete cascade,
  referrer_user_id uuid not null references auth.users (id) on delete cascade,
  referral_code text not null,
  attributed_at timestamptz not null default now(),
  constraint affiliate_referrals_no_self check (referred_user_id <> referrer_user_id)
);

create index if not exists affiliate_referrals_referrer_idx
  on public.affiliate_referrals (referrer_user_id, attributed_at desc);

alter table public.affiliate_referrals enable row level security;

drop policy if exists "affiliate_referrals_select_referrer" on public.affiliate_referrals;
create policy "affiliate_referrals_select_referrer" on public.affiliate_referrals
  for select using (auth.uid() = referrer_user_id or auth.uid() = referred_user_id);

-- --------------------------------------------------------------- functions

-- Crockford-style alphabet: no 0/O/1/I, so a code read aloud or retyped survives.
create or replace function public.generate_referral_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  candidate text;
  i integer;
begin
  loop
    candidate := '';
    for i in 1..8 loop
      candidate := candidate || substr(
        alphabet,
        1 + (get_byte(extensions.gen_random_bytes(1), 0) % length(alphabet)),
        1
      );
    end loop;
    exit when not exists (
      select 1 from public.affiliate_accounts where referral_code = candidate
    );
  end loop;
  return candidate;
end;
$$;

-- Functions grant EXECUTE to PUBLIC by default, which anon and authenticated
-- inherit. Every internal function must be revoked from PUBLIC, not just from
-- those two roles, or PostgREST exposes it to any caller.
revoke execute on function public.generate_referral_code() from public;

-- Creates the caller's affiliate account on first visit to the Affiliate pane.
-- Idempotent: repeated calls return the existing code.
create or replace function public.ensure_affiliate_account()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_code text;
begin
  if v_user is null then
    raise exception 'Sign in required' using errcode = '28000';
  end if;

  select referral_code into v_code
  from public.affiliate_accounts where user_id = v_user;
  if v_code is not null then
    return v_code;
  end if;

  insert into public.affiliate_accounts (user_id, referral_code)
  values (v_user, public.generate_referral_code())
  on conflict (user_id) do nothing;

  select referral_code into v_code
  from public.affiliate_accounts where user_id = v_user;
  return v_code;
end;
$$;

-- Encryption key for bank account numbers, held in Supabase Vault.
create or replace function public.affiliate_payout_key()
returns text
language sql
security definer
set search_path = ''
as $$
  select decrypted_secret
  from vault.decrypted_secrets
  where name = 'affiliate_payout_key'
  limit 1;
$$;

revoke execute on function public.affiliate_payout_key() from public;

-- Stores payout details. The account number is encrypted into a table the
-- client cannot read; only the last four digits are mirrored back for display.
create or replace function public.set_affiliate_payout_details(
  p_bank_name text,
  p_account_holder text,
  p_account_number text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_bank text := btrim(coalesce(p_bank_name, ''));
  v_holder text := btrim(coalesce(p_account_holder, ''));
  v_number text := regexp_replace(coalesce(p_account_number, ''), '[\s-]', '', 'g');
  v_key text;
begin
  if v_user is null then
    raise exception 'Sign in required' using errcode = '28000';
  end if;

  if length(v_bank) < 2 or length(v_bank) > 80 then
    raise exception 'Bank name must be 2-80 characters' using errcode = '22023';
  end if;
  if length(v_holder) < 2 or length(v_holder) > 120 then
    raise exception 'Account holder name must be 2-120 characters' using errcode = '22023';
  end if;
  if v_number !~ '^[0-9]{6,20}$' then
    raise exception 'Account number must be 6-20 digits' using errcode = '22023';
  end if;

  v_key := public.affiliate_payout_key();
  if v_key is null or length(v_key) = 0 then
    raise exception 'Payout encryption key is not configured' using errcode = '55000';
  end if;

  perform public.ensure_affiliate_account();

  insert into public.affiliate_bank_details (user_id, account_number_encrypted, updated_at)
  values (v_user, extensions.pgp_sym_encrypt(v_number, v_key), now())
  on conflict (user_id) do update
    set account_number_encrypted = excluded.account_number_encrypted,
        updated_at = now();

  update public.affiliate_accounts
     set bank_name = v_bank,
         bank_account_holder = v_holder,
         bank_account_last4 = right(v_number, 4),
         payout_details_updated_at = now(),
         updated_at = now()
   where user_id = v_user;
end;
$$;

-- Attributes the caller to an affiliate. Returns a machine-readable status; the
-- app maps it to copy. Attribution is permanent and must land before the user's
-- first paid invoice, which is the only invoice that earns commission.
create or replace function public.claim_referral(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_referrer uuid;
begin
  if v_user is null then
    raise exception 'Sign in required' using errcode = '28000';
  end if;

  if v_code !~ '^[0-9A-Z]{4,16}$' then
    return 'unknown_code';
  end if;

  if exists (select 1 from public.affiliate_referrals where referred_user_id = v_user) then
    return 'already_referred';
  end if;

  select user_id into v_referrer
  from public.affiliate_accounts where referral_code = v_code;

  if v_referrer is null then
    return 'unknown_code';
  end if;
  if v_referrer = v_user then
    return 'self_referral';
  end if;

  -- Retro-attributing an already-paying user would pay commission on a
  -- conversion the affiliate did not cause.
  if exists (
    select 1 from public.billing_accounts
    where user_id = v_user and tier <> 'none'
  ) then
    return 'ineligible';
  end if;

  insert into public.affiliate_referrals (referred_user_id, referrer_user_id, referral_code)
  values (v_user, v_referrer, v_code)
  on conflict (referred_user_id) do nothing;

  return 'claimed';
end;
$$;

-- Records commission for a referred user's first paid invoice. Called only by
-- the stripe-webhook edge function. Idempotent on stripe_invoice_id so Stripe
-- retries cannot double-pay.
create or replace function public.record_affiliate_commission(
  p_referred_user_id uuid,
  p_stripe_invoice_id text,
  p_amount_cents integer,
  p_currency text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings public.affiliate_program_settings;
  v_referrer uuid;
  v_commission integer;
begin
  if p_referred_user_id is null or coalesce(btrim(p_stripe_invoice_id), '') = '' then
    return 'ignored';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    return 'ignored';
  end if;

  if exists (
    select 1 from public.affiliate_commissions where stripe_invoice_id = p_stripe_invoice_id
  ) then
    return 'duplicate';
  end if;

  select referrer_user_id into v_referrer
  from public.affiliate_referrals where referred_user_id = p_referred_user_id;
  if v_referrer is null then
    return 'no_referral';
  end if;

  -- First payment only: a referral earns at most one commission, ever.
  if exists (
    select 1 from public.affiliate_commissions where referred_user_id = p_referred_user_id
  ) then
    return 'duplicate';
  end if;

  select * into v_settings from public.affiliate_program_settings where id;
  v_commission := round(p_amount_cents * v_settings.commission_rate);
  if v_commission <= 0 then
    return 'ignored';
  end if;

  insert into public.affiliate_commissions (
    referrer_user_id, referred_user_id, stripe_invoice_id, currency,
    base_amount_cents, commission_cents, commission_rate, mature_at
  )
  values (
    v_referrer, p_referred_user_id, p_stripe_invoice_id, lower(p_currency),
    p_amount_cents, v_commission, v_settings.commission_rate,
    now() + make_interval(days => v_settings.hold_days)
  )
  on conflict (stripe_invoice_id) do nothing;

  return 'recorded';
end;
$$;

-- Refund / chargeback handling: reverse while the money is still with us,
-- absorb once it has been paid out. Called only by the stripe-webhook function.
create or replace function public.reverse_affiliate_commission(
  p_stripe_invoice_id text,
  p_reason text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_commission public.affiliate_commissions;
  v_payout public.affiliate_payouts;
begin
  select * into v_commission
  from public.affiliate_commissions
  where stripe_invoice_id = p_stripe_invoice_id
  for update;

  if v_commission.id is null then
    return 'not_found';
  end if;
  if v_commission.status = 'reversed' then
    return 'already_reversed';
  end if;
  if v_commission.status = 'paid' then
    return 'absorbed';
  end if;

  if v_commission.payout_id is not null then
    select * into v_payout
    from public.affiliate_payouts where id = v_commission.payout_id for update;

    -- Already handed to the bank: too late to pull back.
    if v_payout.status in ('processing', 'paid') then
      return 'absorbed';
    end if;

    update public.affiliate_payouts
       set amount_cents = greatest(amount_cents - v_commission.commission_cents, 0),
           status = case
             when amount_cents - v_commission.commission_cents <= 0 then 'failed'
             else status
           end,
           failure_reason = case
             when amount_cents - v_commission.commission_cents <= 0
               then 'All commissions in this payout were reversed'
             else failure_reason
           end,
           updated_at = now()
     where id = v_payout.id;
  end if;

  update public.affiliate_commissions
     set status = 'reversed',
         payout_id = null,
         reversed_reason = p_reason,
         reversed_at = now(),
         updated_at = now()
   where id = v_commission.id;

  return 'reversed';
end;
$$;

-- Commission writers are service-role only: a client that could call these
-- could mint its own earnings.
revoke execute on function public.record_affiliate_commission(uuid, text, integer, text) from public;
revoke execute on function public.reverse_affiliate_commission(text, text) from public;

-- Claims every matured, unpaid commission into one payout request. Refuses
-- below the minimum, without payout details, or while a payout is in flight.
create or replace function public.request_affiliate_payout()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_settings public.affiliate_program_settings;
  v_account public.affiliate_accounts;
  v_row record;
  v_ids uuid[] := array[]::uuid[];
  v_total integer := 0;
  v_payout_id uuid;
begin
  if v_user is null then
    raise exception 'Sign in required' using errcode = '28000';
  end if;

  select * into v_settings from public.affiliate_program_settings where id;

  select * into v_account from public.affiliate_accounts where user_id = v_user;
  if v_account.user_id is null
     or v_account.bank_account_last4 is null
     or coalesce(btrim(v_account.bank_name), '') = ''
     or coalesce(btrim(v_account.bank_account_holder), '') = '' then
    raise exception 'Add your bank details before requesting a payout'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.affiliate_payouts
    where referrer_user_id = v_user and status in ('requested', 'processing')
  ) then
    raise exception 'A payout is already in progress' using errcode = '55006';
  end if;

  -- Lock the claimable rows so a concurrent request cannot take them too.
  for v_row in
    select id, commission_cents
    from public.affiliate_commissions
    where referrer_user_id = v_user
      and status = 'pending'
      and payout_id is null
      and mature_at <= now()
      and currency = v_settings.payout_currency
    order by earned_at
    for update
  loop
    v_ids := array_append(v_ids, v_row.id);
    v_total := v_total + v_row.commission_cents;
  end loop;

  if v_total < v_settings.minimum_payout_cents then
    raise exception 'Minimum payout is % cents; available balance is % cents',
      v_settings.minimum_payout_cents, v_total using errcode = '22023';
  end if;

  insert into public.affiliate_payouts (referrer_user_id, amount_cents, currency)
  values (v_user, v_total, v_settings.payout_currency)
  returning id into v_payout_id;

  update public.affiliate_commissions
     set payout_id = v_payout_id, updated_at = now()
   where id = any(v_ids);

  return v_payout_id;
end;
$$;

-- Operator actions, service role only. Marking paid settles the commissions
-- that were claimed by the payout; failing it releases them back to available.
create or replace function public.mark_affiliate_payout_paid(
  p_payout_id uuid,
  p_bank_reference text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.affiliate_payouts
     set status = 'paid',
         bank_reference = p_bank_reference,
         paid_at = now(),
         updated_at = now()
   where id = p_payout_id and status in ('requested', 'processing');

  if not found then
    raise exception 'Payout % is not open', p_payout_id using errcode = '22023';
  end if;

  update public.affiliate_commissions
     set status = 'paid', updated_at = now()
   where payout_id = p_payout_id and status = 'pending';
end;
$$;

create or replace function public.fail_affiliate_payout(
  p_payout_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.affiliate_payouts
     set status = 'failed', failure_reason = p_reason, updated_at = now()
   where id = p_payout_id and status in ('requested', 'processing');

  if not found then
    raise exception 'Payout % is not open', p_payout_id using errcode = '22023';
  end if;

  update public.affiliate_commissions
     set payout_id = null, updated_at = now()
   where payout_id = p_payout_id and status = 'pending';
end;
$$;

revoke execute on function public.mark_affiliate_payout_paid(uuid, text) from public;
revoke execute on function public.fail_affiliate_payout(uuid, text) from public;

-- Client-callable surface, granted explicitly after the blanket revokes above.
revoke execute on function public.ensure_affiliate_account() from public;
revoke execute on function public.set_affiliate_payout_details(text, text, text) from public;
revoke execute on function public.claim_referral(text) from public;
revoke execute on function public.request_affiliate_payout() from public;

grant execute on function public.ensure_affiliate_account() to authenticated;
grant execute on function public.set_affiliate_payout_details(text, text, text) to authenticated;
grant execute on function public.claim_referral(text) to authenticated;
grant execute on function public.request_affiliate_payout() to authenticated;

-- Revoking from PUBLIC also strips service_role, which inherited through it.
-- The webhook and the payout export need these back explicitly.
grant execute on function public.record_affiliate_commission(uuid, text, integer, text) to service_role;
grant execute on function public.reverse_affiliate_commission(text, text) to service_role;
grant execute on function public.mark_affiliate_payout_paid(uuid, text) to service_role;
grant execute on function public.fail_affiliate_payout(uuid, text) to service_role;
grant select on public.affiliate_bank_details to service_role;

-- ------------------------------------------------------------------- views

-- Everything the Affiliate settings pane renders, in one read. security_invoker
-- keeps each underlying table's RLS in force, so a caller sees only their row.
create or replace view public.affiliate_summary
with (security_invoker = on) as
select
  a.user_id,
  a.referral_code,
  a.bank_name,
  a.bank_account_holder,
  a.bank_account_last4,
  a.payout_details_updated_at,
  (
    select count(*)::integer from public.affiliate_referrals r
    where r.referrer_user_id = a.user_id
  ) as referral_count,
  (
    select coalesce(sum(c.commission_cents), 0)::integer
    from public.affiliate_commissions c
    where c.referrer_user_id = a.user_id and c.status = 'pending' and c.mature_at > now()
  ) as pending_cents,
  (
    select coalesce(sum(c.commission_cents), 0)::integer
    from public.affiliate_commissions c
    where c.referrer_user_id = a.user_id and c.status = 'pending'
      and c.mature_at <= now() and c.payout_id is null
  ) as available_cents,
  (
    select coalesce(sum(c.commission_cents), 0)::integer
    from public.affiliate_commissions c
    where c.referrer_user_id = a.user_id and c.status = 'pending' and c.payout_id is not null
  ) as processing_cents,
  (
    select coalesce(sum(c.commission_cents), 0)::integer
    from public.affiliate_commissions c
    where c.referrer_user_id = a.user_id and c.status = 'paid'
  ) as paid_cents,
  (
    select count(*)::integer from public.affiliate_commissions c
    where c.referrer_user_id = a.user_id and c.status <> 'reversed'
  ) as converted_count
from public.affiliate_accounts a;

grant select on public.affiliate_summary to authenticated;

-- Operator export: approved payout requests joined to the decrypted bank
-- details, for entering into the bank portal. Service role only.
create or replace view public.affiliate_payout_queue as
select
  p.id as payout_id,
  p.referrer_user_id,
  u.email,
  p.amount_cents,
  p.currency,
  p.status,
  p.requested_at,
  a.bank_name,
  a.bank_account_holder,
  extensions.pgp_sym_decrypt(b.account_number_encrypted, public.affiliate_payout_key())
    as bank_account_number
from public.affiliate_payouts p
join public.affiliate_accounts a on a.user_id = p.referrer_user_id
join public.affiliate_bank_details b on b.user_id = p.referrer_user_id
left join auth.users u on u.id = p.referrer_user_id
where p.status in ('requested', 'processing');

-- This view decrypts bank account numbers and, like any view, runs with its
-- owner's rights. It must never be reachable by a client role.
revoke all on public.affiliate_payout_queue from public, anon, authenticated;
grant select on public.affiliate_payout_queue to service_role;
