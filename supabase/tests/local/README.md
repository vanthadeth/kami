# Database tests

pgTAP tests for the migrations in `supabase/migrations`.

- With the Supabase CLI and Docker: `supabase test db` runs `supabase/tests/database/*.sql`.
- On plain Postgres (no Docker): `supabase/tests/local/run.sh`. It creates a throwaway
  database, loads `supabase_stub.sql` (a tiny stand-in for Supabase's `auth` schema and API
  roles), applies every migration, then runs the tests with `pg_prove`. CI uses this.

A test signs in as someone by setting the JWT claims and switching role, for example:

    select set_config('request.jwt.claims', '{"sub":"<uuid>","aal":"aal2"}', true);
    set local role authenticated;

`aal2` means the person passed two-factor; use `aal1` to test without it.
Every platform change needs a reason: `select set_config('kami.audit_reason', '...', true);`
