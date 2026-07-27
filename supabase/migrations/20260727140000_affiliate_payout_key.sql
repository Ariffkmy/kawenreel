-- Creates the Vault secret that encrypts affiliate bank account numbers.
--
-- The value is generated inside the database, so the key never appears in this
-- repository. Strictly create-if-missing: replacing this key would make every
-- stored account number undecryptable.

do $$
declare
  v_exists boolean;
begin
  if to_regnamespace('vault') is null then
    raise exception
      'Supabase Vault is unavailable; affiliate payout details cannot be encrypted';
  end if;

  select exists (select 1 from vault.secrets where name = 'affiliate_payout_key')
  into v_exists;

  if v_exists then
    raise notice 'affiliate_payout_key already exists; leaving it untouched';
  else
    -- gen_random_uuid() is core Postgres, so this does not depend on where
    -- pgcrypto is installed. Two UUIDs give a 64-character hex key.
    perform vault.create_secret(
      replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      'affiliate_payout_key',
      'Encrypts affiliate bank account numbers'
    );
    raise notice 'created affiliate_payout_key';
  end if;
end $$;
