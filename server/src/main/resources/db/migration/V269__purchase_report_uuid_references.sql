-- Purchase report relationships use stable UUID identities. Legacy numeric
-- columns remain import snapshots and are consulted only when the UUID is null.

ALTER TABLE purchase_receipts
    ADD COLUMN purchaser_id UUID;

ALTER TABLE purchase_requests
    ADD COLUMN department_id UUID;

-- Install NOT VALID constraints before the backfill: PostgreSQL immediately
-- protects new/changed rows while allowing the historical bridge to run.
ALTER TABLE purchase_receipts
    ADD CONSTRAINT fk_purchase_receipts_purchaser
        FOREIGN KEY (purchaser_id) REFERENCES employees(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE purchase_requests
    ADD CONSTRAINT fk_purchase_requests_department
        FOREIGN KEY (department_id) REFERENCES departments(id)
        ON DELETE RESTRICT NOT VALID;

-- Validate while the new columns are still null. The constraints become fully
-- active before backfill; every bridged UUID below is then checked immediately.
-- This ordering also avoids PostgreSQL rejecting ALTER TABLE after audit
-- triggers have queued events in the same Flyway transaction.
ALTER TABLE purchase_receipts
    VALIDATE CONSTRAINT fk_purchase_receipts_purchaser;

ALTER TABLE purchase_requests
    VALIDATE CONSTRAINT fk_purchase_requests_department;

-- Build indexes before audit-triggered backfill events are queued. The UPDATEs
-- below maintain these indexes transactionally as UUIDs are populated.
CREATE INDEX idx_purchase_receipts_purchaser
    ON purchase_receipts(purchaser_id) WHERE purchaser_id IS NOT NULL;

CREATE INDEX idx_purchase_requests_department
    ON purchase_requests(department_id) WHERE department_id IS NOT NULL;

-- B_Worker.ID -> employees.legacy_id is a documented, unique namespace bridge.
-- Keep the uniqueness CTE explicit so the migration remains deterministic even
-- if an older database predates the partial unique index on employees.legacy_id.
WITH unique_employees AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS employee_id
    FROM employees
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
)
UPDATE purchase_receipts receipt
SET purchaser_id = employee.employee_id
FROM unique_employees employee
WHERE receipt.purchaser_id IS NULL
  AND receipt.purchaser_legacy_id IS NOT NULL
  AND receipt.purchaser_legacy_id <> 0
  AND employee.legacy_id = receipt.purchaser_legacy_id;

-- StepID -> legacy_departments is the old purchase-view namespace; V84 added
-- the reviewed bridge from that dictionary row to departments.id.
UPDATE purchase_requests request
SET department_id = legacy_department.department_id
FROM legacy_departments legacy_department
WHERE request.department_id IS NULL
  AND request.department_legacy_id IS NOT NULL
  AND request.department_legacy_id <> 0
  AND legacy_department.legacy_id = request.department_legacy_id
  AND legacy_department.department_id IS NOT NULL;

COMMENT ON COLUMN purchase_receipts.purchaser_id IS
    '采购员 UUID 真源 -> employees.id；purchaser_legacy_id 仅为老库 B_Worker.ID 快照';
COMMENT ON COLUMN purchase_requests.department_id IS
    '申请部门 UUID 真源 -> departments.id；department_legacy_id 仅为老库 StepID 快照';
