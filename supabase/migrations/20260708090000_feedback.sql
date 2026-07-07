-- In-app feedback. Write-only from clients (anon or signed-in); read via the
-- Supabase dashboard / service role only.
create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid references auth.users (id) on delete set null,
  email text check (char_length(email) <= 320),
  message text not null check (char_length(message) between 1 and 10000),
  may_contact boolean not null default false,
  app_version text check (char_length(app_version) <= 40),
  os_version text check (char_length(os_version) <= 40),
  screenshot_b64 text check (char_length(screenshot_b64) <= 4000000)
);

alter table public.feedback enable row level security;

drop policy if exists "feedback_insert_any" on public.feedback;
create policy "feedback_insert_any" on public.feedback
  for insert to anon, authenticated
  with check (true);
