-- =====================================================================
-- V181：把老库悬空货品引用的占位 stub 从“当前运营 BOM”中隔离。
--
-- 业务单据/生产成本快照为满足 NOT NULL FK，会保留 goods.auto_created=true
-- 的历史引用锚；这些记录不是 B_Goods 主档。migrate_goods_bom.sql 旧实现只按
-- legacy_id JOIN，stub 先存在时会把原本应拒绝的 B_BomItem 孤儿行接入 BOM。
--
-- 安全边界：
--   * 只软删有 legacy_id 的迁移 BOM 行，保留审计和恢复能力；
--   * 对其已派生的当前草稿逐项证明“未流转且无下游”后再软删，异常即整体回滚；
--   * 不删除 goods stub，不破坏历史单据/成本快照外键；
--   * 若存在手工创建的 stub BOM（legacy_id IS NULL），拒绝迁移并要求人工核查。
-- 本机快照核对：81 行（组件端 stub 60、父端 stub 21、两端同时 stub 0）。
-- 另安全清理 2 条未领用 DRAW 明细和 1 张未下单 MRP 采购申请。
-- =====================================================================

UPDATE goods_bom_items bi
SET is_deleted = TRUE,
    deleted_at = COALESCE(bi.deleted_at, CURRENT_TIMESTAMP),
    updated_at = CURRENT_TIMESTAMP
FROM goods parent_goods, goods component_goods
WHERE parent_goods.id = bi.goods_id
  AND component_goods.id = bi.component_goods_id
  AND bi.legacy_id IS NOT NULL
  AND bi.is_deleted = FALSE
  AND (parent_goods.auto_created OR component_goods.auto_created);

-- 旧错误 BOM 已经派生出的“当前运营草稿”也要闭环清理。这里先抓取所有活动
-- DRAW 占位行；只有新系统生成、未审核、未领用、恰有一个生产计划来源且完全无
-- 下游事实时才允许软删。任何不满足安全条件的行都会让整项迁移回滚。
CREATE TEMP TABLE v181_draw_stub_targets ON COMMIT DROP AS
SELECT i.id AS item_id, d.id AS doc_id
FROM stock_document_items i
JOIN stock_documents d ON d.id = i.doc_id
JOIN goods g ON g.id = i.goods_id
WHERE i.is_deleted = FALSE
  AND d.is_deleted = FALSE
  AND d.doc_type = 'DRAW'
  AND g.auto_created = TRUE;

CREATE UNIQUE INDEX ON v181_draw_stub_targets(item_id);

