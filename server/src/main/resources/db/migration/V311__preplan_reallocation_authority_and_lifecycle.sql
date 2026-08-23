-- V311: cross-analysis material reallocation command authority and lifecycle.
-- Physical stock stays in stock_reservations; this migration only hardens the
-- reallocation header and permits a priority-owned PREPLAN reservation source.

ALTER TABLE preplan_material_reallocations
    ADD COLUMN close_idempotency_key TEXT,
    ADD COLUMN close_request_hash TEXT,
    ADD CONSTRAINT preplan_reallocation_close_idem_chk CHECK (
        (
            status NOT IN ('REVERSED', 'CANCELLED')
            AND close_idempotency_key IS NULL
            AND close_request_hash IS NULL
        )
        OR
        (
            status IN ('REVERSED', 'CANCELLED')
            AND close_idempotency_key IS NOT NULL
            AND close_idempotency_key = btrim(close_idempotency_key)
            AND length(close_idempotency_key) BETWEEN 8 AND 128
            AND close_request_hash ~ '^[0-9a-f]{64}$'
        )
    );

CREATE UNIQUE INDEX uq_preplan_reallocation_close_idempotency
    ON preplan_material_reallocations(created_by, close_idempotency_key)
    WHERE close_idempotency_key IS NOT NULL;

ALTER TABLE stock_reservations
    DROP CONSTRAINT stock_reservations_owner_shape_chk;

ALTER TABLE stock_reservations
    ADD CONSTRAINT stock_reservations_owner_shape_chk CHECK (
        (
            owner_type = 'SALES_ORDER_ITEM'
            AND purpose = 'SALES_FULFILLMENT'
            AND order_item_id IS NOT NULL
            AND owner_id = order_item_id
            AND demand_id IS NULL
        )
        OR
        (
            owner_type = 'PRODUCTION_MATERIAL_DEMAND'
            AND purpose = 'PRODUCTION_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NOT NULL
            AND owner_id = demand_id
            AND warehouse_id IS NOT NULL
            AND supply_type = 'STOCK_BALANCE'
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'PREPLAN_ANALYSIS'
            AND purpose = 'PREPLAN_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN (
                'PURCHASE_REQUEST_ITEM',
                'SUBCONTRACT_APPLICATION_ITEM',
                'PRODUCTION_PLAN_ITEM',
                'MATERIAL_REALLOCATION_PRIORITY'
            )
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
    );

ALTER TABLE production_material_analysis_commands
    DROP CONSTRAINT production_material_analysis_command_operation_chk,
    ADD CONSTRAINT production_material_analysis_command_operation_chk CHECK (
        operation IN (
            'PREVIEW', 'ROUTE', 'REALLOCATE', 'NOTIFY', 'GENERATE_PLAN',
            'CANCEL_ANALYSIS', 'CANCEL_ACTION',
            'BORROW', 'BORROW_REVOKE',
            'CROSS_REALLOCATE', 'CROSS_REALLOCATE_REVOKE'
        )
    );

INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('production_material_analysis:cross_reallocate',
     '跨物料分析让料与优先补齐', '生产管理', '物料分析', 218)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- No second approval flow. The command still requires writable object scope on
-- both analyses; default authority is intentionally limited to GM and planning.
INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
CROSS JOIN permissions permission
WHERE department.code IN ('GM', 'SUB_PLAN')
  AND department.is_deleted = FALSE
  AND permission.code = 'production_material_analysis:cross_reallocate'
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION fn_guard_preplan_material_reallocation_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'preplan material reallocations cannot be deleted'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'OPEN'
           OR NEW.priority_fulfilled_qty <> 0
           OR NEW.lock_version <> 0
           OR NEW.closed_by IS NOT NULL
           OR NEW.close_idempotency_key IS NOT NULL THEN
            RAISE EXCEPTION 'preplan material reallocation must start OPEN'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.status IN ('REVERSED', 'CANCELLED') THEN
        RAISE EXCEPTION 'closed preplan material reallocation is immutable'
            USING ERRCODE = '55000';
    END IF;
    IF ROW(
        NEW.id, NEW.from_analysis_id, NEW.from_analysis_material_id,
        NEW.to_analysis_id, NEW.to_analysis_material_id,
        NEW.warehouse_id, NEW.goods_id, NEW.color_id, NEW.unit_id,
        NEW.qty, NEW.reason, NEW.idempotency_key, NEW.request_hash,
        NEW.source_version, NEW.source_fingerprint,
        NEW.target_version, NEW.target_fingerprint,
        NEW.created_by, NEW.created_at
    ) IS DISTINCT FROM ROW(
        OLD.id, OLD.from_analysis_id, OLD.from_analysis_material_id,
        OLD.to_analysis_id, OLD.to_analysis_material_id,
        OLD.warehouse_id, OLD.goods_id, OLD.color_id, OLD.unit_id,
        OLD.qty, OLD.reason, OLD.idempotency_key, OLD.request_hash,
        OLD.source_version, OLD.source_fingerprint,
        OLD.target_version, OLD.target_fingerprint,
        OLD.created_by, OLD.created_at
    ) THEN
        RAISE EXCEPTION 'preplan material reallocation identity is immutable'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.lock_version <> OLD.lock_version + 1 THEN
        RAISE EXCEPTION 'preplan material reallocation lock version must advance by one'
            USING ERRCODE = '40001';
    END IF;
    IF OLD.status IN ('PARTIAL', 'FULFILLED')
       AND NEW.status = 'REVERSED' THEN
        RAISE EXCEPTION 'fulfilled priority cannot be directly reversed'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_material_reallocation_mutation
    BEFORE INSERT OR UPDATE OR DELETE ON preplan_material_reallocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_material_reallocation_mutation();

