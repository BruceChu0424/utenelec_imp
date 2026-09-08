-- V436 target plans store quantities in the goods basic unit. The old INSERT
-- accidentally placed the order conversion factor in unit_rate rather than
-- bom_unit_qty. Correct only the exact pattern with no physical execution.
-- Never rewrite issued/consumed quantities or historical stock movements.
CREATE TEMP TABLE subcontract_basis_unexecuted_fix ON COMMIT DROP AS
SELECT pi.id, g.unit_id AS base_unit_id, oi.unit_rate AS order_unit_rate
FROM subcontract_material_plan_items pi
JOIN subcontract_order_items oi ON oi.id=pi.order_item_id
JOIN goods g ON g.id=pi.goods_id
WHERE pi.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
  AND pi.is_deleted=FALSE AND oi.is_deleted=FALSE AND g.unit_id IS NOT NULL
  AND pi.unit_rate=oi.unit_rate AND pi.unit_rate<>1 AND pi.bom_unit_qty=1
  AND pi.issued_qty=0
  AND NOT EXISTS (
      SELECT 1 FROM subcontract_material_issue_items ii
      JOIN subcontract_material_issues issue ON issue.id=ii.issue_id
      WHERE ii.plan_item_id=pi.id AND (issue.status<>0
          OR ii.at_supplier_qty<>0 OR ii.consumed_qty<>0 OR ii.returned_qty<>0
          OR ii.wasted_qty<>0 OR ii.compensated_qty<>0))
  AND NOT EXISTS (
      SELECT 1 FROM subcontract_receipt_items ri
      JOIN subcontract_receipts receipt ON receipt.id=ri.receipt_id
      WHERE ri.order_item_id=oi.id AND receipt.status<>0);

UPDATE subcontract_material_plan_items pi
SET unit_id=fix.base_unit_id,unit_rate=1,bom_unit_qty=fix.order_unit_rate,updated_at=now()
FROM subcontract_basis_unexecuted_fix fix WHERE fix.id=pi.id;

UPDATE subcontract_material_issue_items ii
SET unit_id=fix.base_unit_id,unit_rate=1,updated_at=now()
FROM subcontract_basis_unexecuted_fix fix,subcontract_material_issues issue
WHERE ii.plan_item_id=fix.id AND issue.id=ii.issue_id AND issue.status=0;

-- Execute queued source/quantity checks before adding a trigger to the changed
-- plan table. This validates the correction; it does not disable any guard.
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

-- A read-only remediation list. Already executed inconsistent rows stay visible
-- with their original UUIDs and numbers, including reversed/deleted history.
CREATE VIEW v_subcontract_quantity_basis_issues AS
SELECT pi.id AS plan_item_id,pi.order_item_id,pi.plan_id,pi.flow_mode,
       pi.unit_id,pi.unit_rate,pi.bom_unit_qty,g.unit_id AS expected_unit_id,
       oi.unit_rate AS expected_bom_unit_qty,
       (pi.unit_id IS DISTINCT FROM g.unit_id OR pi.unit_rate<>1
         OR pi.bom_unit_qty<>oi.unit_rate) AS plan_basis_inconsistent,
       EXISTS (
           SELECT 1 FROM subcontract_material_issue_items ii
           JOIN subcontract_material_issues issue ON issue.id=ii.issue_id
           WHERE ii.plan_item_id=pi.id AND issue.status=1 AND issue.is_deleted=FALSE
             AND ii.is_deleted=FALSE
             AND (ii.unit_id IS DISTINCT FROM g.unit_id OR ii.unit_rate<>1
                 OR ii.frozen_unit_qty IS DISTINCT FROM oi.unit_rate)
       ) AS effective_issue_basis_inconsistent
FROM subcontract_material_plan_items pi
JOIN subcontract_order_items oi ON oi.id=pi.order_item_id
JOIN goods g ON g.id=pi.goods_id
WHERE pi.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
  AND (pi.unit_id IS DISTINCT FROM g.unit_id OR pi.unit_rate<>1 OR pi.bom_unit_qty<>oi.unit_rate
    OR EXISTS (
        SELECT 1 FROM subcontract_material_issue_items ii
        JOIN subcontract_material_issues issue ON issue.id=ii.issue_id
        WHERE ii.plan_item_id=pi.id AND issue.status=1 AND issue.is_deleted=FALSE AND ii.is_deleted=FALSE
          AND (ii.unit_id IS DISTINCT FROM g.unit_id OR ii.unit_rate<>1
              OR ii.frozen_unit_qty IS DISTINCT FROM oi.unit_rate)));

COMMENT ON VIEW v_subcontract_quantity_basis_issues IS
    'V502委外基本量/父件换算率差异。已执行历史不自动更改，继续出回仓前须核对原单与实物并走对应反向。';

CREATE FUNCTION fn_guard_subcontract_target_quantity_basis_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.flow_mode='LEGACY_BOM_COMPONENT' THEN RETURN NEW; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM subcontract_order_items oi JOIN goods g ON g.id=oi.goods_id
        WHERE oi.id=NEW.order_item_id AND NEW.goods_id=oi.goods_id
          AND NEW.unit_id=g.unit_id AND NEW.unit_rate=1 AND NEW.bom_unit_qty=oi.unit_rate
    ) THEN
        RAISE EXCEPTION 'target outbound requires basic unit quantities and frozen order conversion'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_quantity_basis_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_target_quantity_basis_insert
BEFORE INSERT ON subcontract_material_plan_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_target_quantity_basis_insert();
