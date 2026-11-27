-- KAMI platform console, chunk 1 of 3 (part 2): platform staff, roles and the permission grid.
--
-- Platform staff are KAMI's own team. They are a separate list from business users:
-- nothing here is linked to businesses, memberships or business roles, and business
-- permission checks never look at these tables.
-- Every staff check also requires two-factor authentication: the session must be at
-- Supabase Auth assurance level aal2 (signed in with a verified second factor).

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.platform_permissions (
  key        text primary key check (key ~ '^[a-z]+(\.[a-z_]+)+$'),
  label      text not null,
  group_name text not null,
  sort_order int  not null default 0
);
comment on table public.platform_permissions is 'The rows of the console permission grid.';

create table public.platform_roles (
  id            uuid primary key default gen_random_uuid(),
  key           text not null unique check (key ~ '^[a-z][a-z0-9_]*$'),
  name          text not null check (length(btrim(name)) between 1 and 60),
  description   text,
  is_superadmin boolean not null default false,  -- has every permission, cannot be edited
  is_system     boolean not null default false,  -- seeded role: key and superadmin flag are fixed, cannot be deleted
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index platform_roles_one_superadmin on public.platform_roles ((true)) where is_superadmin;

create table public.platform_role_permissions (
  role_id        uuid not null references public.platform_roles (id) on delete cascade,
  permission_key text not null references public.platform_permissions (key) on update cascade on delete cascade,
  primary key (role_id, permission_key)
);
create index platform_role_permissions_key_idx on public.platform_role_permissions (permission_key);

create type public.platform_staff_status as enum ('invited', 'active', 'disabled');

create table public.platform_staff (
  user_id      uuid primary key references auth.users (id) on delete restrict,  -- remove from staff first
  role_id      uuid not null references public.platform_roles (id),
  status       public.platform_staff_status not null default 'invited',
  display_name text,
  added_by     uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.platform_staff is
  'KAMI team members who can open the platform console. Separate from business users. Two-factor is required.';
create index platform_staff_role_idx on public.platform_staff (role_id);

-- ---------------------------------------------------------------------------
-- Access helpers (used by every platform RLS policy)
-- ---------------------------------------------------------------------------

-- True when the current session signed in with a verified second factor.
create or replace function private.has_two_factor()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select auth.jwt()) ->> 'aal', '') = 'aal2';
$$;

-- True for an active staff member who passed two-factor.
create or replace function private.is_platform_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_two_factor()
     and exists (
       select 1 from public.platform_staff s
       where s.user_id = (select auth.uid()) and s.status = 'active'
     );
$$;

-- True when the current staff member's role grants the permission (superadmin: always).
create or replace function private.has_platform_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_two_factor()
     and exists (
       select 1
       from public.platform_staff s
       join public.platform_roles r on r.id = s.role_id
       where s.user_id = (select auth.uid())
         and s.status = 'active'
         and (r.is_superadmin
              or exists (select 1 from public.platform_role_permissions rp
                         where rp.role_id = r.id and rp.permission_key = p_permission))
     );
$$;

-- True when the current user is an active superadmin (two-factor not checked here;
-- callers combine it with has_platform_permission, which checks it).
create or replace function private.is_platform_superadmin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.platform_staff s
    join public.platform_roles r on r.id = s.role_id
    where s.user_id = (select auth.uid()) and s.status = 'active' and r.is_superadmin
  );
$$;

revoke all on function private.has_two_factor(), private.is_platform_staff(),
  private.has_platform_permission(text), private.is_platform_superadmin(),
  private.audit_reason(), private.set_updated_at(), private.audit_platform_change(),
  private.forbid_audit_log_change()
  from public;
grant execute on function private.has_two_factor(), private.is_platform_staff(),
  private.has_platform_permission(text), private.is_platform_superadmin()
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Guard triggers
-- ---------------------------------------------------------------------------

-- Seeded roles keep their key and superadmin flag and cannot be deleted.
create or replace function private.guard_platform_role()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and old.is_system then
    raise exception 'Built-in role % cannot be deleted', old.key using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' and old.is_system
     and (new.key <> old.key or new.is_superadmin <> old.is_superadmin or not new.is_system) then
    raise exception 'Built-in role % keeps its key and type', old.key using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' and not old.is_system and new.is_superadmin then
    raise exception 'Only the built-in Superadmin role has every permission' using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger platform_roles_guard
  before update or delete on public.platform_roles
  for each row execute function private.guard_platform_role();

