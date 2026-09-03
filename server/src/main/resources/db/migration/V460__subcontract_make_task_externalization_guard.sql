-- V460: V458 的 SUBCONTRACT_MAKE_TASK 外部化补上 V250 守卫三处联动。
-- V458 扩展了 preplan_supply_actions 的外部单据类型（SUBCONTRACT_MAKE_TASK，
-- 指向原分析内 SUBCONTRACT_MAKE 前置自制任务行），但漏改了 V250 的三道守卫：
-- route×type 组合 CHECK、action 外部化握手白名单、allocation 外部化 CASE。
-- 结果「下达委外（有子层）」在真库上被 fn_guard_preplan_supply_action_history
-- 以 "externalization handshake is invalid" 拒绝（单测为 focused stub 不落库，
-- 未覆盖触发器路径）。本迁移只放行 (route='SUBCONTRACT',
-- external_document_type='SUBCONTRACT_MAKE_TASK') 组合并要求 allocation
-- 指向同分析内真实 SUBCONTRACT_MAKE 行；其余守卫语义不变。

ALTER TABLE preplan_supply_actions
    DROP CONSTRAINT preplan_supply_action_route_external_v250_chk;

ALTER TABLE preplan_supply_actions
    ADD CONSTRAINT preplan_supply_action_route_external_v250_chk CHECK (
        (external_document_type IS NULL
            AND external_document_id IS NULL
            AND external_document_no IS NULL)
        OR
        (external_document_type IS NOT NULL
            AND external_document_id IS NOT NULL
            AND (
                (route = 'BUY'
                    AND external_document_type = 'PURCHASE_REQUEST')
                OR (route = 'SUBCONTRACT'
                    AND external_document_type =
                        'SUBCONTRACT_APPLICATION')
                OR (route = 'MAKE'
                    AND external_document_type =
                        'PREPLAN_MAKE_TASK')
                OR (route = 'SUBCONTRACT'
                    AND external_document_type =
                        'SUBCONTRACT_MAKE_TASK')
            ))
    );

CREATE OR REPLACE FUNCTION fn_guard_preplan_supply_action_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_externalized boolean;
BEGIN
    v_externalized := OLD.external_document_type IS NOT NULL
        OR OLD.external_document_id IS NOT NULL
        OR OLD.external_document_no IS NOT NULL
        OR EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            WHERE allocation.action_id = OLD.id
              AND allocation.external_item_id IS NOT NULL
        );

    IF NOT v_externalized THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        IF (NEW.external_document_type IS NOT NULL
            OR NEW.external_document_id IS NOT NULL
            OR NEW.external_document_no IS NOT NULL) THEN
            IF OLD.status <> 'OPEN'
               OR NEW.status <> 'CREATED'
               OR NEW.external_document_type IS NULL
               OR NEW.external_document_id IS NULL
               OR NOT (
                   (NEW.route = 'BUY'
                    AND NEW.external_document_type = 'PURCHASE_REQUEST')
                   OR (NEW.route = 'SUBCONTRACT'
                       AND NEW.external_document_type =
                           'SUBCONTRACT_APPLICATION')
                   OR (NEW.route = 'MAKE'
                       AND NEW.external_document_type =
                           'PREPLAN_MAKE_TASK')
                   OR (NEW.route = 'SUBCONTRACT'
                       AND NEW.external_document_type =
                           'SUBCONTRACT_MAKE_TASK')
               ) THEN
                RAISE EXCEPTION
                    'preplan action externalization handshake is invalid'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                            'preplan_external_supply_action_handshake_guard';
            END IF;
            IF OLD.id IS DISTINCT FROM NEW.id
                OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
                OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
                OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
                OR OLD.color_id IS DISTINCT FROM NEW.color_id
                OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
                OR OLD.need_date IS DISTINCT FROM NEW.need_date
                OR OLD.route IS DISTINCT FROM NEW.route
                OR OLD.requested_qty IS DISTINCT FROM NEW.requested_qty
                OR OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key
                OR OLD.action_group_key
                    IS DISTINCT FROM NEW.action_group_key
                OR OLD.request_business_key
                    IS DISTINCT FROM NEW.request_business_key
                OR OLD.generation IS DISTINCT FROM NEW.generation
                OR OLD.predecessor_action_id
                    IS DISTINCT FROM NEW.predecessor_action_id
                OR OLD.request_hash IS DISTINCT FROM NEW.request_hash
                OR OLD.created_by IS DISTINCT FROM NEW.created_by
                OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
                RAISE EXCEPTION
                    'preplan action identity cannot change while externalizing'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                            'preplan_external_supply_action_identity_guard';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'preplan external supply action history is append-only'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_append_only_guard';
    END IF;

    IF OLD.id IS DISTINCT FROM NEW.id
       OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
       OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
       OR OLD.color_id IS DISTINCT FROM NEW.color_id
       OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
       OR OLD.need_date IS DISTINCT FROM NEW.need_date
       OR OLD.route IS DISTINCT FROM NEW.route
       OR OLD.requested_qty IS DISTINCT FROM NEW.requested_qty
       OR OLD.external_document_type
            IS DISTINCT FROM NEW.external_document_type
       OR OLD.external_document_id
            IS DISTINCT FROM NEW.external_document_id
       OR OLD.external_document_no
            IS DISTINCT FROM NEW.external_document_no
       OR OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key
       OR OLD.action_group_key IS DISTINCT FROM NEW.action_group_key
       OR OLD.request_business_key
            IS DISTINCT FROM NEW.request_business_key
       OR OLD.generation IS DISTINCT FROM NEW.generation
       OR OLD.predecessor_action_id
            IS DISTINCT FROM NEW.predecessor_action_id
       OR OLD.request_hash IS DISTINCT FROM NEW.request_hash
       OR OLD.created_by IS DISTINCT FROM NEW.created_by
       OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION
            'preplan external supply action identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_identity_guard';
    END IF;

    IF OLD.status = 'CANCELLED'
       AND (NEW.status IS DISTINCT FROM 'CANCELLED'
            OR OLD.cancelled_by IS DISTINCT FROM NEW.cancelled_by
            OR OLD.cancelled_at IS DISTINCT FROM NEW.cancelled_at
            OR OLD.cancellation_reason
                IS DISTINCT FROM NEW.cancellation_reason) THEN
        RAISE EXCEPTION
            'cancelled preplan external supply action cannot be reactivated or rewritten'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_cancelled_guard';
    END IF;
    IF OLD.status IN ('IN_PROGRESS', 'DONE')
       AND NEW.status = 'CREATED' THEN
        RAISE EXCEPTION
            'advanced preplan external supply action cannot return to draft'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_status_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_preplan_supply_allocation_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_action preplan_supply_actions%ROWTYPE;
    v_external_item_valid boolean;
