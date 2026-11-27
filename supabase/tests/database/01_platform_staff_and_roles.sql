-- Platform staff, roles, two-factor and the permission grid.
begin;
select plan(25);

-- People: 1 superadmin, 2 accountant, 3 auditor, 4 plain user (not staff), 5 staff admin (custom role), 6 disabled staff
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'), ('00000000-0000-0000-0000-000000000004'),
  ('00000000-0000-0000-0000-000000000005'), ('00000000-0000-0000-0000-000000000006');

select set_config('kami.audit_reason', 'Test setup', true);
insert into public.platform_roles (key, name) values ('staff_admin', 'Staff admin');
insert into public.platform_role_permissions (role_id, permission_key)
  select id, 'staff.manage' from public.platform_roles where key = 'staff_admin';
insert into public.platform_staff (user_id, role_id, status)
select u, (select id from public.platform_roles where key = r), s::public.platform_staff_status
from (values
  ('00000000-0000-0000-0000-000000000001'::uuid, 'superadmin',  'active'),
  ('00000000-0000-0000-0000-000000000002'::uuid, 'accountant',  'active'),
  ('00000000-0000-0000-0000-000000000003'::uuid, 'auditor',     'active'),
  ('00000000-0000-0000-0000-000000000005'::uuid, 'staff_admin', 'active'),
  ('00000000-0000-0000-0000-000000000006'::uuid, 'accountant',  'disabled')
) as t(u, r, s);
select set_config('kami.audit_reason', '', true);

-- p_mfa_age_min: minutes since the second factor was entered (null = never, as with aal1)
create function pg_temp.login(p_user text, p_aal text default 'aal2', p_mfa_age_min int default 1) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object(
    'sub', p_user, 'aal', p_aal, 'role', 'authenticated',
    'amr', case when p_aal = 'aal2' and p_mfa_age_min is not null
                then json_build_array(json_build_object('method', 'totp',
                       'timestamp', floor(extract(epoch from now())) - p_mfa_age_min * 60)) end)::text, true);
$$;
grant execute on function pg_temp.login(text, text, int) to authenticated;

-- Seed ----------------------------------------------------------------------
select is((select count(*)::int from public.platform_permissions), 12, 'the grid has 12 permissions');
select set_eq($$select key from public.platform_roles where is_system$$,
  array['superadmin','accountant','support','onboarding','operations','developer','auditor'],
  'the 7 built-in roles are seeded');

select is_empty($$select 1 from public.platform_role_permissions rp
    join public.platform_roles r on r.id = rp.role_id
    where rp.permission_key = 'staff.mfa'$$,
  'only superadmin can reset two-factor: no other role has staff.mfa');

-- Anonymous visitors -----------------------------------------------------------
set local role anon;
select throws_ok($$select * from public.platform_roles$$, '42501', null, 'anon cannot read roles');
select throws_ok($$select * from public.platform_staff$$, '42501', null, 'anon cannot read staff');
reset role;

-- A signed-in business user who is not staff ----------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000004');
set local role authenticated;
select is((select count(*)::int from public.platform_roles), 0, 'non-staff see no roles');
select is((select count(*)::int from public.platform_staff), 0, 'non-staff see no staff');
select is((select count(*)::int from public.platform_permissions), 0, 'non-staff see no permissions');
reset role;

-- Two-factor is required -------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000001', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.platform_roles), 0, 'superadmin without two-factor sees no roles');
select is((select count(*)::int from public.platform_staff), 1, 'without two-factor you still see your own staff row');
reset role;

select pg_temp.login('00000000-0000-0000-0000-000000000001');
set local role authenticated;
select is((select count(*)::int from public.platform_roles), 8, 'superadmin with two-factor sees all roles');
select is((select count(*)::int from public.platform_staff), 5, 'superadmin sees every staff member');

-- Every change needs a reason
select throws_like($$update public.platform_roles set name = 'Billing' where key = 'accountant'$$,
  '%reason is required%', 'a change without a reason is refused');

select set_config('kami.audit_reason', 'Rename for clarity', true);
select lives_ok($$update public.platform_roles set name = 'Billing' where key = 'accountant'$$,
  'superadmin can rename a role with a reason');
select throws_like($$insert into public.platform_role_permissions (role_id, permission_key)
    select id, 'log.view' from public.platform_roles where key = 'superadmin'$$,
  '%every permission%', 'the superadmin grid column cannot be edited');
select throws_like($$delete from public.platform_roles where key = 'auditor'$$,
  '%cannot be deleted%', 'built-in roles cannot be deleted');
select throws_like($$update public.platform_staff set role_id = (select id from public.platform_roles where key = 'auditor')
    where user_id = '00000000-0000-0000-0000-000000000001'$$,
  '%your own staff record%', 'nobody can change their own role, not even a superadmin');
reset role;

-- Risky changes need a fresh two-factor code (within 15 minutes)
select pg_temp.login('00000000-0000-0000-0000-000000000001', 'aal2', 30);
set local role authenticated;
select set_config('kami.audit_reason', 'Rename again', true);
select throws_like($$update public.platform_roles set name = 'Billing team' where key = 'accountant'$$,
  '%two-factor code again%', 'a two-factor code older than 15 minutes cannot change roles');
reset role;

-- Permission by role ----------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000003');  -- auditor
set local role authenticated;
select set_config('kami.audit_reason', 'Trying', true);
select throws_ok($$insert into public.platform_roles (key, name) values ('sneaky', 'Sneaky')$$,
  '42501', null, 'an auditor cannot add roles');
reset role;

select pg_temp.login('00000000-0000-0000-0000-000000000005');  -- staff admin (staff.manage, not superadmin)
set local role authenticated;
select set_config('kami.audit_reason', 'New teammate', true);
select throws_like($$insert into public.platform_staff (user_id, role_id, status)
    select '00000000-0000-0000-0000-000000000004', id, 'invited' from public.platform_roles where key = 'superadmin'$$,
  '%Only a superadmin%', 'only a superadmin can give the Superadmin role');
select lives_ok($$insert into public.platform_staff (user_id, role_id, status)
    select '00000000-0000-0000-0000-000000000004', id, 'invited' from public.platform_roles where key = 'auditor'$$,
  'staff.manage can add an auditor');
select throws_like($$update public.platform_staff set status = 'disabled'
    where user_id = '00000000-0000-0000-0000-000000000001'$$,
  '%at least one active superadmin%', 'the last active superadmin cannot be disabled');
reset role;

-- Disabled staff --------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000006');
set local role authenticated;
select is((select count(*)::int from public.platform_roles), 0, 'disabled staff see nothing');
reset role;

-- The log recorded who and why ------------------------------------------------
select is((select reason from public.platform_audit_log
           where action = 'platform_staff.insert' and new_value ->> 'user_id' = '00000000-0000-0000-0000-000000000004'),
  'New teammate', 'adding staff is logged with its reason');
select is((select actor_user_id from public.platform_audit_log
           where action = 'platform_staff.insert' and new_value ->> 'user_id' = '00000000-0000-0000-0000-000000000004'),
  '00000000-0000-0000-0000-000000000005'::uuid, 'the log records who made the change');

select * from finish();
rollback;
