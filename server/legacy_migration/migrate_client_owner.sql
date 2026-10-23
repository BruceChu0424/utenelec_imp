-- =====================================================================
-- 客户/供应商归属迁移：emp_id（老库 B_Worker.ID 文本）→ owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --client-owner
-- 前提：clients/suppliers 已迁（emp_id 文本快照在库）；employees 有 legacy_id；V261 已应用。
-- 只按精确旧ID映射真正当前员工；旧人离职/缺失/未知非空引用由 ADMIN 临时托管，不转公共。
-- 保留已维护的当前负责人，不按姓名猜测；既有无归属公共资料仍保持公共。
-- =====================================================================


CREATE TEMP TABLE master_owner_resolution AS
SELECT source.*,r.owner_id,r.original_employee_id,r.reason
FROM (
 SELECT 'clients'::text AS target_table,c.id,c.legacy_id,c.owner_employee_id AS previous_owner,
 CASE WHEN c.owner_employee_id IS NOT NULL AND (NULLIF(btrim(c.emp_id),'') IS NULL OR btrim(c.emp_id) ~ '^0+$')
      THEN 'employee_uuid:'||c.owner_employee_id::text ELSE c.emp_id END AS source_reference
 FROM clients c WHERE c.owner_employee_id IS NULL OR NOT EXISTS (
  SELECT 1 FROM employees e WHERE e.id=c.owner_employee_id AND NOT e.is_deleted AND e.status IN ('active','probation','onLeave'))
 UNION ALL
 SELECT 'suppliers',s.id,s.legacy_id,s.owner_employee_id,
 CASE WHEN s.owner_employee_id IS NOT NULL AND (NULLIF(btrim(s.emp_id),'') IS NULL OR btrim(s.emp_id) ~ '^0+$')
      THEN 'employee_uuid:'||s.owner_employee_id::text ELSE s.emp_id END
 FROM suppliers s WHERE s.owner_employee_id IS NULL OR NOT EXISTS (
  SELECT 1 FROM employees e WHERE e.id=s.owner_employee_id AND NOT e.is_deleted AND e.status IN ('active','probation','onLeave'))
) source CROSS JOIN LATERAL pg_temp.legacy_owner_resolution(source.source_reference) r;
UPDATE clients c SET owner_employee_id=r.owner_id FROM master_owner_resolution r
WHERE r.target_table='clients' AND c.id=r.id AND c.owner_employee_id IS DISTINCT FROM r.owner_id;
UPDATE suppliers s SET owner_employee_id=r.owner_id FROM master_owner_resolution r
WHERE r.target_table='suppliers' AND s.id=r.id AND s.owner_employee_id IS DISTINCT FROM r.owner_id;
INSERT INTO pg_temp.legacy_owner_custody
SELECT target_table,id,legacy_id,source_reference,COALESCE(original_employee_id,previous_owner),owner_id,reason
FROM master_owner_resolution WHERE reason NOT IN ('PUBLIC_SOURCE','CURRENT_EMPLOYEE');


-- ---------------- 校验 ----------------
SELECT r FROM (
    SELECT 1 AS ord, '✔ 有归属客户 ' || count(*) AS r FROM clients WHERE owner_employee_id IS NOT NULL
    UNION ALL
    SELECT 2, '  ' || e.full_name || ': ' || count(*)
    FROM clients c JOIN employees e ON e.id = c.owner_employee_id
    GROUP BY e.full_name
    UNION ALL
    SELECT 3, '  客户非空来源归属仍落空（应0） ' || count(*)
    FROM clients c
    WHERE btrim(c.emp_id) ~ '^[0-9]{1,9}$' AND btrim(c.emp_id)::int <> 0
      AND c.owner_employee_id IS NULL
    UNION ALL
    SELECT 4, '✔ 有归属供应商 ' || count(*) FROM suppliers WHERE owner_employee_id IS NOT NULL
    UNION ALL
    SELECT 5, '  供应商非空来源归属仍落空（应0） ' || count(*)
    FROM suppliers s
    WHERE btrim(s.emp_id) ~ '^[0-9]{1,9}$' AND btrim(s.emp_id)::int <> 0
      AND s.owner_employee_id IS NULL
) t ORDER BY ord, r;
