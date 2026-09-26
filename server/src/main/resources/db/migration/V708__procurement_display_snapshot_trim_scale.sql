-- V691 的 display 快照里 weight/giftQty/allowedLossPct 直接取 NUMERIC(18,4) 列的
-- jsonb 文本，天然带四位尾随零("2.7500")；同一函数里 sources 分配量当时已用
-- trim_scale。2026-09-24 全站数值展示统一去尾随零口径(ExactDecimalText 序列化器
-- 同步 strip)，此处对齐：只重建函数体，既有触发器自动改用新定义。
-- 存量 case 的 display_snapshot 不可变(触发器禁 UPDATE)，保留提交时原样；
-- 新 case 起全部干净。displayVersion 升 2 标记文本格式变化。
CREATE OR REPLACE FUNCTION fn_procurement_approval_display_snapshot()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    order_table TEXT;
    item_table TEXT;
    source_table TEXT;
    source_item_table TEXT;
    source_document_table TEXT;
    source_item_column TEXT;
    source_document_column TEXT;
    frozen JSONB;
    matched_items INTEGER;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.display_snapshot IS DISTINCT FROM OLD.display_snapshot THEN
            RAISE EXCEPTION 'Submitted procurement display snapshot is immutable' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.order_type = 'PURCHASE' THEN
        order_table := 'purchase_orders'; item_table := 'purchase_order_items';
        source_table := 'purchase_order_item_sources'; source_item_table := 'purchase_request_items';
        source_document_table := 'purchase_requests'; source_item_column := 'request_item_id';
        source_document_column := 'request_id';
    ELSIF NEW.order_type = 'SUBCONTRACT' THEN
        order_table := 'subcontract_orders'; item_table := 'subcontract_order_items';
        source_table := 'subcontract_order_item_sources'; source_item_table := 'subcontract_application_items';
        source_document_table := 'subcontract_applications'; source_item_column := 'application_item_id';
        source_document_column := 'application_id';
    ELSE
        RAISE EXCEPTION 'Unknown procurement order type' USING ERRCODE = '23514';
    END IF;

    IF jsonb_typeof(NEW.submission_snapshot -> 'items') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Procurement submitted item snapshot is required' USING ERRCODE = '23514';
    END IF;
    IF jsonb_typeof(NEW.submission_snapshot -> 'items') = 'array' THEN
        EXECUTE format('SELECT count(DISTINCT item.id) FROM jsonb_array_elements($1) submitted(value)
            JOIN %I item ON item.id = CAST(submitted.value ->> ''itemId'' AS uuid)
            AND item.order_id = $2 AND NOT item.is_deleted', item_table)
            INTO matched_items USING NEW.submission_snapshot -> 'items', NEW.order_id;
        IF matched_items IS DISTINCT FROM jsonb_array_length(NEW.submission_snapshot -> 'items') THEN
            RAISE EXCEPTION 'Procurement display snapshot item identity differs from submitted snapshot' USING ERRCODE = '23514';
        END IF;
    END IF;

    -- Both initial submission and approved-order quantity reconfirmation insert
    -- a case in the locked order transaction. The trigger covers both paths and
    -- cannot be bypassed by forgetting an application-side snapshot call.
    EXECUTE format($sql$
        SELECT ($1 - 'items') || jsonb_build_object(
            'displayVersion', 2,
            'supplierName', supplier.name, 'supplierCode', supplier.code,
            'warehouseName', warehouse.name, 'currencyName', currency.name,
            'settlementMethodName', settlement.name,
            'purchaserName', purchaser.full_name, 'makerName', maker.full_name,
            'remark', head.remark,
            'items', COALESCE((
                SELECT jsonb_agg(submitted.value || jsonb_build_object(
                    'goodsCode', COALESCE(NULLIF(item.goods_code_snapshot, ''), goods.code),
                    'goodsName', COALESCE(NULLIF(item.goods_name_snapshot, ''), goods.name),
                    'colorName', color.name, 'unitName', unit.name,
                    'weight', trim_scale(NULLIF(to_jsonb(item) ->> 'weight', '')::numeric)::text,
                    'giftQty', trim_scale(NULLIF(to_jsonb(item) ->> 'gift_qty', '')::numeric)::text,
                    'allowedLossPct', trim_scale(NULLIF(to_jsonb(item) ->> 'allowed_loss_pct', '')::numeric)::text,
                    'remark', item.remark, 'sourceDocNo', item.source_doc_no,
                    'sources', COALESCE(sources.rows, '[]'::jsonb),
                    'sourceApplicationNos', sources.labels
                ) ORDER BY item.line_no NULLS LAST, item.id)
                FROM jsonb_array_elements($1 -> 'items') submitted(value)
                JOIN %2$I item ON item.id = CAST(submitted.value ->> 'itemId' AS uuid)
                    AND item.order_id = $2 AND NOT item.is_deleted
                LEFT JOIN goods ON goods.id = CAST(submitted.value ->> 'goodsId' AS uuid)
                LEFT JOIN colors color ON color.id = CAST(submitted.value ->> 'colorId' AS uuid)
                LEFT JOIN units unit ON unit.id = CAST(submitted.value ->> 'unitId' AS uuid)
                LEFT JOIN LATERAL (
                    SELECT jsonb_agg(jsonb_build_object(
                               'sourceItemId', source.%6$I, 'quantity', trim_scale(source.alloc_qty)::text,
                               'documentNo', source_document.bill_no, 'lineNo', source_item.line_no
                           ) ORDER BY source.line_no, source.%6$I) AS rows,
                           string_agg(concat_ws(' · ', source_document.bill_no,
                               '第' || source_item.line_no || '行',
                               trim_scale(source.alloc_qty)::text), '；'
                               ORDER BY source.line_no, source.%6$I) AS labels
                    FROM %3$I source
                    JOIN %4$I source_item ON source_item.id = source.%6$I
                    LEFT JOIN %5$I source_document ON source_document.id = source_item.%7$I
                    WHERE source.order_item_id = item.id
                ) sources ON TRUE
                WHERE item.order_id = $2 AND NOT item.is_deleted
            ), '[]'::jsonb)
        )
        FROM %1$I head
        LEFT JOIN suppliers supplier ON supplier.id = head.supplier_id
        LEFT JOIN warehouses warehouse ON warehouse.id = head.warehouse_id
        LEFT JOIN currencies currency ON currency.id = head.currency_id
        LEFT JOIN settlement_methods settlement ON settlement.id = head.settlement_method_id
        LEFT JOIN employees purchaser ON purchaser.id = head.purchaser_id
        LEFT JOIN employees maker ON maker.id = head.maker_id
        WHERE head.id = $2
    $sql$, order_table, item_table, source_table, source_item_table,
        source_document_table, source_item_column, source_document_column)
    INTO frozen USING NEW.submission_snapshot, NEW.order_id;

    IF frozen IS NULL OR (jsonb_typeof(NEW.submission_snapshot -> 'items') = 'array' AND
        jsonb_array_length(frozen -> 'items') IS DISTINCT FROM jsonb_array_length(NEW.submission_snapshot -> 'items')) THEN
        RAISE EXCEPTION 'Procurement display snapshot cannot resolve every submitted row' USING ERRCODE = '23514';
    END IF;
    NEW.display_snapshot := frozen;
    RETURN NEW;
END
$function$;
