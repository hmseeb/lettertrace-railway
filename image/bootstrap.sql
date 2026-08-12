-- Everything the Supabase platform normally sets up for you before an app's own
-- schema is applied. Runs once per boot, before GoTrue migrates, and is safe to
-- re-run.
--
-- Lettertrace's schema.sql assumes all of this exists: it writes row-level
-- security policies against auth.uid(), and it revokes privileges from `anon`
-- and `authenticated` on the assumption something already granted them.

\set ON_ERROR_STOP on

create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";

-- The three roles PostgREST switches into, named exactly as Supabase names them
-- because the app's policies and its service-role key both refer to them.
do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    -- Bypasses row-level security, matching Supabase. The scheduled-run
    -- endpoint and the API-key surface need to read across every account.
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

-- The role PostgREST actually connects as. It owns nothing and can read
-- nothing; its only power is to become one of the three above, chosen by the
-- `role` claim in the caller's token.
-- Built as a string and executed, rather than done inside a DO block, because
-- psql does not substitute :variables inside dollar-quoted bodies - the password
-- would land in the database as the literal text ":'authenticator_pw'".
select format('create role authenticator login noinherit password %L', :'authenticator_pw')
where not exists (select from pg_roles where rolname = 'authenticator')
\gexec

select format('alter role authenticator with login noinherit password %L', :'authenticator_pw')
\gexec

grant anon, authenticated, service_role to authenticator;

-- GoTrue creates and owns everything under `auth`; we only pre-create the
-- schema so the helper functions below can be defined before it runs.
create schema if not exists auth;

-- The account this deployment's login service connects as.
--
-- It exists for one reason: GoTrue's migrations create their enum types
-- WITHOUT a schema qualifier and rely on the connection's default schema being
-- `auth`. Connect it as the ordinary database owner and those types are created
-- in `public`, then a later migration asks for `auth.factor_type`, fails, and
-- rolls the whole thing back - leaving a half-built auth schema and an app that
-- boots to a 502. Setting the default schema on the role is the fix Supabase
-- itself uses, and it applies at connection time regardless of driver.
select format('create role supabase_auth_admin login noinherit password %L', :'auth_admin_pw')
where not exists (select from pg_roles where rolname = 'supabase_auth_admin')
\gexec

select format('alter role supabase_auth_admin with login noinherit password %L', :'auth_admin_pw')
\gexec

alter role supabase_auth_admin set search_path = auth;
alter schema auth owner to supabase_auth_admin;
grant all on schema auth to supabase_auth_admin;

-- auth.uid() is NOT defined here on purpose. GoTrue's first migration creates
-- its own, and it refuses to start if it finds one owned by anybody else
-- ("must be owner of function uid"). It is redefined in auth-helpers.sql after
-- GoTrue has finished, which is the only window where both are true.
grant usage on schema auth to anon, authenticated, service_role;

grant usage on schema public to anon, authenticated, service_role;

-- Applied BEFORE schema.sql creates its tables, which is the whole point: the
-- grants land as each table is created, and schema.sql's selective REVOKEs then
-- take privileges away from there. Reversing the order would leave every table
-- unreadable and every REVOKE a no-op.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

-- Covers a schema that was created before this file ever ran (an upgrade from
-- an older image, or a database restored from elsewhere).
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
