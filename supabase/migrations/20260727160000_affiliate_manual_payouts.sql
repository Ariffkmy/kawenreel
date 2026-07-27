-- Switch affiliate payouts to a fully manual, admin-driven process.
--
-- Affiliates no longer request payouts in the app. The webhook still records
-- and reverses commissions -- that is the data the operator reviews -- but
-- deciding who gets paid, and recording that it happened, now belongs to the
-- admin console. The 30-day hold becomes advisory: a commission inside the
-- refund window is flagged as "clearing" rather than blocked.
--
-- Removes: request_affiliate_payout, the affiliate_payouts state machine, the
-- payout queue view, and the minimum payout threshold.

-- ------------------------------------------------------- drop payout flow

drop function if exists public.request_affiliate_payout();
drop function if exists public.mark_affiliate_payout_paid(uuid, text);
drop function if exists public.fail_affiliate_payout(uuid, text);
drop view if exists public.affiliate_payout_queue;

-- affiliate_summary reads payout_id, and its column list changes below, so it
-- is dropped rather than replaced.
drop view if exists public.affiliate_summary;

alter table public.affiliate_commissions drop column if exists payout_id;
drop table if exists public.affiliate_payouts;

-- Settlement is now recorded on the commission itself.
alter table public.affiliate_commissions
  add column if not exists paid_at timestamptz,
  add column if not exists paid_reference text;

-- Nothing enforces a threshold any more; the operator pays what they choose.
alter table public.affiliate_program_settings drop column if exists minimum_payout_cents;

-- --------------------------------------------------- reversal without payouts

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

  -- Money already sent to the affiliate cannot be pulled back; record and move on.
  if v_commission.status = 'paid' then
    return 'absorbed';
  end if;

  update public.affiliate_commissions
     set status = 'reversed',
         reversed_reason = p_reason,
         reversed_at = now(),
         updated_at = now()
   where id = v_commission.id;

  return 'reversed';
end;
$$;

-- ------------------------------------------------------- settle by hand

-- Marks specific commissions as paid after the operator has transferred the
-- money. Only 'pending' rows move, so a double submit cannot re-pay a
-- settled commission or resurrect a reversed one. Returns the number settled.
create or replace function public.mark_affiliate_commissions_paid(
  p_commission_ids uuid[],
  p_reference text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_commission_ids is null or array_length(p_commission_ids, 1) is null then
    return 0;
  end if;

  update public.affiliate_commissions
     set status = 'paid',
         paid_at = now(),
         paid_reference = nullif(btrim(coalesce(p_reference, '')), ''),
         updated_at = now()
   where id = any(p_commission_ids)
     and status = 'pending';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ------------------------------------------------------------------ views

-- Rebuilt without the payout stage. "clearing" is still inside the refund
-- window, "ready" has matured; both are unpaid and owed.
create view public.affiliate_summary
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
  ) as clearing_cents,
  (
    select coalesce(sum(c.commission_cents), 0)::integer
    from public.affiliate_commissions c
    where c.referrer_user_id = a.user_id and c.status = 'pending' and c.mature_at <= now()
  ) as ready_cents,
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

-- ---------------------------------------------------------------- grants

revoke execute on function public.mark_affiliate_commissions_paid(uuid[], text)
  from public, anon, authenticated;
grant execute on function public.mark_affiliate_commissions_paid(uuid[], text) to service_role;

revoke execute on function public.reverse_affiliate_commission(text, text)
  from public, anon, authenticated;
grant execute on function public.reverse_affiliate_commission(text, text) to service_role;

-- ------------------------------------------------------------ assertions

do $$
declare
  v_round integer;
begin
  if has_function_privilege('authenticated',
       'public.mark_affiliate_commissions_paid(uuid[], text)', 'EXECUTE')
     or has_function_privilege('anon',
       'public.mark_affiliate_commissions_paid(uuid[], text)', 'EXECUTE') then
    raise exception 'SECURITY: settlement is callable by a client role';
  end if;

  if not has_function_privilege('service_role',
       'public.mark_affiliate_commissions_paid(uuid[], text)', 'EXECUTE') then
    raise exception 'The admin console cannot settle commissions';
  end if;

  if to_regclass('public.affiliate_payouts') is not null then
    raise exception 'affiliate_payouts still exists; the payout flow was not removed';
  end if;

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'request_affiliate_payout'
  ) then
    raise exception 'request_affiliate_payout still exists';
  end if;

  select round(8990 * commission_rate)::integer into v_round
  from public.affiliate_program_settings where id;
  if v_round <> 899 then
    raise exception 'Commission math is wrong: expected 899, got %', v_round;
  end if;

  raise notice 'affiliate manual-payout migration verified';
end $$;