-- Superadmin always has every permission: its grid column cannot be edited.
create or replace function private.guard_superadmin_permissions()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.platform_roles r
             where r.id = coalesce(new.role_id, old.role_id) and r.is_superadmin) then
    raise exception 'Superadmin always has every permission and cannot be edited'
      using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger platform_role_permissions_guard
  before insert or update or delete on public.platform_role_permissions
  for each row execute function private.guard_superadmin_permissions();

-- Only a superadmin can make someone a superadmin, and the last active superadmin
-- cannot be removed, disabled or moved to another role.
-- (Direct SQL by the database owner, with no signed-in user, is how the first
-- superadmin is added.)
create or replace function private.guard_platform_staff()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_super_role uuid := (select id from public.platform_roles where is_superadmin);
begin
  if tg_op in ('INSERT', 'UPDATE') and new.role_id = v_super_role
     and (tg_op = 'INSERT' or old.role_id <> v_super_role)
     and (select auth.uid()) is not null
     and not private.is_platform_superadmin() then
    raise exception 'Only a superadmin can give the Superadmin role' using errcode = 'insufficient_privilege';
  end if;

  if tg_op in ('UPDATE', 'DELETE') and old.role_id = v_super_role and old.status = 'active'
     and (tg_op = 'DELETE' or new.role_id <> v_super_role or new.status <> 'active')
     and not exists (select 1 from public.platform_staff s
                     where s.role_id = v_super_role and s.status = 'active' and s.user_id <> old.user_id) then
    raise exception 'KAMI must keep at least one active superadmin' using errcode = 'check_violation';
  end if;

  if tg_op = 'UPDATE' and new.user_id <> old.user_id then
    raise exception 'A staff record cannot be moved to another login' using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function private.guard_platform_role(), private.guard_superadmin_permissions(),
  private.guard_platform_staff() from public;

create trigger platform_staff_guard
  before insert or update or delete on public.platform_staff
  for each row execute function private.guard_platform_staff();

create trigger platform_roles_updated_at before update on public.platform_roles
  for each row execute function private.set_updated_at();
create trigger platform_staff_updated_at before update on public.platform_staff
  for each row execute function private.set_updated_at();

-- Every change is logged with its reason.
create trigger platform_permissions_audit after insert or update or delete on public.platform_permissions
  for each row execute function private.audit_platform_change();
create trigger platform_roles_audit after insert or update or delete on public.platform_roles
  for each row execute function private.audit_platform_change();
create trigger platform_role_permissions_audit after insert or update or delete on public.platform_role_permissions
  for each row execute function private.audit_platform_change();
create trigger platform_staff_audit after insert or update or delete on public.platform_staff
  for each row execute function private.audit_platform_change();

-- ---------------------------------------------------------------------------
-- Seed: the permission grid and the built-in roles (from the console prototype)
-- ---------------------------------------------------------------------------

select set_config('kami.audit_reason', 'Initial platform setup', true);

insert into public.platform_permissions (key, label, group_name, sort_order) values
  ('biz.view',        'See businesses and usage numbers',          'Businesses',       10),
  ('biz.create',      'Create businesses and owner invite links',  'Businesses',       20),
  ('trial.extend',    'Extend trials',                             'Subscriptions',    30),
  ('plan.change',     'Change plan and add overrides',             'Subscriptions',    40),
  ('biz.suspend',     'Suspend or reactivate a business',          'Subscriptions',    50),
  ('plans.manage',    'Create and edit plans and prices',          'Billing',          60),
  ('billing.export',  'Export billing and usage reports',          'Billing',          70),
  ('log.view',        'Read the platform log',                     'Logs and support', 80),
  ('support.remote',  'Remote support (owner must approve)',       'Logs and support', 90),
  ('settings.manage', 'Platform settings and app catalog',         'System',          100),
  ('staff.mfa',       'Reset a staff member''s two-factor',        'Staff',           110),
  ('staff.manage',    'Add staff and edit roles',                  'Staff',           120);

insert into public.platform_roles (key, name, description, is_superadmin, is_system) values
  ('superadmin', 'Superadmin', 'Everything, including staff and roles',  true,  true),
  ('accountant', 'Accountant', 'Billing and subscriptions',              false, true),
  ('support',    'Support',    'Logs and remote support',                false, true),
  ('onboarding', 'Onboarding', 'New businesses and trials',              false, true),
  ('operations', 'Operations', 'Settings and app catalog',               false, true),
  ('developer',  'Developer',  'Read-only data, logs and app catalog',   false, true),
  ('auditor',    'Auditor',    'Read-only',                              false, true);

