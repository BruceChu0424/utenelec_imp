-- =====================================================================
-- 销售单据归属迁移：seller_legacy_id（老库 B_Worker.ID）→ owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --sales-owner
-- 前提：销售单据已迁；employees 有 legacy_id；V91 已应用。
-- seller_legacy_id 保留历史人；当前归属只给真正在职员工，离职/缺失旧人由 ADMIN 暂管。
-- 公共来源保持公共；已维护的当前归属不清空。下游仍按真实上游关系继承，并记录暂管对象。
-- =====================================================================


-- Requires Flyway V137 or later: the final verification and refresh depend on
-- the owner-aware sales_monthly_mv definition.

CREATE TEMP TABLE sales_owner_resolution AS
SELECT source.*,r.owner_id,r.original_employee_id,r.reason FROM (
 SELECT 'sales_orders'::text AS target_table,id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_orders
 UNION ALL SELECT 'sales_shipments',id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_shipments
 UNION ALL SELECT 'sales_other_shipments',id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_other_shipments
 UNION ALL SELECT 'sales_returns',id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_returns
) source CROSS JOIN LATERAL pg_temp.legacy_owner_resolution(
 CASE WHEN source.owner_employee_id IS NOT NULL AND COALESCE(source.seller_legacy_id,0)=0
      THEN 'employee_uuid:'||source.owner_employee_id::text ELSE source.seller_legacy_id::text END) r
WHERE source.owner_employee_id IS NULL OR NOT EXISTS (
 SELECT 1 FROM employees e WHERE e.id=source.owner_employee_id AND NOT e.is_deleted AND e.status IN ('active','probation','onLeave'));
UPDATE sales_orders t SET owner_employee_id=r.owner_id FROM sales_owner_resolution r
WHERE r.target_table='sales_orders' AND t.id=r.id AND t.owner_employee_id IS DISTINCT FROM r.owner_id;
UPDATE sales_shipments t SET owner_employee_id=r.owner_id FROM sales_owner_resolution r
WHERE r.target_table='sales_shipments' AND t.id=r.id AND t.owner_employee_id IS DISTINCT FROM r.owner_id;
UPDATE sales_other_shipments t SET owner_employee_id=r.owner_id FROM sales_owner_resolution r
WHERE r.target_table='sales_other_shipments' AND t.id=r.id AND t.owner_employee_id IS DISTINCT FROM r.owner_id;
UPDATE sales_returns t SET owner_employee_id=r.owner_id FROM sales_owner_resolution r
WHERE r.target_table='sales_returns' AND t.id=r.id AND t.owner_employee_id IS DISTINCT FROM r.owner_id;

-- A historical merged document can have several genuinely different upstream
-- owners. Preserve every relationship, but give its current responsibility to
-- the unique ADMIN until an explicit handover; never pick an owner or go public.
CREATE TEMP TABLE sales_owner_custodian AS
SELECT pg_temp.legacy_custodian_employee() AS employee_id;
CREATE TEMP TABLE sales_upstream_owner_refs (
 target_table text,target_id uuid,target_legacy_id int,target_item_id uuid,target_item_legacy_id int,
 upstream_kind text,upstream_document_table text,upstream_document_id uuid,upstream_document_legacy_id int,
 upstream_item_id uuid,upstream_item_legacy_id int,source_seller_legacy_id int,resolved_owner_employee_id uuid);
CREATE TEMP TABLE sales_upstream_owner_groups (
 target_table text,target_id uuid,target_legacy_id int,owner_count bigint,
 owner_employee_id uuid,resolved_owner_ids uuid[]);

INSERT INTO sales_upstream_owner_refs
SELECT 'sales_shipments',shipment.id,shipment.legacy_id,si.id,(to_jsonb(si)->>'legacy_id')::int,
 'ORDER_ITEM','sales_orders',o.id,o.legacy_id,oi.id,(to_jsonb(oi)->>'legacy_id')::int,
 o.seller_legacy_id,o.owner_employee_id
FROM sales_shipment_items si
JOIN sales_shipments shipment ON shipment.id=si.shipment_id
JOIN sales_order_items oi ON oi.id=si.order_item_id
JOIN sales_orders o ON o.id=oi.order_id
WHERE COALESCE(si.is_deleted,false)=false AND COALESCE(oi.is_deleted,false)=false
 AND COALESCE(o.is_deleted,false)=false;

INSERT INTO sales_upstream_owner_groups
SELECT target_table,target_id,target_legacy_id,count(DISTINCT resolved_owner_employee_id),
 CASE WHEN count(DISTINCT resolved_owner_employee_id)>1
      THEN (SELECT employee_id FROM sales_owner_custodian)
      ELSE min(resolved_owner_employee_id::text)::uuid END,
 array_agg(DISTINCT resolved_owner_employee_id ORDER BY resolved_owner_employee_id)
   FILTER (WHERE resolved_owner_employee_id IS NOT NULL)
