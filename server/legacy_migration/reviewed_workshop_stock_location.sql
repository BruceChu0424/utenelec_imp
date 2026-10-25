-- Historical location only: never opens a bin/period, approves a document or changes source numbers.
-- Both supported entry points prepend this exact file before migrate_stock_docs.sql.
SET LOCAL TimeZone='Asia/Shanghai';
CREATE TEMP TABLE workshop_stock_location_review_stage (
 goods_legacy_id int PRIMARY KEY, goods_code text, goods_name text, original_owning_warehouse text,
 workshop_code text, workshop_name text, owning_warehouse text, resolution text, source_file text, source_row int);
\copy workshop_stock_location_review_stage FROM '/tmp/goods_workshop_stock_location_review.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE workshop_stock_location_crosswalk_stage (
 goods_legacy_id int PRIMARY KEY, goods_code text, goods_name text, workshop_code text,
 bin_warehouse_id uuid, authority_sha256 text);
\copy workshop_stock_location_crosswalk_stage FROM '/tmp/workshop_stock_location_crosswalk.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE workshop_stock_location_authority_stage (
 format text, approved boolean, target_database text, target_database_oid oid, target_sid text,
 workshop_code text, workshop_department_id uuid, bin_warehouse_id uuid,
 bin_row_sha256 text, warehouse_row_sha256 text, department_row_sha256 text,
 opened_by uuid, opened_at timestamptz, source_warehouse_id uuid, bin_row_version bigint,
 authority_sha256 text, snapshot_sha256 text, review_sha256 text);
\copy workshop_stock_location_authority_stage FROM '/tmp/workshop_stock_location_authority.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE workshop_stock_location_identity_stage(goods_legacy_id int PRIMARY KEY,goods_code text,goods_name text);
INSERT INTO workshop_stock_location_identity_stage VALUES
 (65919,'GD2056','B款暗装轨道E极铜条（90型）'),
 (65920,'GD2057','B款暗装轨道LN极铜条（90型  磨床切割）'),
 (65921,'GD2058','B款暗装轨道PVC线槽（90型）'),
 (65923,'GD2060','B款暗装铝合金轨道90型（铣床加工）');

