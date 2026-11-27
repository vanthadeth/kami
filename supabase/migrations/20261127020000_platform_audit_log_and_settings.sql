-- KAMI platform console, chunk 1 of 3: shared helpers, the platform audit log, and platform settings.
--
-- Every platform change must carry a reason. Callers (later: the platform_ functions,
-- the daily job) set it for the current transaction with
--     select set_config('kami.audit_reason', '<why>', true);
-- and the audit trigger refuses any change without one. So a plain table write through
-- the API (which cannot set it) is always refused, even when RLS would allow it.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;  -- RLS policies call helpers here
comment on schema private is 'Internal helpers. Not exposed through the Data API.';

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- The reason given for the current transaction, or null when missing or blank.
create or replace function private.audit_reason()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(btrim(coalesce(current_setting('kami.audit_reason', true), '')), '');
$$;

-- ---------------------------------------------------------------------------
-- Platform audit log: append-only, every row has a reason
-- ---------------------------------------------------------------------------

create table public.platform_audit_log (
  id                  bigint generated always as identity primary key,
  created_at          timestamptz not null default now(),
  actor_user_id       uuid,          -- the staff member; null = automatic (daily job, setup)
  business_id         uuid,          -- the business it concerns, if any (FK added with the core tables)
  action              text not null check (action ~ '^[a-z_]+(\.[a-z_]+)*$'),
  target_table        text,
  target_id           text,
  old_value           jsonb,
  new_value           jsonb,
  reason              text not null check (length(btrim(reason)) >= 3),
  visible_to_business boolean not null default false
);
comment on table public.platform_audit_log is
  'Platform log: every staff and automatic change. Append-only: rows can never be edited or deleted.';

create index platform_audit_log_created_idx  on public.platform_audit_log (created_at desc);
create index platform_audit_log_business_idx on public.platform_audit_log (business_id, created_at desc);
create index platform_audit_log_actor_idx    on public.platform_audit_log (actor_user_id, created_at desc);

create or replace function private.forbid_audit_log_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'The platform log is append-only: % is not allowed', lower(tg_op)
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger platform_audit_log_no_update
  before update or delete on public.platform_audit_log
  for each row execute function private.forbid_audit_log_change();
create trigger platform_audit_log_no_truncate
  before truncate on public.platform_audit_log
  for each statement execute function private.forbid_audit_log_change();

-- Writes one log row for every insert, update or delete on a platform table.
-- Refuses the change when no reason was given for the transaction.
create or replace function private.audit_platform_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason   text := private.audit_reason();
  v_old      jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new      jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row      jsonb := coalesce(v_new, v_old);
  v_business uuid;
begin
  if v_reason is null or length(v_reason) < 3 then
    raise exception 'A reason is required for every platform change'
      using errcode = 'check_violation',
            hint = 'Set it first with set_config(''kami.audit_reason'', ''...'', true).';
  end if;

  if tg_op = 'UPDATE' and v_old = v_new then
    return null;  -- nothing changed, nothing to log
  end if;

  v_business := (v_row ->> 'business_id')::uuid;
  if v_business is null and v_row ? 'subscription_id' then
    select s.business_id into v_business
    from public.subscriptions s
    where s.id = (v_row ->> 'subscription_id')::uuid;
  end if;

  insert into public.platform_audit_log
    (actor_user_id, business_id, action, target_table, target_id, old_value, new_value, reason)
  values
    ((select auth.uid()), v_business, tg_table_name || '.' || lower(tg_op), tg_table_name,
     coalesce(v_row ->> 'id', v_row ->> 'key', v_row ->> 'user_id', v_row ->> 'plan_id', v_row ->> 'role_id'),
     v_old, v_new, v_reason);
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Platform settings: global switches
-- ---------------------------------------------------------------------------

create table public.platform_settings (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]*$'),
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now()
);
comment on table public.platform_settings is 'Global platform switches, changed only by staff with settings.manage.';

create trigger platform_settings_updated_at
  before update on public.platform_settings
  for each row execute function private.set_updated_at();
create trigger platform_settings_audit
  after insert or update or delete on public.platform_settings
  for each row execute function private.audit_platform_change();

-- Seed values. The seed itself is logged, so it needs a reason too.
select set_config('kami.audit_reason', 'Initial platform setup', true);

insert into public.platform_settings (key, value, description) values
  ('enforce_trial_end',  'false'::jsonb,
   'When true, a business turns read-only once its trial end date plus grace days has passed. Off until paid plans exist.'),
  ('default_grace_days', '14'::jsonb,
   'Days between the trial end date and read-only mode for new subscriptions.');

select set_config('kami.audit_reason', '', true);

-- ---------------------------------------------------------------------------
-- RLS on; policies are added in the next migration, once staff and permissions exist.
-- ---------------------------------------------------------------------------

alter table public.platform_audit_log enable row level security;
alter table public.platform_settings  enable row level security;

revoke all on public.platform_audit_log, public.platform_settings from anon, authenticated;