FROM sales_upstream_owner_refs WHERE target_table='sales_shipments'
GROUP BY target_table,target_id,target_legacy_id HAVING count(DISTINCT resolved_owner_employee_id)>0;
UPDATE sales_shipments shipment SET owner_employee_id=source.owner_employee_id
FROM sales_upstream_owner_groups source
WHERE source.target_table='sales_shipments' AND shipment.id=source.target_id
 AND shipment.owner_employee_id IS DISTINCT FROM source.owner_employee_id;

-- Return relationships see the final shipment responsibility, including a
-- mixed-source shipment's explicit custody, and the direct order relationship.
INSERT INTO sales_upstream_owner_refs
SELECT 'sales_returns',r.id,r.legacy_id,(to_jsonb(ri)->>'id')::uuid,(to_jsonb(ri)->>'legacy_id')::int,
 'SHIPMENT_ITEM','sales_shipments',shipment.id,shipment.legacy_id,si.id,(to_jsonb(si)->>'legacy_id')::int,
 shipment.seller_legacy_id,shipment.owner_employee_id
FROM sales_return_items ri JOIN sales_returns r ON r.id=ri.return_id
JOIN sales_shipment_items si ON si.id=ri.out_item_id
JOIN sales_shipments shipment ON shipment.id=si.shipment_id
WHERE COALESCE(ri.is_deleted,false)=false AND COALESCE(si.is_deleted,false)=false
 AND COALESCE(shipment.is_deleted,false)=false
UNION ALL
SELECT 'sales_returns',r.id,r.legacy_id,(to_jsonb(ri)->>'id')::uuid,(to_jsonb(ri)->>'legacy_id')::int,
 'ORDER_ITEM','sales_orders',o.id,o.legacy_id,oi.id,(to_jsonb(oi)->>'legacy_id')::int,
 o.seller_legacy_id,o.owner_employee_id
FROM sales_return_items ri JOIN sales_returns r ON r.id=ri.return_id
JOIN sales_order_items oi ON oi.id=ri.order_item_id
JOIN sales_orders o ON o.id=oi.order_id
WHERE COALESCE(ri.is_deleted,false)=false AND COALESCE(oi.is_deleted,false)=false
 AND COALESCE(o.is_deleted,false)=false;

INSERT INTO sales_upstream_owner_groups
SELECT target_table,target_id,target_legacy_id,count(DISTINCT resolved_owner_employee_id),
 CASE WHEN count(DISTINCT resolved_owner_employee_id)>1
      THEN (SELECT employee_id FROM sales_owner_custodian)
      ELSE min(resolved_owner_employee_id::text)::uuid END,
 array_agg(DISTINCT resolved_owner_employee_id ORDER BY resolved_owner_employee_id)
   FILTER (WHERE resolved_owner_employee_id IS NOT NULL)
FROM sales_upstream_owner_refs WHERE target_table='sales_returns'
GROUP BY target_table,target_id,target_legacy_id HAVING count(DISTINCT resolved_owner_employee_id)>0;
UPDATE sales_returns r SET owner_employee_id=source.owner_employee_id
FROM sales_upstream_owner_groups source
WHERE source.target_table='sales_returns' AND r.id=source.target_id
 AND r.owner_employee_id IS DISTINCT FROM source.owner_employee_id;

CREATE TEMP TABLE sales_owner_conflict_records AS
SELECT g.target_table,g.target_id,g.target_legacy_id,
 jsonb_build_object('target_table',g.target_table,'target_id',g.target_id,'target_legacy_id',g.target_legacy_id,
   'reason','MIXED_UPSTREAM_OWNER_CUSTODY','assigned_employee_id',g.owner_employee_id,
   'resolved_owner_ids',to_jsonb(g.resolved_owner_ids),
   'upstream_references',(SELECT jsonb_agg(to_jsonb(ref) - 'target_table' - 'target_id' - 'target_legacy_id'
       ORDER BY ref.upstream_kind,ref.upstream_document_legacy_id,ref.upstream_item_legacy_id,ref.target_item_legacy_id,
                ref.upstream_document_id,ref.upstream_item_id,ref.target_item_id)
     FROM sales_upstream_owner_refs ref WHERE ref.target_table=g.target_table AND ref.target_id=g.target_id)) AS evidence
FROM sales_upstream_owner_groups g WHERE g.owner_count>1;