DO $reviewed_workshop_stock_location$
DECLARE a workshop_stock_location_authority_stage%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM workshop_stock_location_review_stage)
    AND NOT EXISTS(SELECT 1 FROM workshop_stock_location_crosswalk_stage)
    AND NOT EXISTS(SELECT 1 FROM workshop_stock_location_authority_stage)
    AND NOT EXISTS(SELECT 1 FROM goods g JOIN workshop_stock_location_identity_stage e ON e.goods_legacy_id=g.legacy_id)
 THEN RETURN; END IF;
 IF NOT fn_imported_business_document_maintenance_allowed() THEN
  RAISE EXCEPTION 'Reviewed historical stock location requires actual maintenance session'; END IF;
 IF (SELECT count(*) FROM workshop_stock_location_review_stage)<>4
    OR (SELECT count(*) FROM workshop_stock_location_crosswalk_stage)<>4
    OR (SELECT count(*) FROM workshop_stock_location_authority_stage)<>1
    OR EXISTS(SELECT 1 FROM workshop_stock_location_identity_stage e
       FULL JOIN workshop_stock_location_review_stage r USING(goods_legacy_id)
       WHERE e.goods_legacy_id IS NULL OR r.goods_legacy_id IS NULL
          OR (r.goods_code,r.goods_name,r.original_owning_warehouse,r.workshop_code)
             IS DISTINCT FROM (e.goods_code,e.goods_name,'五金车间'::text,'WS_WJTZ'::text)
          OR NULLIF(r.owning_warehouse,'') IS NOT NULL)
    OR EXISTS(SELECT 1 FROM workshop_stock_location_identity_stage e
       FULL JOIN workshop_stock_location_crosswalk_stage x USING(goods_legacy_id)
       WHERE e.goods_legacy_id IS NULL OR x.goods_legacy_id IS NULL
          OR (x.goods_code,x.goods_name,x.workshop_code)
             IS DISTINCT FROM (e.goods_code,e.goods_name,'WS_WJTZ'::text)) THEN
  RAISE EXCEPTION 'Workshop stock location exact four identities/review/crosswalk required'; END IF;
 SELECT * INTO STRICT a FROM workshop_stock_location_authority_stage;
 IF a.format IS DISTINCT FROM 'REVIEWED_OPEN_BIN_HISTORICAL_STOCK_V1'
    OR a.approved IS DISTINCT FROM true OR a.workshop_code IS DISTINCT FROM 'WS_WJTZ'
    OR a.target_database IS DISTINCT FROM current_database()
    OR a.target_database_oid IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database())
    OR a.target_sid IS DISTINCT FROM (SELECT system_identifier::text FROM pg_control_system())
    OR a.authority_sha256 !~ '^[0-9a-f]{64}$' OR a.snapshot_sha256 !~ '^[0-9a-f]{64}$'
    OR a.review_sha256 !~ '^[0-9a-f]{64}$' OR a.authority_sha256 IS NULL
    OR a.snapshot_sha256 IS NULL OR a.review_sha256 IS NULL
    OR EXISTS(SELECT 1 FROM workshop_stock_location_crosswalk_stage x
       WHERE x.authority_sha256 IS DISTINCT FROM a.authority_sha256 OR x.bin_warehouse_id IS DISTINCT FROM a.bin_warehouse_id)
 THEN RAISE EXCEPTION 'Workshop stock location authorization/target mismatch'; END IF;
 PERFORM 1 FROM workshop_bins b WHERE b.workshop_department_id=a.workshop_department_id FOR SHARE;
 PERFORM 1 FROM warehouses w WHERE w.id IN(a.bin_warehouse_id,fn_warehouse_root_id(),a.source_warehouse_id) FOR SHARE;
 PERFORM 1 FROM departments d WHERE d.id=a.workshop_department_id FOR SHARE;
 PERFORM 1 FROM goods g WHERE g.legacy_id IN(SELECT goods_legacy_id FROM workshop_stock_location_identity_stage) FOR SHARE;
 IF NOT EXISTS(SELECT 1 FROM workshop_bins b
    JOIN warehouses w ON w.id=b.bin_warehouse_id
    JOIN departments d ON d.id=b.workshop_department_id
    JOIN departments parent ON parent.id=d.parent_id AND parent.code='DEPT_PROD' AND NOT parent.is_deleted
    JOIN warehouses root ON root.id=w.parent_id AND root.id=fn_warehouse_root_id()
       AND NOT root.is_line_side AND NOT root.is_deleted AND root.status='使用'
    WHERE d.id=a.workshop_department_id AND d.code='WS_WJTZ' AND NOT d.is_deleted
      AND b.bin_warehouse_id=a.bin_warehouse_id AND w.is_line_side AND w.is_accountable
      AND NOT w.is_defective AND NOT w.is_deleted AND w.status='使用'
      AND w.workshop_department_id=d.id AND b.opened_by=a.opened_by AND b.opened_by IS NOT NULL
      AND b.opened_at=a.opened_at AND b.source_warehouse_id IS NOT DISTINCT FROM a.source_warehouse_id
      AND b.row_version=a.bin_row_version
      AND encode(sha256(convert_to(to_jsonb(b)::text,'UTF8')),'hex')=a.bin_row_sha256
      AND encode(sha256(convert_to(to_jsonb(w)::text,'UTF8')),'hex')=a.warehouse_row_sha256
      AND encode(sha256(convert_to(to_jsonb(d)::text,'UTF8')),'hex')=a.department_row_sha256)
    OR (a.source_warehouse_id IS NOT NULL AND NOT fn_warehouse_is_good_stock_leaf(a.source_warehouse_id))
    OR EXISTS(SELECT 1 FROM workshop_material_settings s WHERE s.workshop_department_id=a.workshop_department_id AND s.periodic_enabled)
 THEN RAISE EXCEPTION 'Actual reviewed unified bin opening/department/main-tree snapshot required; no periodic activation'; END IF;
 IF (SELECT count(*) FROM goods g JOIN workshop_stock_location_identity_stage e ON e.goods_legacy_id=g.legacy_id
     WHERE g.code=e.goods_code AND g.name=e.goods_name AND NOT g.is_deleted
       AND g.owning_warehouse_id IS NULL AND g.owning_workshop_department_id=a.workshop_department_id
       AND g.unit_id IS NOT NULL)<>4 THEN
  RAISE EXCEPTION 'Workshop stock goods exact legacy/code/name/dept/NULL ordinary owner/nonNULL unit required'; END IF;
END $reviewed_workshop_stock_location$;

CREATE TEMP TABLE reviewed_workshop_stock_location_stage AS
SELECT x.goods_legacy_id,x.bin_warehouse_id AS warehouse_id
FROM workshop_stock_location_crosswalk_stage x;
