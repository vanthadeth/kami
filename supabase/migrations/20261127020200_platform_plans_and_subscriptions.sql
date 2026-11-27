-- KAMI platform console, chunk 1 of 3 (part 3): plans and per-business subscriptions.
--
-- Today there is one plan: "Free for 90 days" (free_90). The tables already hold paid plans,
-- a price per user, app add-ons and per-business overrides, so those arrive later as rows.
-- Prices are whole numbers in the smallest currency unit (cents), never decimals.
--
-- Depends on the core business tables, which do not exist yet:
--   * subscriptions.business_id  -> public.businesses (id)   FK added by the core migration
--   * plan_apps.app_key          -> public.apps (key)        FK added with the app registry
-- The core create_business function will also insert the business's subscription.

-- ---------------------------------------------------------------------------
-- Plans
-- ---------------------------------------------------------------------------

create table public.plans (
  id               uuid primary key default gen_random_uuid(),
  key              text not null unique check (key ~ '^[a-z0-9_]+$'),
  name             text not null check (length(btrim(name)) between 1 and 80),
  description      text,
  is_public        boolean not null default false,   -- on the pricing page / chosen at sign-up
  status           text not null default 'active' check (status in ('active', 'archived')),
  trial_days       int check (trial_days >= 0),       -- null = no trial
  billing_interval text not null default 'none' check (billing_interval in ('none', 'month', 'year')),
  currency         char(3) not null default 'USD' check (currency in ('USD', 'KHR')),
  base_price       int not null default 0 check (base_price >= 0),      -- per business, smallest unit
  price_per_user   int not null default 0 check (price_per_user >= 0),  -- per user beyond included_users
  included_users   int check (included_users >= 0),                     -- null = not limited
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table public.plans is 'Plan catalog. Plans are never deleted, only archived.';

create table public.plan_limits (
  plan_id     uuid not null references public.plans (id) on delete restrict,
  limit_key   text not null check (limit_key ~ '^[a-z_]+$'),   -- max_users, max_employees, max_storage_mb
  limit_value int  not null check (limit_value >= 0),
  primary key (plan_id, limit_key)
);

create table public.plan_apps (
  plan_id     uuid not null references public.plans (id) on delete restrict,
  app_key     text not null check (app_key ~ '^[a-z][a-z0-9_]*$'),
  included    boolean not null default true,    -- false = available as a paid add-on
  addon_price int not null default 0 check (addon_price >= 0),
  primary key (plan_id, app_key)
);

-- ---------------------------------------------------------------------------
-- Subscriptions: exactly one per business
-- ---------------------------------------------------------------------------

create type public.subscription_status as enum ('trialing', 'active', 'expired', 'suspended');

create table public.subscriptions (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null unique,     -- FK to public.businesses added by the core migration
  plan_id               uuid not null references public.plans (id),
  status                public.subscription_status not null default 'trialing',
  status_before_suspend public.subscription_status,   -- restored on reactivate
  trial_ends_at         timestamptz,                   -- set from the plan when left empty
  grace_days            int not null check (grace_days between 0 and 365),  -- default from platform_settings
  current_period_end    timestamptz,
  note_for_business     text,                          -- shown to the owner, e.g. when suspended
  internal_note         text,                          -- staff only
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check (status <> 'suspended' or status_before_suspend is not null),
  check (status_before_suspend is distinct from 'suspended')
);
create index subscriptions_status_trial_idx on public.subscriptions (status, trial_ends_at);
create index subscriptions_plan_idx on public.subscriptions (plan_id);

create table public.subscription_overrides (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions (id) on delete cascade,
  kind            text not null check (kind in ('limit', 'app')),
  key             text not null,           -- a limit_key or an app_key
  value           int,                     -- the custom limit; empty for an app
  reason          text not null check (length(btrim(reason)) >= 3),
  expires_at      timestamptz,             -- null = no end date
  created_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  check ((kind = 'limit') = (value is not null)),
  check (value is null or value >= 0)
);
create index subscription_overrides_sub_idx on public.subscription_overrides (subscription_id, kind, key);

-- New subscriptions: trial end = created + the plan's trial days (90 for free_90),
-- grace days from the platform setting (14).
create or replace function private.fill_subscription_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.trial_ends_at is null and new.status = 'trialing' then
    select new.created_at + make_interval(days => p.trial_days)
      into new.trial_ends_at
      from public.plans p where p.id = new.plan_id and p.trial_days is not null;
  end if;
  if new.grace_days is null then
    new.grace_days := coalesce(
      (select (value #>> '{}')::int from public.platform_settings where key = 'default_grace_days'), 14);
  end if;
  return new;
end;
$$;

create trigger subscriptions_defaults
  before insert on public.subscriptions
  for each row execute function private.fill_subscription_defaults();

-- A new subscription cannot start on an archived plan.
create or replace function private.guard_subscription_plan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' or new.plan_id <> old.plan_id)
     and exists (select 1 from public.plans p where p.id = new.plan_id and p.status = 'archived') then
    raise exception 'This plan is archived and cannot be given to a business' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger subscriptions_plan_guard
  before insert or update on public.subscriptions
  for each row execute function private.guard_subscription_plan();

-- Each kind of change needs its own permission (RLS lets any of them in):
--   trial dates or grace days -> trial.extend
--   plan or billing period    -> plan.change
--   suspend or reactivate     -> biz.suspend
-- Direct SQL with no signed-in user (the daily job, the database owner) is not checked here.
create or replace function private.guard_subscription_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;
  if new.business_id <> old.business_id then
    raise exception 'A subscription cannot move to another business' using errcode = 'check_violation';
  end if;
  if (new.trial_ends_at is distinct from old.trial_ends_at or new.grace_days <> old.grace_days)
     and not private.has_platform_permission('trial.extend') then
    raise exception 'Changing trial dates needs the trial.extend permission' using errcode = 'insufficient_privilege';
  end if;
  if (new.plan_id <> old.plan_id or new.current_period_end is distinct from old.current_period_end)
     and not private.has_platform_permission('plan.change') then
    raise exception 'Changing the plan needs the plan.change permission' using errcode = 'insufficient_privilege';
  end if;
  if new.status <> old.status then
    if 'suspended' in (new.status, old.status) then
      if not private.has_platform_permission('biz.suspend') then
        raise exception 'Suspending or reactivating needs the biz.suspend permission' using errcode = 'insufficient_privilege';
      end if;
    elsif new.status = 'trialing' then
      if not private.has_platform_permission('trial.extend') then
        raise exception 'Restarting a trial needs the trial.extend permission' using errcode = 'insufficient_privilege';
      end if;
    elsif not private.has_platform_permission('plan.change') then
      raise exception 'Changing the status needs the plan.change permission' using errcode = 'insufficient_privilege';
    end if;
  end if;
  return new;
end;
$$;

create trigger subscriptions_update_guard
  before update on public.subscriptions
  for each row execute function private.guard_subscription_update();

-- updated_at and the audit log.
create trigger plans_updated_at before update on public.plans
  for each row execute function private.set_updated_at();
create trigger subscriptions_updated_at before update on public.subscriptions
  for each row execute function private.set_updated_at();

create trigger plans_audit after insert or update or delete on public.plans
  for each row execute function private.audit_platform_change();
create trigger plan_limits_audit after insert or update or delete on public.plan_limits
  for each row execute function private.audit_platform_change();
create trigger plan_apps_audit after insert or update or delete on public.plan_apps
  for each row execute function private.audit_platform_change();
create trigger subscriptions_audit after insert or update or delete on public.subscriptions
  for each row execute function private.audit_platform_change();
create trigger subscription_overrides_audit after insert or update or delete on public.subscription_overrides
  for each row execute function private.audit_platform_change();

-- ---------------------------------------------------------------------------
-- Day 90 rule, for business tables to call later
-- ---------------------------------------------------------------------------

-- False when the business may not add, edit or delete data:
--   * suspended, always;
--   * expired, or trial end + grace days passed, but only when enforce_trial_end is on.
-- Reads are never blocked by this (expired = read-only), so it goes only in write policies.
create or replace function private.business_is_writable(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when s.id is null then false
    when s.status = 'suspended' then false
    when not coalesce((select (value #>> '{}')::boolean from public.platform_settings
                       where key = 'enforce_trial_end'), false) then true
    when s.status = 'expired' then false
    when s.status = 'trialing' and s.trial_ends_at is not null
         and now() > s.trial_ends_at + make_interval(days => s.grace_days) then false
    else true
  end
  from (select 1) as one
  left join public.subscriptions s on s.business_id = p_business_id;
$$;

revoke all on function private.fill_subscription_defaults(), private.guard_subscription_plan(),
  private.guard_subscription_update(), private.business_is_writable(uuid) from public;
grant execute on function private.business_is_writable(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Seed: the one plan that exists today
-- ---------------------------------------------------------------------------

select set_config('kami.audit_reason', 'Initial platform setup', true);

insert into public.plans (key, name, description, is_public, trial_days)
values ('free_90', 'Free for 90 days', 'Every app included, free for the first 90 days.', true, 90);

select set_config('kami.audit_reason', '', true);

-- ---------------------------------------------------------------------------
-- Row level security: platform staff only, by permission. Business users get nothing here;
-- the owner's own read-only view of their subscription comes with the core tables.
-- ---------------------------------------------------------------------------

alter table public.plans                  enable row level security;
alter table public.plan_limits            enable row level security;
alter table public.plan_apps              enable row level security;
alter table public.subscriptions          enable row level security;
alter table public.subscription_overrides enable row level security;

revoke all on public.plans, public.plan_limits, public.plan_apps,
  public.subscriptions, public.subscription_overrides from anon, authenticated;
grant select, insert, update on public.plans to authenticated;           -- no delete: archive instead
grant select, insert, update, delete on public.plan_limits, public.plan_apps to authenticated;
grant select, insert, update on public.subscriptions to authenticated;   -- no delete
grant select, insert, update, delete on public.subscription_overrides to authenticated;

-- Plans: any staff member reads; plans.manage changes.
create policy "staff read plans" on public.plans
  for select to authenticated using ((select private.is_platform_staff()));
create policy "plans.manage adds plans" on public.plans
  for insert to authenticated with check ((select private.has_platform_permission('plans.manage')));
create policy "plans.manage edits plans" on public.plans
  for update to authenticated
  using ((select private.has_platform_permission('plans.manage')))
  with check ((select private.has_platform_permission('plans.manage')));

create policy "staff read plan limits" on public.plan_limits
  for select to authenticated using ((select private.is_platform_staff()));
create policy "plans.manage adds plan limits" on public.plan_limits
  for insert to authenticated with check ((select private.has_platform_permission('plans.manage')));
create policy "plans.manage edits plan limits" on public.plan_limits
  for update to authenticated
  using ((select private.has_platform_permission('plans.manage')))
  with check ((select private.has_platform_permission('plans.manage')));
create policy "plans.manage removes plan limits" on public.plan_limits
  for delete to authenticated using ((select private.has_platform_permission('plans.manage')));

create policy "staff read plan apps" on public.plan_apps
  for select to authenticated using ((select private.is_platform_staff()));
create policy "plans.manage adds plan apps" on public.plan_apps
  for insert to authenticated with check ((select private.has_platform_permission('plans.manage')));
create policy "plans.manage edits plan apps" on public.plan_apps
  for update to authenticated
  using ((select private.has_platform_permission('plans.manage')))
  with check ((select private.has_platform_permission('plans.manage')));
create policy "plans.manage removes plan apps" on public.plan_apps
  for delete to authenticated using ((select private.has_platform_permission('plans.manage')));

-- Subscriptions: biz.view reads; biz.create starts one; the update guard checks which permission
-- each change needs.
create policy "biz.view reads subscriptions" on public.subscriptions
  for select to authenticated using ((select private.has_platform_permission('biz.view')));
create policy "biz.create starts subscriptions" on public.subscriptions
  for insert to authenticated with check ((select private.has_platform_permission('biz.create')));
create policy "staff with a subscription permission edit subscriptions" on public.subscriptions
  for update to authenticated
  using ((select private.has_platform_permission('trial.extend'))
      or (select private.has_platform_permission('plan.change'))
      or (select private.has_platform_permission('biz.suspend')))
  with check ((select private.has_platform_permission('trial.extend'))
      or (select private.has_platform_permission('plan.change'))
      or (select private.has_platform_permission('biz.suspend')));

-- Overrides: biz.view reads; plan.change changes.
create policy "biz.view reads overrides" on public.subscription_overrides
  for select to authenticated using ((select private.has_platform_permission('biz.view')));
create policy "plan.change adds overrides" on public.subscription_overrides
  for insert to authenticated with check ((select private.has_platform_permission('plan.change')));
create policy "plan.change edits overrides" on public.subscription_overrides
  for update to authenticated
  using ((select private.has_platform_permission('plan.change')))
  with check ((select private.has_platform_permission('plan.change')));
create policy "plan.change removes overrides" on public.subscription_overrides
  for delete to authenticated using ((select private.has_platform_permission('plan.change')));
