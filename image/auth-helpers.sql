-- Runs after GoTrue has migrated and before the app's own schema is applied.
--
-- GoTrue ships an auth.uid() that only reads the OLD per-claim connection
-- setting (request.jwt.claim.sub). PostgREST stopped setting that by default in
-- v12 and drops it entirely later, so leaving GoTrue's version in place means
-- every row-level security policy silently sees a NULL user and the app shows
-- an empty dashboard to a signed-in person - the worst kind of failure, because
-- nothing errors.
--
-- Reading both shapes means the data API underneath can be upgraded without
-- taking the app's access rules with it. Applied as the database owner, which
-- can replace a function it does not own.
\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.email() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;

grant execute on function auth.uid(), auth.role(), auth.email()
  to anon, authenticated, service_role;
