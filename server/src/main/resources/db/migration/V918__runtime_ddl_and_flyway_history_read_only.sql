-- Restore the established split between the runtime and maintenance identities.
-- Business table/sequence privileges, CONNECT/TEMP, owners and memberships stay intact.
DO $runtime_ddl_history_acl$
DECLARE
 runtime_id oid;
 history_table regclass := 'public.flyway_schema_history'::regclass;
 owner_id oid;
 column_name text;
 privilege_name text;
 reachable_role record;
BEGIN
 SELECT oid INTO runtime_id FROM pg_catalog.pg_roles WHERE rolname='uten';
 IF runtime_id IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE oid=runtime_id
            AND (rolsuper OR rolcreatedb OR rolcreaterole)) THEN
   RAISE EXCEPTION 'V918: runtime has administrative role authority' USING ERRCODE='42501';
  END IF;
  FOR owner_id IN
   SELECT datdba FROM pg_catalog.pg_database WHERE datname=current_database()
   UNION SELECT nspowner FROM pg_catalog.pg_namespace WHERE nspname='public'
   UNION SELECT relowner FROM pg_catalog.pg_class WHERE oid=history_table
  LOOP
   IF pg_catalog.pg_has_role(runtime_id,owner_id,'SET') THEN
    RAISE EXCEPTION 'V918: runtime can assume database, schema or migration history owner' USING ERRCODE='42501';
   END IF;
  END LOOP;
 END IF;

 EXECUTE format('REVOKE CREATE ON DATABASE %I FROM PUBLIC',current_database());
 REVOKE CREATE ON SCHEMA public FROM PUBLIC;
 REVOKE ALL PRIVILEGES ON TABLE public.flyway_schema_history FROM PUBLIC;
 IF runtime_id IS NOT NULL THEN
  EXECUTE format('REVOKE CREATE ON DATABASE %I FROM uten',current_database());
  REVOKE CREATE ON SCHEMA public FROM uten;
  REVOKE ALL PRIVILEGES ON TABLE public.flyway_schema_history FROM uten;
 END IF;
 -- A table-level REVOKE does not remove independent column ACLs or grant options.
 FOR column_name IN SELECT attname FROM pg_catalog.pg_attribute
                    WHERE attrelid=history_table AND attnum>0 AND NOT attisdropped LOOP
  EXECUTE format('REVOKE ALL PRIVILEGES (%I) ON TABLE public.flyway_schema_history FROM PUBLIC',column_name);
  IF runtime_id IS NOT NULL THEN
   EXECUTE format('REVOKE ALL PRIVILEGES (%I) ON TABLE public.flyway_schema_history FROM uten',column_name);
  END IF;
 END LOOP;
 IF runtime_id IS NOT NULL THEN
  GRANT SELECT ON TABLE public.flyway_schema_history TO uten;
  -- Do not silently rewrite shared memberships or another role's grants. A
  -- NOINHERIT member can still SET ROLE; reject such bypasses transactionally.
  FOR reachable_role IN
   WITH RECURSIVE authority(role_id) AS (
    SELECT runtime_id
    UNION
    SELECT membership.roleid FROM authority parent
    JOIN pg_catalog.pg_auth_members membership ON membership.member=parent.role_id
    WHERE membership.set_option OR membership.admin_option
   ) SELECT role.oid,role.rolsuper,role.rolcreatedb,role.rolcreaterole
     FROM pg_catalog.pg_roles role JOIN authority ON authority.role_id=role.oid
  LOOP
   IF reachable_role.rolsuper OR reachable_role.rolcreatedb OR reachable_role.rolcreaterole THEN
    RAISE EXCEPTION 'V918: runtime can reach administrative role authority' USING ERRCODE='42501';
   END IF;
   IF pg_catalog.has_database_privilege(reachable_role.oid,current_database(),'CREATE')
      OR pg_catalog.has_schema_privilege(reachable_role.oid,'public','CREATE') THEN
    RAISE EXCEPTION 'V918: runtime can assume a role with database or public schema CREATE' USING ERRCODE='42501';
   END IF;
   FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','SELECT WITH GRANT OPTION'] LOOP
    IF pg_catalog.has_table_privilege(reachable_role.oid,history_table,privilege_name) THEN
     RAISE EXCEPTION 'V918: runtime can assume a role with migration history write or delegation authority' USING ERRCODE='42501';
    END IF;
   END LOOP;
   FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','REFERENCES','SELECT WITH GRANT OPTION'] LOOP
    IF pg_catalog.has_any_column_privilege(reachable_role.oid,history_table,privilege_name) THEN
     RAISE EXCEPTION 'V918: runtime can assume a role with migration history column write or delegation authority' USING ERRCODE='42501';
    END IF;
   END LOOP;
  END LOOP;
  -- These effective checks also cover inherited grants on edges without SET.
  IF pg_catalog.has_database_privilege(runtime_id,current_database(),'CREATE')
     OR pg_catalog.has_schema_privilege(runtime_id,'public','CREATE') THEN
   RAISE EXCEPTION 'V918: runtime retains effective DDL authority' USING ERRCODE='42501';
  END IF;
  FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','SELECT WITH GRANT OPTION'] LOOP
   IF pg_catalog.has_table_privilege(runtime_id,history_table,privilege_name) THEN
    RAISE EXCEPTION 'V918: runtime retains effective migration history write or delegation authority' USING ERRCODE='42501';
   END IF;
  END LOOP;
  FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','REFERENCES','SELECT WITH GRANT OPTION'] LOOP
   IF pg_catalog.has_any_column_privilege(runtime_id,history_table,privilege_name) THEN
    RAISE EXCEPTION 'V918: runtime retains effective migration history column authority' USING ERRCODE='42501';
   END IF;
  END LOOP;
 END IF;
END;
$runtime_ddl_history_acl$;
