-- Close inherited default table privileges on original production provenance.
-- No rows, immutable source lineage or role memberships are changed.
-- Owner and runtime must remain separate production roles.
DO $runtime_provenance_acl$
DECLARE target regclass; privilege_name text; owner_id oid; reachable_role record;
BEGIN
 IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
  FOREACH target IN ARRAY ARRAY[
   'public.legacy_production_plan_counter_import_sources'::regclass,
   'public.legacy_production_plan_counter_import_contexts'::regclass]
  LOOP
   EXECUTE format('REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON TABLE %s FROM uten,PUBLIC',target);
   -- Preserve SELECT, but not delegation. Dependencies cause a safe failure;
   -- do not CASCADE through unrelated grants without a separate reviewed plan.
   EXECUTE format('REVOKE GRANT OPTION FOR SELECT ON TABLE %s FROM uten',target);
   EXECUTE format('GRANT SELECT ON TABLE %s TO uten',target);
   SELECT c.relowner INTO STRICT owner_id FROM pg_catalog.pg_class c WHERE c.oid=target;
   IF pg_catalog.pg_has_role('uten',owner_id,'SET') THEN
    RAISE EXCEPTION 'runtime can assume production provenance owner' USING ERRCODE='42501';
   END IF;
   -- NOINHERIT does not prevent SET ROLE. Check every transitively reachable
   -- role, including a non-owner writer, without changing global membership.
   FOR reachable_role IN SELECT r.oid FROM pg_catalog.pg_roles r
     WHERE pg_catalog.pg_has_role('uten',r.oid,'SET') LOOP
    FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','SELECT WITH GRANT OPTION'] LOOP
     IF pg_catalog.has_table_privilege(reachable_role.oid,target,privilege_name) THEN
      RAISE EXCEPTION 'runtime can assume a role with provenance write or delegation authority' USING ERRCODE='42501';
     END IF;
    END LOOP;
    FOREACH privilege_name IN ARRAY ARRAY['INSERT','UPDATE','REFERENCES','SELECT WITH GRANT OPTION'] LOOP
     IF pg_catalog.has_any_column_privilege(reachable_role.oid,target,privilege_name) THEN
      RAISE EXCEPTION 'runtime can assume a role with provenance column write or delegation authority' USING ERRCODE='42501';
     END IF;
    END LOOP;
   END LOOP;
  END LOOP;
 END IF;
END;
$runtime_provenance_acl$;
