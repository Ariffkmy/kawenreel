-- Admin-only read access and reporting views for the affiliate program,
-- consumed by the admin console in the kawenreel-landingpage repo.
--
-- These depend on two objects the landing-page project owns and this repo does
-- not create: public.is_admin() and public.profiles. The whole migration is
-- therefore guarded -- on an environment without them it logs and skips rather
-- than failing the deploy. (The sibling admin_*.sql files in the landing repo
-- are applied by hand in the SQL Editor; this one lives here so it ships with
-- the affiliate schema it describes.)
--
-- Deliberately NOT covered: public.affiliate_bank_details. Raw account numbers
-- stay unreachable from the browser's anon key and are read only by the
-- service-role endpoint api/admin-affiliate-bank.js.

do $$
begin
  if to_regprocedure('public.is_admin()') is null then
    raise notice 'public.is_admin() not found; skipping affiliate admin views';
    return;
  end if;
  if to_regclass('public.profiles') is null then
    raise notice 'public.profiles not found; skipping affiliate admin views';
    return;
  end if;

  -- ------------------------------------------------------- admin policies

  execute $ddl$
    drop policy if exists "affiliate_accounts_select_admin" on public.affiliate_accounts
  $ddl$;
  execute $ddl$
    create policy "affiliate_accounts_select_admin" on public.affiliate_accounts
      for select to authenticated using (public.is_admin())
  $ddl$;

  execute $ddl$
    drop policy if exists "affiliate_commissions_select_admin" on public.affiliate_commissions
  $ddl$;
  execute $ddl$
    create policy "affiliate_commissions_select_admin" on public.affiliate_commissions
      for select to authenticated using (public.is_admin())
  $ddl$;

  execute $ddl$
    drop policy if exists "affiliate_referrals_select_admin" on public.affiliate_referrals
  $ddl$;
  execute $ddl$
    create policy "affiliate_referrals_select_admin" on public.affiliate_referrals
      for select to authenticated using (public.is_admin())
  $ddl$;

  -- ---------------------------------------------------------------- views

  -- Every view is additionally gated on is_admin(). Without that gate a normal
  -- signed-in user would match the app's own "select own row" policies and read
  -- these views for their own data -- exposing the email addresses of the
  -- people they referred.

  -- One row per affiliate, built on affiliate_summary so the money aggregates
  -- keep a single definition shared with the macOS app.
  execute $ddl$
    create or replace view public.affiliate_admin_overview
      with (security_invoker = on) as
      select
        s.user_id,
        p.email,
        p.name,
        s.referral_code,
        s.referral_count,
        s.converted_count,
        s.clearing_cents,
        s.ready_cents,
        s.paid_cents,
        (s.clearing_cents + s.ready_cents) as owed_cents,
        s.bank_name,
        s.bank_account_holder,
        s.bank_account_last4,
        (s.bank_account_last4 is not null) as has_bank_details,
        s.payout_details_updated_at
      from public.affiliate_summary s
      left join public.profiles p on p.id = s.user_id
      where public.is_admin()
  $ddl$;

  execute $ddl$
    create or replace view public.affiliate_commissions_admin
      with (security_invoker = on) as
      select
        c.id,
        c.referrer_user_id,
        rp.email as referrer_email,
        c.referred_user_id,
        dp.email as referred_email,
        c.base_amount_cents,
        c.commission_cents,
        c.commission_rate,
        c.currency,
        c.status,
        c.mature_at,
        (c.status = 'pending' and c.mature_at <= now()) as is_ready,
        c.earned_at,
        c.paid_at,
        c.paid_reference,
        c.reversed_at,
        c.reversed_reason,
        c.stripe_invoice_id
      from public.affiliate_commissions c
      left join public.profiles rp on rp.id = c.referrer_user_id
      left join public.profiles dp on dp.id = c.referred_user_id
      where public.is_admin()
  $ddl$;

  execute $ddl$
    create or replace view public.affiliate_admin_summary
      with (security_invoker = on) as
      select
        count(*) filter (where c.status = 'pending' and c.mature_at <= now())  as ready_count,
        count(*) filter (where c.status = 'pending' and c.mature_at > now())   as clearing_count,
        count(*) filter (where c.status = 'paid')                              as paid_count,
        count(*) filter (where c.status = 'reversed')                          as reversed_count,
        coalesce(sum(c.commission_cents) filter
          (where c.status = 'pending' and c.mature_at <= now()), 0)::integer   as ready_cents,
        coalesce(sum(c.commission_cents) filter
          (where c.status = 'pending' and c.mature_at > now()), 0)::integer    as clearing_cents,
        coalesce(sum(c.commission_cents) filter
          (where c.status = 'paid'), 0)::integer                               as paid_cents
      from public.affiliate_commissions c
      where public.is_admin()
  $ddl$;

  execute 'grant select on public.affiliate_admin_overview to authenticated';
  execute 'grant select on public.affiliate_commissions_admin to authenticated';
  execute 'grant select on public.affiliate_admin_summary to authenticated';

  raise notice 'affiliate admin policies and views installed';
end $$;
