-- Harden the affiliate payout encryption against pgcrypto's install location.
--
-- The previous migration assumed pgcrypto lives in `extensions` and called
-- `extensions.pgp_sym_encrypt(...)` directly. `create extension if not exists`
-- is a no-op when the extension already exists in a different schema, so that
-- assumption is not guaranteed. Here the schema is discovered from the catalog
-- and pinned into each consumer, so encryption works wherever pgcrypto lives.

do $$
declare
  v_schema text;
begin
  select n.nspname into v_schema
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  if v_schema is null then
    raise exception 'pgcrypto is not installed; affiliate payout encryption cannot work';
  end if;

  raise notice 'pgcrypto is installed in schema: %', v_schema;

  -- pgcrypto calls are unqualified below; search_path is pinned to exactly the
  -- schema holding it. Everything else in these bodies is already fully
  -- qualified, so nothing else resolves through the path.
  execute format(
    'alter function public.generate_referral_code() set search_path = %I', v_schema
  );
  execute format(
    'alter function public.set_affiliate_payout_details(text, text, text) set search_path = %I',
    v_schema
  );

  -- A view has no search_path of its own, so the decrypt call is qualified.
  execute format($view$
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
      %I.pgp_sym_decrypt(b.account_number_encrypted, public.affiliate_payout_key())
        as bank_account_number
    from public.affiliate_payouts p
    join public.affiliate_accounts a on a.user_id = p.referrer_user_id
    join public.affiliate_bank_details b on b.user_id = p.referrer_user_id
    left join auth.users u on u.id = p.referrer_user_id
    where p.status in ('requested', 'processing')
  $view$, v_schema);
end $$;

-- Recreated with unqualified pgcrypto calls; the DO block above pins the
-- search_path that resolves them.
create or replace function public.generate_referral_code()
returns text
language plpgsql
security definer
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
        1 + (pg_catalog.get_byte(gen_random_bytes(1), 0) % pg_catalog.length(alphabet)),
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

create or replace function public.set_affiliate_payout_details(
  p_bank_name text,
  p_account_holder text,
  p_account_number text
)
returns void
language plpgsql
security definer
as $$
declare
  v_user uuid := auth.uid();
  v_bank text := pg_catalog.btrim(pg_catalog.coalesce(p_bank_name, ''));
  v_holder text := pg_catalog.btrim(pg_catalog.coalesce(p_account_holder, ''));
  v_number text := pg_catalog.regexp_replace(
    pg_catalog.coalesce(p_account_number, ''), '[\s-]', '', 'g'
  );
  v_key text;
begin
  if v_user is null then
    raise exception 'Sign in required' using errcode = '28000';
  end if;

  if pg_catalog.length(v_bank) < 2 or pg_catalog.length(v_bank) > 80 then
    raise exception 'Bank name must be 2-80 characters' using errcode = '22023';
  end if;
  if pg_catalog.length(v_holder) < 2 or pg_catalog.length(v_holder) > 120 then
    raise exception 'Account holder name must be 2-120 characters' using errcode = '22023';
  end if;
  if v_number !~ '^[0-9]{6,20}$' then
    raise exception 'Account number must be 6-20 digits' using errcode = '22023';
  end if;

  v_key := public.affiliate_payout_key();
  if v_key is null or pg_catalog.length(v_key) = 0 then
    raise exception 'Payout encryption key is not configured' using errcode = '55000';
  end if;

  perform public.ensure_affiliate_account();

  insert into public.affiliate_bank_details (user_id, account_number_encrypted, updated_at)
  values (v_user, pgp_sym_encrypt(v_number, v_key), pg_catalog.now())
  on conflict (user_id) do update
    set account_number_encrypted = excluded.account_number_encrypted,
        updated_at = pg_catalog.now();

  update public.affiliate_accounts
     set bank_name = v_bank,
         bank_account_holder = v_holder,
         bank_account_last4 = pg_catalog.right(v_number, 4),
         payout_details_updated_at = pg_catalog.now(),
         updated_at = pg_catalog.now()
   where user_id = v_user;
end;
$$;

-- `create or replace function` resets the pinned search_path, so re-pin after
-- the definitions above.
do $$
declare
  v_schema text;
begin
  select n.nspname into v_schema
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  execute format(
    'alter function public.generate_referral_code() set search_path = %I', v_schema
  );
  execute format(
    'alter function public.set_affiliate_payout_details(text, text, text) set search_path = %I',
    v_schema
  );
end $$;

revoke execute on function public.generate_referral_code() from public;
revoke execute on function public.set_affiliate_payout_details(text, text, text) from public;
grant execute on function public.set_affiliate_payout_details(text, text, text) to authenticated;

revoke all on public.affiliate_payout_queue from public, anon, authenticated;
grant select on public.affiliate_payout_queue to service_role;
