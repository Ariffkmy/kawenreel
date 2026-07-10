-- Aggregated token usage for the admin dashboard: one row per user, day,
-- provider, and model. Clients batch locally and report deltas through the
-- RPC below — never per-request inserts.
create table if not exists public.token_usage_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null default (now() at time zone 'utc')::date,
  provider text not null check (char_length(provider) <= 40),
  model text not null check (char_length(model) <= 120),
  requests integer not null default 0,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  cache_read_tokens bigint not null default 0,
  cache_write_tokens bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, day, provider, model)
);

alter table public.token_usage_daily enable row level security;

drop policy if exists "token_usage_select_own" on public.token_usage_daily;
create policy "token_usage_select_own" on public.token_usage_daily
  for select using (auth.uid() = user_id);

-- Writes only through this RPC: callers may increment their own row only.
create or replace function public.report_token_usage(
  p_provider text,
  p_model text,
  p_requests integer,
  p_input bigint,
  p_output bigint,
  p_cache_read bigint,
  p_cache_write bigint
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_requests < 0 or p_requests > 100000
     or p_input < 0 or p_output < 0 or p_cache_read < 0 or p_cache_write < 0
     or greatest(p_input, p_output, p_cache_read, p_cache_write) > 10000000000 then
    raise exception 'invalid usage delta';
  end if;
  insert into public.token_usage_daily (
    user_id, day, provider, model,
    requests, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
  ) values (
    auth.uid(), (now() at time zone 'utc')::date, p_provider, p_model,
    p_requests, p_input, p_output, p_cache_read, p_cache_write
  )
  on conflict (user_id, day, provider, model) do update set
    requests = token_usage_daily.requests + excluded.requests,
    input_tokens = token_usage_daily.input_tokens + excluded.input_tokens,
    output_tokens = token_usage_daily.output_tokens + excluded.output_tokens,
    cache_read_tokens = token_usage_daily.cache_read_tokens + excluded.cache_read_tokens,
    cache_write_tokens = token_usage_daily.cache_write_tokens + excluded.cache_write_tokens,
    updated_at = now();
end
$$;

revoke execute on function public.report_token_usage(text, text, integer, bigint, bigint, bigint, bigint) from public, anon;
grant execute on function public.report_token_usage(text, text, integer, bigint, bigint, bigint, bigint) to authenticated;
