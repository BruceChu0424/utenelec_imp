-- =====================================================================
-- 客户归属迁移：clients.emp_id（老库 B_Worker.ID 文本）→ owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --client-owner
-- 前提：clients 已迁（emp_id 文本在库）；employees 有 legacy_id（stub 或 HR 真员工）；V86 已应用。
-- 规则：emp_id 非空且能对齐 employees.legacy_id → 归属；'0'/空/对不上的（老库已删员工，
--   如 508/528/462/503/504/129/460 共 13 个客户）→ 公共（NULL），在校验输出计数备查。
-- 幂等：先全量清零再灌入；HR 真员工替换 stub 后 legacy_id 不变，归属不断链。
-- =====================================================================

BEGIN;

UPDATE clients SET owner_employee_id = NULL WHERE owner_employee_id IS NOT NULL;

UPDATE clients c
SET owner_employee_id = e.id
FROM employees e
WHERE c.emp_id IS NOT NULL AND BTRIM(c.emp_id) <> '' AND BTRIM(c.emp_id) <> '0'
  AND e.legacy_id = CAST(BTRIM(c.emp_id) AS int);

COMMIT;

-- ---------------- 校验 ----------------
SELECT r FROM (
    SELECT 1 AS ord, '✔ 有归属客户 ' || count(*) AS r FROM clients WHERE owner_employee_id IS NOT NULL
    UNION ALL
    SELECT 2, '  ' || e.full_name || ': ' || count(*)
    FROM clients c JOIN employees e ON e.id = c.owner_employee_id
    GROUP BY e.full_name
    UNION ALL
    SELECT 3, '  归属落空（老库 emp_id 对不上员工，转公共） ' || count(*)
    FROM clients c
    WHERE c.emp_id IS NOT NULL AND BTRIM(c.emp_id) <> '' AND BTRIM(c.emp_id) <> '0'
      AND c.owner_employee_id IS NULL
) t ORDER BY ord, r;