CREATE TRIGGER trg_set_updated_at_preplan_material_reallocations
    BEFORE UPDATE ON preplan_material_reallocations
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE OR REPLACE FUNCTION fn_validate_preplan_material_reallocation_endpoints()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    bad UUID;
BEGIN
    SELECT reallocation.id
    INTO bad
    FROM preplan_material_reallocations reallocation
    LEFT JOIN production_material_analyses source_analysis
      ON source_analysis.id = reallocation.from_analysis_id
    LEFT JOIN production_material_analyses target_analysis
      ON target_analysis.id = reallocation.to_analysis_id
    LEFT JOIN production_material_analysis_materials source_material
      ON source_material.id = reallocation.from_analysis_material_id
     AND source_material.analysis_id = reallocation.from_analysis_id
    LEFT JOIN production_material_analysis_materials target_material
      ON target_material.id = reallocation.to_analysis_material_id
     AND target_material.analysis_id = reallocation.to_analysis_id
    WHERE reallocation.status IN ('OPEN', 'PARTIAL')
      AND (
          source_analysis.id IS NULL OR target_analysis.id IS NULL
          OR source_analysis.is_deleted IS DISTINCT FROM FALSE
          OR target_analysis.is_deleted IS DISTINCT FROM FALSE
          OR source_analysis.status NOT IN ('ACTIVE', 'PARTIALLY_PLANNED')
          OR target_analysis.status NOT IN ('ACTIVE', 'PARTIALLY_PLANNED')
          OR source_analysis.warehouse_id <> reallocation.warehouse_id
          OR target_analysis.warehouse_id <> reallocation.warehouse_id
          OR source_material.id IS NULL OR target_material.id IS NULL
          OR source_material.active IS DISTINCT FROM TRUE
          OR target_material.active IS DISTINCT FROM TRUE
          OR source_material.control_stage IN ('SHIP', 'REFERENCE')
          OR target_material.control_stage IN ('SHIP', 'REFERENCE')
          OR source_material.goods_id <> reallocation.goods_id
          OR target_material.goods_id <> reallocation.goods_id
          OR source_material.color_id IS DISTINCT FROM reallocation.color_id
          OR target_material.color_id IS DISTINCT FROM reallocation.color_id
          OR source_material.unit_id <> reallocation.unit_id
          OR target_material.unit_id <> reallocation.unit_id
      )
    ORDER BY reallocation.id
    LIMIT 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'active preplan material reallocation has invalid endpoints'
            USING ERRCODE = '55000';
    END IF;

    WITH endpoints AS (
        SELECT id, from_analysis_material_id AS material_id
        FROM preplan_material_reallocations
        WHERE status IN ('OPEN', 'PARTIAL')
        UNION ALL
        SELECT id, to_analysis_material_id
        FROM preplan_material_reallocations
        WHERE status IN ('OPEN', 'PARTIAL')
    )
    SELECT material_id
    INTO bad
    FROM endpoints
    GROUP BY material_id
    HAVING COUNT(*) > 1
    ORDER BY material_id
    LIMIT 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'a material node cannot participate in multiple open reallocations'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_preplan_material_reallocation
    AFTER INSERT OR UPDATE ON preplan_material_reallocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_material_reallocation_endpoints();

CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_material
    AFTER UPDATE OF analysis_id, analysis_item_id, goods_id, color_id,
        unit_id, control_stage, active
    ON production_material_analysis_materials
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_material_reallocation_endpoints();

CREATE CONSTRAINT TRIGGER trg_validate_preplan_reallocation_analysis
    AFTER UPDATE OF warehouse_id, status, is_deleted
    ON production_material_analyses
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_preplan_material_reallocation_endpoints();

COMMENT ON COLUMN preplan_material_reallocations.priority_fulfilled_qty IS
    '来源计划已由后续合格供给优先补齐的数量；不是欠款或还款金额';
