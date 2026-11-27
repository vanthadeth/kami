-- Plans, subscriptions, overrides, and the day-90 read-only rule.
begin;
select plan(21);

-- 1 onboarding, 2 accountant, 3 auditor, 4 plain user, 5 support (no subscription perms), 9 superadmin
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'), ('00000000-0000-0000-0000-000000000004'),
  ('00000000-0000-0000-0000-000000000005'), ('00000000-0000-0000-0000-000000000009');
select set_config('kami.audit_reason', 'Test setup', true);
insert into public.platform_staff (user_id, role_id, status)
select u, (select id from public.platform_roles where key = r), 'active'
from (values
  ('00000000-0000-0000-0000-000000000009'::uuid, 'superadmin'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'onboarding'),
  ('00000000-0000-0000-0000-000000000002'::uuid, 'accountant'),
  ('00000000-0000-0000-0000-000000000003'::uuid, 'auditor'),
  ('00000000-0000-0000-0000-000000000005'::uuid, 'support')
) as t(u, r);
insert into public.plans (key, name, trial_days, billing_interval, base_price, price_per_user)
  values ('pro', 'Pro', null, 'month', 1500, 300);
insert into public.plans (key, name, status) values ('old_plan', 'Old plan', 'archived');
select set_config('kami.audit_reason', '', true);

create function pg_temp.login(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'aal', p_aal, 'role', 'authenticated')::text, true);
$$;
grant execute on function pg_temp.login(text, text) to authenticated;

-- The seeded plan ------------------------------------------------------------
select results_eq($$select name, is_public, trial_days, base_price from public.plans where key = 'free_90'$$,
  $$values ('Free for 90 days'::text, true, 90, 0)$$, 'free_90 is seeded: public, 90-day trial, free');

-- Starting a subscription (onboarding has biz.create) ----------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('kami.audit_reason', 'New business signed up', true);
select lives_ok($$insert into public.subscriptions (business_id, plan_id)
    select 'b0000000-0000-0000-0000-000000000001', id from public.plans where key = 'free_90'$$,
  'biz.create can start a subscription');
select throws_like($$insert into public.subscriptions (business_id, plan_id)
    select 'b0000000-0000-0000-0000-000000000002', id from public.plans where key = 'old_plan'$$,
  '%archived%', 'an archived plan cannot be given');
reset role;

select results_eq($$select status::text, trial_ends_at = created_at + interval '90 days', grace_days
    from public.subscriptions where business_id = 'b0000000-0000-0000-0000-000000000001'$$,
  $$values ('trialing'::text, true, 14)$$, 'a new subscription is trialing, ends after 90 days, 14 grace days');
select is((select reason from public.platform_audit_log where action = 'subscriptions.insert'),
  'New business signed up', 'starting a subscription is logged with its reason');
select is((select business_id from public.platform_audit_log where action = 'subscriptions.insert'),
  'b0000000-0000-0000-0000-000000000001'::uuid, 'the log entry names the business');

-- Each change needs its own permission ------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000001');  -- onboarding: trial.extend, not plan.change
set local role authenticated;
select set_config('kami.audit_reason', 'Asked for more time', true);
select lives_ok($$update public.subscriptions set trial_ends_at = trial_ends_at + interval '30 days'
    where business_id = 'b0000000-0000-0000-0000-000000000001'$$, 'onboarding can extend a trial');
select throws_like($$update public.subscriptions set plan_id = (select id from public.plans where key = 'pro')
    where business_id = 'b0000000-0000-0000-0000-000000000001'$$,
  '%plan.change%', 'onboarding cannot change the plan');
select throws_like($$update public.subscriptions set status = 'suspended', status_before_suspend = 'trialing'
    where business_id = 'b0000000-0000-0000-0000-000000000001'$$,
  '%biz.suspend%', 'onboarding cannot suspend');
reset role;

select pg_temp.login('00000000-0000-0000-0000-000000000002');  -- accountant: plan.change
set local role authenticated;
select set_config('kami.audit_reason', 'Moved to Pro', true);
select lives_ok($$update public.subscriptions set plan_id = (select id from public.plans where key = 'pro'), status = 'active'
    where business_id = 'b0000000-0000-0000-0000-000000000001'$$, 'an accountant can change the plan');
select throws_ok($$delete from public.subscriptions$$, '42501', null, 'nobody deletes subscriptions through the API');
select throws_ok($$delete from public.plans where key = 'pro'$$, '42501', null, 'plans are archived, never deleted');
select lives_ok($$insert into public.subscription_overrides (subscription_id, kind, key, value, reason)
    select id, 'limit', 'max_users', 25, 'Pilot customer' from public.subscriptions
    where business_id = 'b0000000-0000-0000-0000-000000000001'$$, 'plan.change can add an override');
select throws_ok($$insert into public.subscription_overrides (subscription_id, kind, key, reason)
    select id, 'limit', 'max_users', 'Missing value' from public.subscriptions
    where business_id = 'b0000000-0000-0000-0000-000000000001'$$, '23514', null, 'a limit override needs a value');
reset role;

-- Who can read --------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000003');  -- auditor: biz.view
set local role authenticated;
select is((select count(*)::int from public.subscriptions), 1, 'biz.view reads subscriptions');
select set_config('kami.audit_reason', 'Trying', true);
update public.subscriptions set internal_note = 'auditor was here';
reset role;
select is((select internal_note from public.subscriptions), null, 'an auditor cannot edit subscriptions');

select pg_temp.login('00000000-0000-0000-0000-000000000004');  -- business user
set local role authenticated;
select is((select count(*)::int from public.subscriptions) + (select count(*)::int from public.plans)
        + (select count(*)::int from public.subscription_overrides), 0,
  'business users see no plans, subscriptions or overrides');
reset role;

-- Day 90: read-only rule (as the database owner, like the daily job) ------------
select set_config('request.jwt.claims', '', true);
select set_config('kami.audit_reason', 'Test: trial over', true);
update public.subscriptions set status = 'trialing', trial_ends_at = now() - interval '20 days', grace_days = 14;
select ok(private.business_is_writable('b0000000-0000-0000-0000-000000000001'),
  'with enforcement off, a business past its trial can still write');

update public.platform_settings set value = 'true' where key = 'enforce_trial_end';
select ok(not private.business_is_writable('b0000000-0000-0000-0000-000000000001'),
  'with enforcement on, trial end + 14 grace days passed means read-only');

update public.subscriptions set trial_ends_at = now() - interval '10 days';
select ok(private.business_is_writable('b0000000-0000-0000-0000-000000000001'),
  'inside the 14 grace days the business can still write');

update public.platform_settings set value = 'false' where key = 'enforce_trial_end';
update public.subscriptions set status = 'suspended', status_before_suspend = 'trialing';
select ok(not private.business_is_writable('b0000000-0000-0000-0000-000000000001'),
  'a suspended business can never write, even with enforcement off');

select * from finish();
rollback;
