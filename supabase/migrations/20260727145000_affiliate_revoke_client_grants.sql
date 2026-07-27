-- Close a privilege hole on the affiliate internals.
--
-- Supabase ships `alter default privileges in schema public grant execute on
-- functions to anon, authenticated, service_role`, so every function created
-- here received *explicit* grants to those roles. `revoke ... from public` only
-- drops the implicit PUBLIC grant and leaves the explicit ones in place, so the
-- commission writers stayed callable by any signed-in user through PostgREST —
-- enough to mint arbitrary commissions.
--
-- Revoke from the named roles as well as PUBLIC, then re-grant only what each
-- role legitimately needs.

revoke execute on function public.generate_referral_code()
  from public, anon, authenticated;
revoke execute on function public.affiliate_payout_key()
  from public, anon, authenticated;
revoke execute on function public.record_affiliate_commission(uuid, text, integer, text)
  from public, anon, authenticated;
revoke execute on function public.reverse_affiliate_commission(text, text)
  from public, anon, authenticated;
revoke execute on function public.mark_affiliate_payout_paid(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.fail_affiliate_payout(uuid, text)
  from public, anon, authenticated;

-- anon is never allowed to touch the affiliate surface; every entry point
-- requires a signed-in user.
revoke execute on function public.ensure_affiliate_account() from anon;
revoke execute on function public.set_affiliate_payout_details(text, text, text) from anon;
revoke execute on function public.claim_referral(text) from anon;
revoke execute on function public.request_affiliate_payout() from anon;

grant execute on function public.ensure_affiliate_account() to authenticated;
grant execute on function public.set_affiliate_payout_details(text, text, text) to authenticated;
grant execute on function public.claim_referral(text) to authenticated;
grant execute on function public.request_affiliate_payout() to authenticated;

grant execute on function public.record_affiliate_commission(uuid, text, integer, text) to service_role;
grant execute on function public.reverse_affiliate_commission(text, text) to service_role;
grant execute on function public.mark_affiliate_payout_paid(uuid, text) to service_role;
grant execute on function public.fail_affiliate_payout(uuid, text) to service_role;

-- Same explicit-grant problem applies to the tables and the decrypting view.
revoke all on public.affiliate_bank_details from public, anon, authenticated;
revoke all on public.affiliate_payout_queue from public, anon, authenticated;
grant select on public.affiliate_bank_details to service_role;
grant select on public.affiliate_payout_queue to service_role;

-- Client roles read affiliate data only through RLS-protected tables and the
-- security_invoker summary view; nothing here is writable from the app.
revoke insert, update, delete on public.affiliate_accounts from anon, authenticated;
revoke insert, update, delete on public.affiliate_referrals from anon, authenticated;
revoke insert, update, delete on public.affiliate_commissions from anon, authenticated;
revoke insert, update, delete on public.affiliate_payouts from anon, authenticated;
revoke insert, update, delete on public.affiliate_program_settings from anon, authenticated;
revoke all on public.affiliate_accounts from anon;
revoke all on public.affiliate_referrals from anon;
revoke all on public.affiliate_commissions from anon;
revoke all on public.affiliate_payouts from anon;
