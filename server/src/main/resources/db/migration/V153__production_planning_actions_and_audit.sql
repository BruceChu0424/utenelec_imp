-- V153: actionable plan-package documents and audit coverage.

ALTER TABLE production_planning_package_documents
    DROP CONSTRAINT production_planning_package_document_type_chk,
    ADD CONSTRAINT production_planning_package_document_type_chk
        CHECK (document_type IN ('SUBPLAN', 'PURCHASE_REQUEST', 'DRAW'));

CREATE TABLE production_planning_package_document_items (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    package_id        UUID NOT NULL
        REFERENCES production_planning_packages(id) ON DELETE CASCADE,
    demand_id         UUID NOT NULL
        REFERENCES production_material_demands(id) ON DELETE CASCADE,
    document_type     TEXT NOT NULL,
    document_id       UUID NOT NULL,
    document_item_id  UUID NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    CONSTRAINT production_planning_package_document_item_type_chk
        CHECK (document_type IN ('DRAW'))
);

CREATE UNIQUE INDEX uq_production_planning_package_document_item
    ON production_planning_package_document_items(
        package_id, demand_id, document_type, document_item_id);
CREATE UNIQUE INDEX uq_production_planning_package_owned_document_item
    ON production_planning_package_document_items(
        document_type, document_item_id);

CREATE TRIGGER trg_audit_production_planning_package_document_items
    AFTER INSERT OR UPDATE OR DELETE
    ON production_planning_package_document_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_production_planning_packages
    ON production_planning_packages;
CREATE TRIGGER trg_audit_production_planning_packages
    AFTER INSERT OR UPDATE OR DELETE ON production_planning_packages
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_production_planning_package_documents
    ON production_planning_package_documents;
CREATE TRIGGER trg_audit_production_planning_package_documents
    AFTER INSERT OR UPDATE OR DELETE ON production_planning_package_documents
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_production_material_demands
    ON production_material_demands;
CREATE TRIGGER trg_audit_production_material_demands
    AFTER INSERT OR UPDATE OR DELETE ON production_material_demands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_production_material_supply_pegs
    ON production_material_supply_pegs;
CREATE TRIGGER trg_audit_production_material_supply_pegs
    AFTER INSERT OR UPDATE OR DELETE ON production_material_supply_pegs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_production_stock_reservations
    ON stock_reservations;
CREATE TRIGGER trg_audit_production_stock_reservations
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE VIEW v_fulfillment_workbench_actions AS
SELECT w.*,
       action.document_type AS action_doc_type,
       action.document_id AS action_doc_id,
       action.document_no AS action_doc_no,
       action_item.action_item_id,
       CASE action.document_type
           WHEN 'DRAW' THEN sd.status::text
           WHEN 'PURCHASE_REQUEST' THEN pr.status::text
           ELSE NULL
       END AS action_doc_status
FROM v_fulfillment_workbench w
LEFT JOIN LATERAL (
    SELECT d.document_type, d.document_id, d.document_no
    FROM production_planning_package_documents d
    WHERE d.package_id = w.package_id
      AND (
          (w.department = 'WAREHOUSE' AND d.document_type = 'DRAW')
          OR
          (w.department = 'PURCHASE' AND d.document_type = 'PURCHASE_REQUEST')
      )
    ORDER BY d.created_at DESC, d.id
    LIMIT 1
) action ON TRUE
LEFT JOIN LATERAL (
    SELECT di.document_item_id AS action_item_id
    FROM production_planning_package_document_items di
    WHERE action.document_type = 'DRAW'
      AND di.package_id = w.package_id
      AND di.demand_id = w.task_id
      AND di.document_id = action.document_id
    UNION ALL
    SELECT p.supply_item_id
    FROM production_material_supply_pegs p
    WHERE action.document_type = 'PURCHASE_REQUEST'
      AND p.demand_id = w.task_id
      AND p.supply_type = 'PURCHASE_REQUEST_ITEM'
      AND p.status <> 'REVERSED'
    LIMIT 1
) action_item ON TRUE
LEFT JOIN stock_documents sd
  ON action.document_type = 'DRAW'
 AND sd.id = action.document_id
LEFT JOIN purchase_requests pr
  ON action.document_type = 'PURCHASE_REQUEST'
 AND pr.id = action.document_id;

COMMENT ON VIEW v_fulfillment_workbench_actions IS
    'Fulfillment tasks with real actionable downstream document identity and status.';
