-- Single-affiliate bank detail lookup for the admin console.
--
-- Replaces the dropped affiliate_payout_queue view. A function is a better fit
-- than a view here: it decrypts exactly one affiliate's account number, on an
-- explicit "reveal" action in the console, instead of exposing every account
-- number to anything that can select the view.
--
-- Service role only, called from the landing-page endpoint
-- api/admin-affiliate-bank.js, which checks the caller against the admins table.

create or replace function public.admin_affiliate_bank_details(p_user_id uuid)
returns table (
  bank_name text,
  bank_account_holder text,
  account_number text
)
-- plpgsql, not sql: a `language sql` body is name-resolved at creation time,
-- which would fail on the unqualified pgcrypto call before the ALTER below
-- pins the search_path. plpgsql resolves it at run time instead.
language plpgsql
security definer
as $$
begin
  return query
  select
    a.bank_name,
    a.bank_account_holder,
    pgp_sym_decrypt(b.account_number_encrypted, public.affiliate_payout_key())
  from public.affiliate_accounts a
  join public.affiliate_bank_details b on b.user_id = a.user_id
  where a.user_id = p_user_id;
end;
$$;

-- Pin the search_path to wherever pgcrypto actually lives, matching the
-- approach in 20260727130000. Every other reference above is fully qualified.
do $$
declare
  v_schema text;
begin
  select n.nspname into v_schema
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  if v_schema is null then
    raise exception 'pgcrypto is not installed';
  end if;

  execute format(
    'alter function public.admin_affiliate_bank_details(uuid) set search_path = %I',
    v_schema
  );
end $$;

revoke execute on function public.admin_affiliate_bank_details(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_affiliate_bank_details(uuid) to service_role;

do $$
begin
  if has_function_privilege('authenticated', 'public.admin_affiliate_bank_details(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_affiliate_bank_details(uuid)', 'EXECUTE') then
    raise exception 'SECURITY: bank detail lookup is callable by a client role';
  end if;
  if not has_function_privilege('service_role',
       'public.admin_affiliate_bank_details(uuid)', 'EXECUTE') then
    raise exception 'The admin console cannot read bank details';
  end if;
  raise notice 'admin bank lookup locked to service_role';
end $$;