DO $$
DECLARE
    v_doc UUID;
    v_expected BIGINT;
    v_actual BIGINT;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM v181_draw_stub_targets t
        JOIN stock_document_items i ON i.id = t.item_id
        JOIN stock_documents d ON d.id = t.doc_id
        WHERE d.status <> 0
           OR d.issue_status <> 0
           OR d.legacy_id IS NOT NULL
           OR i.legacy_id IS NOT NULL
           OR COALESCE(i.issued_qty, 0) <> 0
           OR i.upstream_item_id IS NOT NULL
           OR i.execution_segment_id IS NOT NULL
           OR i.execution_segment_sales_allocation_id IS NOT NULL
           OR (
               SELECT count(*)
               FROM plan_draw_links link
               WHERE link.draw_id = t.doc_id
                 AND link.is_deleted = FALSE
           ) <> 1
    ) THEN
        RAISE EXCEPTION 'V181 unsafe auto-created DRAW item state';
    END IF;

    -- 本迁移只移除错误明细，不静默删除整张领料单。
    IF EXISTS (
        SELECT 1
        FROM (SELECT DISTINCT doc_id FROM v181_draw_stub_targets) target_doc
        WHERE NOT EXISTS (
            SELECT 1
            FROM stock_document_items keep
            WHERE keep.doc_id = target_doc.doc_id
              AND keep.is_deleted = FALSE
              AND NOT EXISTS (
                  SELECT 1
                  FROM v181_draw_stub_targets target_item
                  WHERE target_item.item_id = keep.id
              )
        )
    ) THEN
        RAISE EXCEPTION 'V181 would empty a DRAW document';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM v181_draw_stub_targets t
        WHERE EXISTS (
                  SELECT 1
                  FROM production_planning_package_documents x
                  WHERE x.document_type = 'DRAW'
                    AND x.document_id = t.doc_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_planning_package_document_items x
                  WHERE x.document_type = 'DRAW'
                    AND (x.document_id = t.doc_id OR x.document_item_id = t.item_id))
           OR EXISTS (
                  SELECT 1
                  FROM production_material_receipt_allocations x
                  WHERE x.draw_id = t.doc_id OR x.draw_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_material_subcontract_receipt_allocations x
                  WHERE x.draw_id = t.doc_id OR x.draw_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_material_stock_postings x
                  WHERE x.stock_document_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_material_stock_events x
                  WHERE x.stock_document_id = t.doc_id)
           OR EXISTS (
                  SELECT 1
                  FROM stock_movements x
                  WHERE x.source_doc_id = t.doc_id OR x.source_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM stock_reservations x
                  WHERE x.source_doc_id = t.doc_id)
           OR EXISTS (
                  SELECT 1
                  FROM stock_document_items x
                  WHERE x.upstream_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM ar_ap_ledger x
                  WHERE x.source_doc_id = t.doc_id)
           OR EXISTS (
                  SELECT 1
                  FROM gl_entries x
                  WHERE x.source_doc_id = t.doc_id)
           OR EXISTS (
                  SELECT 1
                  FROM finance_reconciliations x
                  WHERE x.source_doc_id = t.doc_id)
           OR EXISTS (
                  SELECT 1
                  FROM business_outbox x
                  WHERE x.aggregate_id IN (t.doc_id, t.item_id))
    ) THEN
        RAISE EXCEPTION 'V181 DRAW item has downstream facts';
    END IF;

    -- V164 只允许逐张草稿、事务内授权的 false -> true 精确软删。
    FOR v_doc IN
        SELECT DISTINCT doc_id
        FROM v181_draw_stub_targets
        ORDER BY doc_id
    LOOP
        SELECT count(*)
        INTO v_expected
        FROM v181_draw_stub_targets
        WHERE doc_id = v_doc;

        PERFORM set_config(
            'app.production_stock_cleanup_doc_id', v_doc::text, TRUE);

        UPDATE stock_document_items i
        SET is_deleted = TRUE,
            updated_at = CURRENT_TIMESTAMP
        FROM v181_draw_stub_targets target
        WHERE target.doc_id = v_doc
          AND target.item_id = i.id
          AND i.doc_id = v_doc
          AND i.is_deleted = FALSE;

        GET DIAGNOSTICS v_actual = ROW_COUNT;
        IF v_actual <> v_expected THEN
            RAISE EXCEPTION 'V181 DRAW cleanup race for %', v_doc;
        END IF;
    END LOOP;

    PERFORM set_config('app.production_stock_cleanup_doc_id', '', TRUE);

    IF EXISTS (
        SELECT 1
        FROM stock_document_items i
        JOIN stock_documents d ON d.id = i.doc_id
        JOIN goods g ON g.id = i.goods_id
        WHERE i.is_deleted = FALSE
          AND d.is_deleted = FALSE
          AND d.doc_type = 'DRAW'
          AND g.auto_created = TRUE
    ) THEN
        RAISE EXCEPTION 'V181 active DRAW still uses auto-created goods';
    END IF;
END
$$;

-- MRP 采购申请同样只清理安全草稿：全单活动明细必须都是占位货品，且无下单、
-- 供给台账、计划包、财务或 Outbox 事实。顺序为明细 -> MRP 来源链接 -> 空单头。
CREATE TEMP TABLE v181_request_stub_targets ON COMMIT DROP AS
SELECT i.id AS item_id, request.id AS request_id
FROM purchase_request_items i
JOIN purchase_requests request ON request.id = i.request_id
JOIN goods g ON g.id = i.goods_id
WHERE i.is_deleted = FALSE
  AND request.is_deleted = FALSE
  AND g.auto_created = TRUE;

CREATE UNIQUE INDEX ON v181_request_stub_targets(item_id);

