-- =====================================================================
-- 客户/供应商归属迁移：emp_id（老库 B_Worker.ID 文本）→ owner_employee_id
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --client-owner
-- 前提：clients/suppliers 已迁（emp_id 文本快照在库）；employees 有 legacy_id；V261 已应用。
-- 规则：只接受十进制正整数，且仅在 employees.legacy_id 唯一命中时补 UUID；禁止按姓名猜测。
-- 幂等：只补 owner_employee_id IS NULL 的历史行，不清空或覆盖用户已经维护的新 UUID 关系。
-- =====================================================================

BEGIN;

WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
)
UPDATE clients c
SET owner_employee_id = employee_owner.employee_id
FROM unique_employees employee_owner
WHERE c.owner_employee_id IS NULL
  AND employee_owner.legacy_id = CASE
      WHEN btrim(c.emp_id) ~ '^[0-9]{1,9}$'
          THEN NULLIF(btrim(c.emp_id)::int, 0)
      ELSE NULL
  END;

WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
)
UPDATE suppliers s
SET owner_employee_id = employee_owner.employee_id
FROM unique_employees employee_owner
WHERE s.owner_employee_id IS NULL
  AND employee_owner.legacy_id = CASE
      WHEN btrim(s.emp_id) ~ '^[0-9]{1,9}$'
          THEN NULLIF(btrim(s.emp_id)::int, 0)
      ELSE NULL
  END;

COMMIT;

-- ---------------- 校验 ----------------
SELECT r FROM (
    SELECT 1 AS ord, '✔ 有归属客户 ' || count(*) AS r FROM clients WHERE owner_employee_id IS NOT NULL
    UNION ALL
    SELECT 2, '  ' || e.full_name || ': ' || count(*)
    FROM clients c JOIN employees e ON e.id = c.owner_employee_id
    GROUP BY e.full_name
    UNION ALL
    SELECT 3, '  客户归属落空（数字 emp_id 对不上员工，保持公共） ' || count(*)
    FROM clients c
    WHERE btrim(c.emp_id) ~ '^[0-9]{1,9}$' AND btrim(c.emp_id)::int <> 0
      AND c.owner_employee_id IS NULL
    UNION ALL
    SELECT 4, '✔ 有归属供应商 ' || count(*) FROM suppliers WHERE owner_employee_id IS NOT NULL
    UNION ALL
    SELECT 5, '  供应商归属落空（数字 emp_id 对不上员工，保持公共） ' || count(*)
    FROM suppliers s
    WHERE btrim(s.emp_id) ~ '^[0-9]{1,9}$' AND btrim(s.emp_id)::int <> 0
      AND s.owner_employee_id IS NULL
) t ORDER BY ord, r;