DO $$
DECLARE claim_id uuid;claim_ids uuid[];previous jsonb;objects jsonb;
BEGIN
 claim_id:=NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid;
 IF claim_id IS NULL THEN
  SELECT array_agg(run_id ORDER BY started_at) INTO claim_ids FROM legacy_migration_runs
  WHERE status='RUNNING' AND reconciliation_summary->>'targetDatabase'=current_database();
  IF cardinality(claim_ids)=1 THEN claim_id:=claim_ids[1]; END IF;
 END IF;
 SELECT reconciliation_summary#>'{salesOwnerConflicts,objects}' INTO previous
 FROM legacy_migration_runs WHERE run_id=claim_id AND status='RUNNING'
  AND reconciliation_summary->>'targetDatabase'=current_database() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Mixed sales owner custody requires its running import claim'; END IF;
 SELECT COALESCE(jsonb_agg(entry ORDER BY entry->>'target_table',(entry->>'target_legacy_id')::int,entry->>'target_id'),'[]'::jsonb)
 INTO objects FROM (
  SELECT DISTINCT ON (entry->>'target_table',entry->>'target_id') entry FROM (
   SELECT value AS entry,0 AS priority FROM jsonb_array_elements(COALESCE(previous,'[]'::jsonb))
   UNION ALL SELECT evidence,1 FROM sales_owner_conflict_records
  ) candidates ORDER BY entry->>'target_table',entry->>'target_id',priority DESC
 ) merged;
 UPDATE legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{salesOwnerConflicts}',
  jsonb_build_object('mappingVersion','mixed-upstream-owner-custody-v1',
    'helperSha256',current_setting('uten.legacy_custody_helper_sha',true),
    'objectCount',jsonb_array_length(objects),'objects',objects),true)
 WHERE run_id=claim_id;
END $$;

INSERT INTO pg_temp.legacy_owner_custody
SELECT source.target_table,source.id,source.legacy_id,
 COALESCE(source.seller_legacy_id::text,'upstream_document'),resolution.original_employee_id,source.owner_employee_id,
 CASE WHEN conflict.target_id IS NOT NULL THEN 'MIXED_UPSTREAM_OWNER_CUSTODY'
      WHEN resolution.reason IN ('PUBLIC_SOURCE','CURRENT_EMPLOYEE') THEN 'UPSTREAM_DOCUMENT_CUSTODY' ELSE resolution.reason END
FROM (
 SELECT 'sales_orders'::text AS target_table,id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_orders
 UNION ALL SELECT 'sales_shipments',id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_shipments
 UNION ALL SELECT 'sales_other_shipments',id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_other_shipments
 UNION ALL SELECT 'sales_returns',id,legacy_id,seller_legacy_id,owner_employee_id FROM sales_returns
) source
CROSS JOIN LATERAL pg_temp.legacy_owner_resolution(source.seller_legacy_id::text) resolution
LEFT JOIN sales_owner_conflict_records conflict ON conflict.target_table=source.target_table AND conflict.target_id=source.id
WHERE source.owner_employee_id=(SELECT employee_id FROM sales_owner_custodian)
ON CONFLICT(target_table,target_id) DO UPDATE SET target_legacy_id=EXCLUDED.target_legacy_id,
 source_reference=EXCLUDED.source_reference,original_employee_id=EXCLUDED.original_employee_id,
 assigned_employee_id=EXCLUDED.assigned_employee_id,reason=EXCLUDED.reason;


-- migrate_sales.sql refreshes before HR/owner backfill in --bootstrap-all.
-- Refresh again after ownership is final so V137 cannot leave aggregates in
-- the legacy-public sentinel bucket after their headers become owned.
REFRESH MATERIALIZED VIEW sales_monthly_mv;

-- ---------------- 校验 ----------------
SELECT r FROM (
    SELECT 1 AS ord, '✔ 订货 ' || count(*) AS r FROM sales_orders WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 2, '  出货 ' || count(*) FROM sales_shipments WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 3, '  其它出货 ' || count(*) FROM sales_other_shipments WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 4, '  退货 ' || count(*) FROM sales_returns WHERE owner_employee_id IS NOT NULL
    UNION ALL SELECT 5, '  非空历史seller仍无当前归属（应0） ' || (
        (SELECT count(*) FROM sales_orders WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL) +
        (SELECT count(*) FROM sales_shipments WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL) +
        (SELECT count(*) FROM sales_other_shipments WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL) +
        (SELECT count(*) FROM sales_returns WHERE seller_legacy_id IS NOT NULL AND seller_legacy_id<>0 AND owner_employee_id IS NULL))::text
    UNION ALL SELECT 6, '  归属员工数 ' || count(DISTINCT owner_employee_id)
        FROM sales_orders
    UNION ALL SELECT 7, '  MV owner buckets ' || count(DISTINCT owner_employee_id)
        FROM sales_monthly_mv
) t ORDER BY ord;
