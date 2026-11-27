-- The platform log is append-only and readable only with log.view; settings need settings.manage.
begin;
select plan(14);

-- 1 auditor (log.view), 2 onboarding (no log.view), 3 operations (settings.manage), 4 plain user
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'), ('00000000-0000-0000-0000-000000000004'),
  ('00000000-0000-0000-0000-000000000009');
select set_config('kami.audit_reason', 'Test setup', true);
insert into public.platform_staff (user_id, role_id, status)
select u, (select id from public.platform_roles where key = r), 'active'
from (values
  ('00000000-0000-0000-0000-000000000009'::uuid, 'superadmin'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'auditor'),
  ('00000000-0000-0000-0000-000000000002'::uuid, 'onboarding'),
  ('00000000-0000-0000-0000-000000000003'::uuid, 'operations')
) as t(u, r);
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

-- Append-only, even for the database owner -------------------------------------
select ok((select count(*) from public.platform_audit_log) > 0, 'setup changes were logged');
select throws_like($$update public.platform_audit_log set reason = 'changed'$$, '%append-only%',
  'log rows cannot be edited, even by the owner');
select throws_like($$delete from public.platform_audit_log$$, '%append-only%',
  'log rows cannot be deleted, even by the owner');
select throws_like($$truncate public.platform_audit_log$$, '%append-only%',
  'the log cannot be truncated');
select throws_ok($$insert into public.platform_audit_log (action, reason) values ('note', '  ')$$,
  '23514', null, 'a log row needs a real reason');

-- Who reads the log -------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000001');
set local role authenticated;
select ok((select count(*) from public.platform_audit_log) > 0, 'log.view (auditor) reads the log');
select throws_ok($$insert into public.platform_audit_log (action, reason) values ('note', 'Fake entry')$$,
  '42501', null, 'staff cannot write log rows directly');
reset role;

select pg_temp.login('00000000-0000-0000-0000-000000000002');
set local role authenticated;
select is((select count(*)::int from public.platform_audit_log), 0, 'onboarding (no log.view) sees no log rows');
reset role;

select pg_temp.login('00000000-0000-0000-0000-000000000004');
set local role authenticated;
select is((select count(*)::int from public.platform_audit_log), 0, 'business users see no log rows');
select is((select count(*)::int from public.platform_settings), 0, 'business users see no settings');
reset role;

-- Settings -------------------------------------------------------------------
select is((select value from public.platform_settings where key = 'enforce_trial_end'), 'false'::jsonb,
  'trial-end enforcement starts switched off');

select pg_temp.login('00000000-0000-0000-0000-000000000001');  -- auditor: no settings.manage
set local role authenticated;
select set_config('kami.audit_reason', 'Trying', true);
update public.platform_settings set value = 'true' where key = 'enforce_trial_end';
reset role;
select is((select value from public.platform_settings where key = 'enforce_trial_end'), 'false'::jsonb,
  'an auditor cannot change settings');

select pg_temp.login('00000000-0000-0000-0000-000000000003', 'aal2', 20);  -- operations, old 2FA code
set local role authenticated;
select set_config('kami.audit_reason', 'Paid plans are live', true);
select throws_like($$update public.platform_settings set value = 'true' where key = 'enforce_trial_end'$$,
  '%two-factor code again%', 'changing a setting needs a two-factor code from the last 15 minutes');
reset role;

select pg_temp.login('00000000-0000-0000-0000-000000000003');  -- operations: settings.manage
set local role authenticated;
select set_config('kami.audit_reason', 'Paid plans are live', true);
update public.platform_settings set value = 'true' where key = 'enforce_trial_end';
reset role;
select is((select value from public.platform_settings where key = 'enforce_trial_end'), 'true'::jsonb,
  'settings.manage can switch enforcement on');

select * from finish();
rollback;
