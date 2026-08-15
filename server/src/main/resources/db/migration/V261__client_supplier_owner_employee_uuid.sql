-- 客户/供应商业务员关系统一为 employees.id；emp_id 仅保留老库融合值。
ALTER TABLE suppliers ADD COLUMN owner_employee_id UUID;

-- 只按 B_Worker.ID -> employees.legacy_id 的已确认同命名空间回填；不按姓名猜测。
WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
), refs AS (
    SELECT c.id AS master_id, e.employee_id
    FROM clients c
    JOIN unique_employees e
      ON e.legacy_id = CASE
          WHEN btrim(c.emp_id) ~ '^[0-9]{1,9}$' THEN NULLIF(btrim(c.emp_id)::int, 0)
          ELSE NULL
      END
    WHERE c.owner_employee_id IS NULL
)
UPDATE clients c
SET owner_employee_id = refs.employee_id
FROM refs
WHERE c.id = refs.master_id;

WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
), refs AS (
    SELECT s.id AS master_id, e.employee_id
    FROM suppliers s
    JOIN unique_employees e
      ON e.legacy_id = CASE
          WHEN btrim(s.emp_id) ~ '^[0-9]{1,9}$' THEN NULLIF(btrim(s.emp_id)::int, 0)
          ELSE NULL
      END
)
UPDATE suppliers s
SET owner_employee_id = refs.employee_id
FROM refs
WHERE s.id = refs.master_id;

CREATE INDEX idx_suppliers_owner_employee_id
    ON suppliers(owner_employee_id) WHERE owner_employee_id IS NOT NULL;

ALTER TABLE suppliers
    ADD CONSTRAINT fk_suppliers_owner_employee
        FOREIGN KEY (owner_employee_id) REFERENCES employees(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE suppliers VALIDATE CONSTRAINT fk_suppliers_owner_employee;

COMMENT ON COLUMN clients.owner_employee_id IS
    '业务员 UUID 真源 -> employees.id；emp_id 仅为旧库 B_Worker.ID 兼容快照';
COMMENT ON COLUMN suppliers.owner_employee_id IS
    '业务员 UUID 真源 -> employees.id；emp_id 仅为旧库 B_Worker.ID 兼容快照';