DO $$
DECLARE
    v_expected BIGINT;
    v_actual BIGINT;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM v181_request_stub_targets t
        JOIN purchase_request_items i ON i.id = t.item_id
        JOIN purchase_requests request ON request.id = t.request_id
        WHERE request.status <> 0
           OR request.is_closed
           OR request.is_stopped
           OR request.legacy_id IS NOT NULL
           OR i.legacy_id IS NOT NULL
           OR COALESCE(i.ordered_qty, 0) <> 0
           OR (
               SELECT count(*)
               FROM mrp_generations generation
               WHERE generation.request_id = t.request_id
                 AND generation.is_deleted = FALSE
           ) <> 1
    ) THEN
        RAISE EXCEPTION 'V181 unsafe auto-created purchase request state';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM (SELECT DISTINCT request_id FROM v181_request_stub_targets) target_request
        JOIN purchase_request_items keep
          ON keep.request_id = target_request.request_id
         AND keep.is_deleted = FALSE
        WHERE NOT EXISTS (
            SELECT 1
            FROM v181_request_stub_targets target_item
            WHERE target_item.item_id = keep.id
        )
    ) THEN
        RAISE EXCEPTION 'V181 purchase request also has real items';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM v181_request_stub_targets t
        WHERE EXISTS (
                  SELECT 1
                  FROM production_material_supply_pegs x
                  WHERE x.supply_type = 'PURCHASE_REQUEST_ITEM'
                    AND x.supply_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_material_peg_transfers x
                  WHERE x.request_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM purchase_order_items x
                  WHERE x.request_item_id = t.item_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_planning_packages x
                  WHERE x.purchase_request_id = t.request_id)
           OR EXISTS (
                  SELECT 1
                  FROM production_planning_package_documents x
                  WHERE x.document_type = 'PURCHASE_REQUEST'
                    AND x.document_id = t.request_id)
           OR EXISTS (
                  SELECT 1
                  FROM ar_ap_ledger x
                  WHERE x.source_doc_id = t.request_id)
           OR EXISTS (
                  SELECT 1
                  FROM gl_entries x
                  WHERE x.source_doc_id = t.request_id)
           OR EXISTS (
                  SELECT 1
                  FROM finance_reconciliations x
                  WHERE x.source_doc_id = t.request_id)
           OR EXISTS (
                  SELECT 1
                  FROM business_outbox x
                  WHERE x.aggregate_id IN (t.request_id, t.item_id))
    ) THEN
        RAISE EXCEPTION 'V181 purchase request has downstream facts';
    END IF;

    SELECT count(*) INTO v_expected FROM v181_request_stub_targets;

    UPDATE purchase_request_items i
    SET is_deleted = TRUE,
        updated_at = CURRENT_TIMESTAMP
    FROM v181_request_stub_targets target
    WHERE target.item_id = i.id
      AND i.request_id = target.request_id
      AND i.is_deleted = FALSE;

    GET DIAGNOSTICS v_actual = ROW_COUNT;
    IF v_actual <> v_expected THEN
        RAISE EXCEPTION 'V181 request-item cleanup race';
    END IF;

    SELECT count(DISTINCT request_id)
    INTO v_expected
    FROM v181_request_stub_targets;

    UPDATE mrp_generations generation
    SET is_deleted = TRUE,
        deleted_at = COALESCE(generation.deleted_at, CURRENT_TIMESTAMP)
    WHERE generation.is_deleted = FALSE
      AND EXISTS (
          SELECT 1
          FROM v181_request_stub_targets target
          WHERE target.request_id = generation.request_id
      );

    GET DIAGNOSTICS v_actual = ROW_COUNT;
    IF v_actual <> v_expected THEN
        RAISE EXCEPTION 'V181 MRP-link cleanup race';
    END IF;

    UPDATE purchase_requests request
    SET is_deleted = TRUE,
        deleted_at = COALESCE(request.deleted_at, CURRENT_TIMESTAMP),
        updated_at = CURRENT_TIMESTAMP
    WHERE request.is_deleted = FALSE
      AND EXISTS (
          SELECT 1
          FROM v181_request_stub_targets target
          WHERE target.request_id = request.id
      );

    GET DIAGNOSTICS v_actual = ROW_COUNT;
    IF v_actual <> v_expected THEN
        RAISE EXCEPTION 'V181 request-header cleanup race';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM v181_request_stub_targets t
        JOIN purchase_request_items i ON i.id = t.item_id
        JOIN purchase_requests request ON request.id = t.request_id
        WHERE i.is_deleted = FALSE
           OR request.is_deleted = FALSE
           OR EXISTS (
               SELECT 1
               FROM mrp_generations generation
               WHERE generation.request_id = t.request_id
                 AND generation.is_deleted = FALSE)
    ) THEN
        RAISE EXCEPTION 'V181 purchase cleanup postcondition failed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM purchase_request_items i
        JOIN purchase_requests request ON request.id = i.request_id
        JOIN goods g ON g.id = i.goods_id
        WHERE i.is_deleted = FALSE
          AND request.is_deleted = FALSE
          AND g.auto_created = TRUE
    ) THEN
        RAISE EXCEPTION 'V181 active purchase request still uses auto-created goods';
    END IF;
END
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM goods_bom_items bi
        JOIN goods parent_goods ON parent_goods.id = bi.goods_id
        JOIN goods component_goods ON component_goods.id = bi.component_goods_id
        WHERE bi.is_deleted = FALSE
          AND (parent_goods.auto_created OR component_goods.auto_created)
    ) THEN
        RAISE EXCEPTION
            'active BOM still references auto_created goods; manual rows require investigation';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION guard_goods_bom_operational_goods()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_deleted = FALSE AND EXISTS (
        SELECT 1
        FROM goods g
        WHERE g.id IN (NEW.goods_id, NEW.component_goods_id)
          AND (g.auto_created OR g.is_deleted)
    ) THEN
        RAISE EXCEPTION
            'active BOM parent/component must be a non-placeholder active goods record'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_goods_bom_operational_goods
ON goods_bom_items;

CREATE TRIGGER trg_goods_bom_operational_goods
BEFORE INSERT OR UPDATE OF goods_id, component_goods_id, is_deleted
ON goods_bom_items
FOR EACH ROW
EXECUTE FUNCTION guard_goods_bom_operational_goods();

COMMENT ON FUNCTION guard_goods_bom_operational_goods() IS
    '阻止迁移占位或已删除货品进入活动 BOM；软删历史行仍允许保留';

COMMENT ON COLUMN goods.auto_created IS
    '老库悬空引用的历史外键锚；不得进入当前货品选择、BOM 或 MRP（V181）';
