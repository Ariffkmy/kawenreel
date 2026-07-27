-- Standing guard on the affiliate program's security posture.
--
-- These are assertions, not changes: the migration fails loudly if a client
-- role can reach commission writers or raw bank details. Because it re-runs on
-- every fresh environment, a future migration that loosens a grant is caught
-- at deploy time rather than in production.

do $$
declare
  v_encrypted bytea;
  v_key text;
  v_round integer;
begin
  -- 1. Commission writers must be unreachable by client roles. A client that
  --    could call these could mint its own earnings.
  if has_function_privilege('authenticated',
       'public.record_affiliate_commission(uuid, text, integer, text)', 'EXECUTE')
     or has_function_privilege('anon',
       'public.record_affiliate_commission(uuid, text, integer, text)', 'EXECUTE') then
    raise exception 'SECURITY: record_affiliate_commission is callable by a client role';
  end if;

  if has_function_privilege('authenticated',
       'public.reverse_affiliate_commission(text, text)', 'EXECUTE') then
    raise exception 'SECURITY: reverse_affiliate_commission is callable by authenticated';
  end if;

  -- 2. Payout settlement is an operator action only.
  if has_function_privilege('authenticated',
       'public.mark_affiliate_payout_paid(uuid, text)', 'EXECUTE')
     or has_function_privilege('authenticated',
       'public.fail_affiliate_payout(uuid, text)', 'EXECUTE') then
    raise exception 'SECURITY: payout settlement is callable by authenticated';
  end if;

  -- 3. The encryption key must never be readable through PostgREST.
  if has_function_privilege('authenticated', 'public.affiliate_payout_key()', 'EXECUTE')
     or has_function_privilege('anon', 'public.affiliate_payout_key()', 'EXECUTE') then
    raise exception 'SECURITY: affiliate_payout_key is callable by a client role';
  end if;

  -- 4. Raw bank details and the decrypting export view are service-role only.
  if has_table_privilege('authenticated', 'public.affiliate_bank_details', 'SELECT')
     or has_table_privilege('anon', 'public.affiliate_bank_details', 'SELECT') then
    raise exception 'SECURITY: affiliate_bank_details is readable by a client role';
  end if;

  if has_table_privilege('authenticated', 'public.affiliate_payout_queue', 'SELECT')
     or has_table_privilege('anon', 'public.affiliate_payout_queue', 'SELECT') then
    raise exception 'SECURITY: affiliate_payout_queue is readable by a client role';
  end if;

  -- 5. The app's own surface must still work.
  if not has_function_privilege('authenticated', 'public.ensure_affiliate_account()', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.claim_referral(text)', 'EXECUTE')
     or not has_function_privilege('authenticated',
       'public.set_affiliate_payout_details(text, text, text)', 'EXECUTE')
     or not has_function_privilege('authenticated',
       'public.request_affiliate_payout()', 'EXECUTE') then
    raise exception 'The app cannot call its own affiliate RPCs';
  end if;

  -- 6. The webhook and payout export must still work.
  if not has_function_privilege('service_role',
       'public.record_affiliate_commission(uuid, text, integer, text)', 'EXECUTE')
     or not has_function_privilege('service_role',
       'public.reverse_affiliate_commission(text, text)', 'EXECUTE')
     or not has_table_privilege('service_role', 'public.affiliate_payout_queue', 'SELECT') then
    raise exception 'The webhook or payout export lost access it needs';
  end if;

  -- 7. No client role may write the ledger directly through PostgREST. RLS
  --    already denies this (there are no write policies), but the privilege
  --    must be gone too so a future policy cannot accidentally open it.
  if has_table_privilege('authenticated', 'public.affiliate_commissions', 'INSERT')
     or has_table_privilege('authenticated', 'public.affiliate_commissions', 'UPDATE')
     or has_table_privilege('authenticated', 'public.affiliate_referrals', 'INSERT')
     or has_table_privilege('authenticated', 'public.affiliate_payouts', 'INSERT')
     or has_table_privilege('authenticated', 'public.affiliate_accounts', 'UPDATE')
     or has_table_privilege('authenticated', 'public.affiliate_program_settings', 'UPDATE') then
    raise exception 'SECURITY: a client role can write affiliate data directly';
  end if;

  -- 8. RLS must be on for every affiliate table.
  if exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname like 'affiliate_%'
      and c.relkind = 'r'
      and not c.relrowsecurity
  ) then
    raise exception 'SECURITY: an affiliate table has RLS disabled';
  end if;

  -- 9. Encryption round-trips with the Vault key, so saving payout details
  --    will not fail at runtime.
  v_key := public.affiliate_payout_key();
  if v_key is null or length(v_key) = 0 then
    raise exception 'affiliate_payout_key is missing; payout details cannot be saved';
  end if;
  v_encrypted := extensions.pgp_sym_encrypt('1234567890', v_key);
  if extensions.pgp_sym_decrypt(v_encrypted, v_key) <> '1234567890' then
    raise exception 'Payout encryption does not round-trip';
  end if;

  -- 10. Commission math: 10% of a RM89.90 Pro invoice is RM8.99.
  select round(8990 * commission_rate)::integer into v_round
  from public.affiliate_program_settings where id;
  if v_round <> 899 then
    raise exception 'Commission math is wrong: expected 899, got %', v_round;
  end if;

  raise notice 'affiliate assertions passed: permissions, RLS, encryption, commission math';
end $$;