BEGIN
    IF OLD.external_item_id IS NULL THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        IF NEW.external_item_id IS NOT NULL
           AND (OLD.id IS DISTINCT FROM NEW.id
                OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
                OR OLD.action_id IS DISTINCT FROM NEW.action_id
                OR OLD.analysis_material_id
                    IS DISTINCT FROM NEW.analysis_material_id
                OR OLD.allocated_qty IS DISTINCT FROM NEW.allocated_qty
                OR OLD.created_at IS DISTINCT FROM NEW.created_at
                OR OLD.created_by IS DISTINCT FROM NEW.created_by) THEN
            RAISE EXCEPTION
                'preplan allocation identity cannot change while externalizing'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'preplan_external_supply_allocation_identity_guard';
        END IF;
        IF NEW.external_item_id IS NOT NULL THEN
            SELECT * INTO v_action
            FROM preplan_supply_actions action
            WHERE action.id = NEW.action_id
            FOR KEY SHARE;
            v_external_item_valid := CASE v_action.route
                WHEN 'BUY' THEN
                    v_action.status = 'CREATED'
                    AND v_action.external_document_type = 'PURCHASE_REQUEST'
                    AND EXISTS (
                        SELECT 1
                        FROM purchase_request_items item
                        WHERE item.id = NEW.external_item_id
                          AND item.request_id =
                              v_action.external_document_id
                          AND item.is_deleted = FALSE
                    )
                WHEN 'SUBCONTRACT' THEN
                    v_action.status = 'CREATED'
                    AND (
                        (v_action.external_document_type =
                             'SUBCONTRACT_APPLICATION'
                         AND EXISTS (
                             SELECT 1
                             FROM subcontract_application_items item
                             WHERE item.id = NEW.external_item_id
                               AND item.application_id =
                                   v_action.external_document_id
                               AND item.is_deleted = FALSE
                         ))
                        OR (v_action.external_document_type =
                                'SUBCONTRACT_MAKE_TASK'
                            AND v_action.external_document_id =
                                NEW.external_item_id
                            AND EXISTS (
                                SELECT 1
                                FROM production_material_analysis_items item
                                WHERE item.id = NEW.external_item_id
                                  AND item.analysis_id = NEW.analysis_id
                                  AND item.source_type = 'SUBCONTRACT_MAKE'
                                  AND item.is_deleted = FALSE
                            ))
                    )
                WHEN 'MAKE' THEN
                    v_action.status = 'CREATED'
                    AND v_action.external_document_type = 'PREPLAN_MAKE_TASK'
                    AND v_action.external_document_id =
                        NEW.external_item_id
                    AND EXISTS (
                        SELECT 1
                        FROM production_material_analysis_items item
                        WHERE item.id = NEW.external_item_id
                          AND item.analysis_id = NEW.analysis_id
                          AND item.source_type = 'MAKE_COMPONENT'
                          AND item.is_deleted = FALSE
                    )
                ELSE FALSE
            END;
            IF v_action.id IS NULL
               OR NOT COALESCE(v_external_item_valid, FALSE) THEN
                RAISE EXCEPTION
                    'preplan allocation externalization handshake is invalid'
                    USING ERRCODE = '23514',
                      CONSTRAINT =
                        'preplan_external_supply_allocation_handshake_guard';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'preplan external supply allocation history is append-only'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_allocation_append_only_guard';
    END IF;

    IF OLD.id IS DISTINCT FROM NEW.id
       OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR OLD.action_id IS DISTINCT FROM NEW.action_id
       OR OLD.analysis_material_id
            IS DISTINCT FROM NEW.analysis_material_id
       OR OLD.allocated_qty IS DISTINCT FROM NEW.allocated_qty
       OR OLD.external_item_id IS DISTINCT FROM NEW.external_item_id
       OR OLD.created_at IS DISTINCT FROM NEW.created_at
       OR OLD.created_by IS DISTINCT FROM NEW.created_by THEN
        RAISE EXCEPTION
            'preplan external supply allocation history is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_allocation_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;
