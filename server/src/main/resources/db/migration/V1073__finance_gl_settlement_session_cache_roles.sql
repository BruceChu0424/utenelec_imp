-- FK actions execute row triggers as the affected table owner. The invoker
-- creating this transaction-local cache may therefore differ from the next
-- invoker in the same session. Share only this cache with those exact actors;
-- business-table ACLs, function ownership and settlement arithmetic stay intact.
CREATE OR REPLACE FUNCTION fn_finance_gl_settlement_lock_style(p_style uuid,p_dirty boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE cache_actor record;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('finance-gl-settlement-style:'||p_style::text,0));
 IF to_regclass('pg_temp.finance_gl_settlement_dirty') IS NULL THEN
  CREATE TEMP TABLE finance_gl_settlement_dirty(style_id uuid PRIMARY KEY,generation bigint NOT NULL,checked_generation bigint NOT NULL DEFAULT -1) ON COMMIT DROP;
  FOR cache_actor IN
   SELECT role.rolname FROM pg_catalog.pg_roles role
   WHERE role.rolname<>current_user AND (
    role.rolname=session_user OR role.rolname=current_setting('role',true)
    OR role.oid IN (
     SELECT relation.relowner FROM pg_catalog.pg_class relation
     WHERE relation.oid IN ('public.gl_entries'::regclass,'public.gl_vouchers'::regclass,
      'public.finance_gl_entry_allocations'::regclass,'public.finance_gl_settlement_reservations'::regclass,
      'public.finance_native_legacy_opening_parts'::regclass)
    )
   )
  LOOP
   EXECUTE format('GRANT SELECT, INSERT, UPDATE ON TABLE pg_temp.finance_gl_settlement_dirty TO %I',cache_actor.rolname);
  END LOOP;
 END IF;
 INSERT INTO pg_temp.finance_gl_settlement_dirty(style_id,generation) VALUES(p_style,CASE WHEN p_dirty THEN 1 ELSE 0 END)
  ON CONFLICT(style_id) DO UPDATE SET generation=finance_gl_settlement_dirty.generation+CASE WHEN p_dirty THEN 1 ELSE 0 END;
END $$;
