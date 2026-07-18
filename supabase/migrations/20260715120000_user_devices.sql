-- Single-device enforcement: one row per user recording which device is
-- currently "active". Signing in on a new device claims it (last one wins);
-- the app and llm-proxy both gate AI usage on the caller's device matching
-- the active row.
create table if not exists public.user_devices (
  user_id uuid primary key references auth.users (id) on delete cascade,
  device_id text not null check (char_length(device_id) <= 200),
  updated_at timestamptz not null default now()
);

alter table public.user_devices enable row level security;

drop policy if exists "user_devices_select_own" on public.user_devices;
create policy "user_devices_select_own" on public.user_devices
  for select using (auth.uid() = user_id);

-- Writes only through this RPC: a device claims the account for itself,
-- unconditionally superseding whatever device was active before.
create or replace function public.claim_device(p_device_id text) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_device_id is null or char_length(p_device_id) = 0 or char_length(p_device_id) > 200 then
    raise exception 'invalid device id';
  end if;
  insert into public.user_devices (user_id, device_id, updated_at)
  values (auth.uid(), p_device_id, now())
  on conflict (user_id) do update set
    device_id = excluded.device_id,
    updated_at = now();
end
$$;

revoke execute on function public.claim_device(text) from public, anon;
grant execute on function public.claim_device(text) to authenticated;