insert into public.platform_role_permissions (role_id, permission_key)
select r.id, p.key
from (values
  ('accountant', 'biz.view'), ('accountant', 'trial.extend'), ('accountant', 'plan.change'),
  ('accountant', 'plans.manage'), ('accountant', 'billing.export'), ('accountant', 'log.view'),
  ('support',    'biz.view'), ('support', 'log.view'), ('support', 'support.remote'), ('support', 'staff.mfa'),
  ('onboarding', 'biz.view'), ('onboarding', 'biz.create'), ('onboarding', 'trial.extend'),
  ('operations', 'biz.view'), ('operations', 'log.view'), ('operations', 'settings.manage'),
  ('developer',  'biz.view'), ('developer', 'log.view'), ('developer', 'settings.manage'),
  ('auditor',    'biz.view'), ('auditor', 'log.view'), ('auditor', 'billing.export')
) as g(role_key, perm)
join public.platform_roles r on r.key = g.role_key
join public.platform_permissions p on p.key = g.perm;

select set_config('kami.audit_reason', '', true);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.platform_permissions      enable row level security;
alter table public.platform_roles            enable row level security;
alter table public.platform_role_permissions enable row level security;
alter table public.platform_staff            enable row level security;

revoke all on public.platform_permissions, public.platform_roles,
  public.platform_role_permissions, public.platform_staff from anon, authenticated;
grant select on public.platform_permissions to authenticated;
grant select, insert, update, delete on public.platform_roles, public.platform_role_permissions,
  public.platform_staff to authenticated;

-- Permission list: any staff member can read it; it changes only by migration.
create policy "staff read permissions" on public.platform_permissions
  for select to authenticated using ((select private.is_platform_staff()));

-- Roles and the grid: staff read; staff.manage changes.
create policy "staff read roles" on public.platform_roles
  for select to authenticated using ((select private.is_platform_staff()));
create policy "staff.manage adds roles" on public.platform_roles
  for insert to authenticated with check ((select private.has_platform_permission('staff.manage')));
create policy "staff.manage edits roles" on public.platform_roles
  for update to authenticated
  using ((select private.has_platform_permission('staff.manage')))
  with check ((select private.has_platform_permission('staff.manage')));
create policy "staff.manage deletes roles" on public.platform_roles
  for delete to authenticated using ((select private.has_platform_permission('staff.manage')));

create policy "staff read grid" on public.platform_role_permissions
  for select to authenticated using ((select private.is_platform_staff()));
create policy "staff.manage grants" on public.platform_role_permissions
  for insert to authenticated with check ((select private.has_platform_permission('staff.manage')));
create policy "staff.manage edits grants" on public.platform_role_permissions
  for update to authenticated
  using ((select private.has_platform_permission('staff.manage')))
  with check ((select private.has_platform_permission('staff.manage')));
create policy "staff.manage revokes" on public.platform_role_permissions
  for delete to authenticated using ((select private.has_platform_permission('staff.manage')));

-- Staff list: staff read it; a signed-in person can always see their own row, so the
-- app can tell them to finish two-factor before the console opens.
create policy "staff read staff, people read own row" on public.platform_staff
  for select to authenticated
  using ((select private.is_platform_staff()) or user_id = (select auth.uid()));
create policy "staff.manage adds staff" on public.platform_staff
  for insert to authenticated with check ((select private.has_platform_permission('staff.manage')));
create policy "staff.manage edits staff" on public.platform_staff
  for update to authenticated
  using ((select private.has_platform_permission('staff.manage')))
  with check ((select private.has_platform_permission('staff.manage')));
create policy "staff.manage removes staff" on public.platform_staff
  for delete to authenticated using ((select private.has_platform_permission('staff.manage')));

-- Policies for the tables from the previous migration.
grant select on public.platform_audit_log to authenticated;
create policy "log.view reads the log" on public.platform_audit_log
  for select to authenticated using ((select private.has_platform_permission('log.view')));
-- No insert, update or delete policy or grant: only the audit trigger writes the log.

grant select, insert, update, delete on public.platform_settings to authenticated;
create policy "staff read settings" on public.platform_settings
  for select to authenticated using ((select private.is_platform_staff()));
create policy "settings.manage adds settings" on public.platform_settings
  for insert to authenticated with check ((select private.has_platform_permission('settings.manage')));
create policy "settings.manage edits settings" on public.platform_settings
  for update to authenticated
  using ((select private.has_platform_permission('settings.manage')))
  with check ((select private.has_platform_permission('settings.manage')));
create policy "settings.manage removes settings" on public.platform_settings
  for delete to authenticated using ((select private.has_platform_permission('settings.manage')));
