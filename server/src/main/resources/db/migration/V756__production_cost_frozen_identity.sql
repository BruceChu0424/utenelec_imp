-- Capture identities only for new facts. Existing history is deliberately NOT backfilled from today's masters.
ALTER TABLE stock_movements ADD COLUMN cost_identity_snapshot JSONB;
ALTER TABLE stock_value_nodes ADD COLUMN origin_identity_snapshot JSONB;

CREATE FUNCTION fn_cost_original_document_identity(p_type TEXT,p_item UUID,p_goods UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE source_table TEXT; item JSONB;
BEGIN
    source_table:=CASE p_type WHEN 'STOCK_DOC' THEN 'stock_document_items'
        WHEN 'PURCHASE_RECEIPT' THEN 'purchase_receipt_items' WHEN 'PURCHASE_RETURN' THEN 'purchase_return_items'
        WHEN 'SUBCONTRACT_RECEIPT' THEN 'subcontract_receipt_items' WHEN 'SUBCONTRACT_RETURN' THEN 'subcontract_return_items'
        WHEN 'SALES_SHIPMENT' THEN 'sales_shipment_items' WHEN 'SALES_RETURN' THEN 'sales_return_items' END;
    IF source_table IS NULL OR p_item IS NULL OR to_regclass('public.'||source_table) IS NULL THEN RETURN NULL; END IF;
    EXECUTE format('SELECT to_jsonb(item) FROM %I item WHERE id=$1 AND goods_id=$2',source_table) INTO item USING p_item,p_goods;
    IF item IS NULL OR item->>'goods_snapshot_locked_at' IS NULL
       OR COALESCE(item->>'goods_snapshot_source','') LIKE 'BACKFILL%'
       OR NULLIF(item->>'goods_snapshot_source','') IS NULL THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('goodsId',p_goods,'goodsCode',item->>'goods_code_snapshot','goodsName',item->>'goods_name_snapshot',
        'unitId',CASE WHEN COALESCE((item->>'unit_rate')::numeric,0)=1 THEN item->>'unit_id' END,
        'unitName',NULL,'state','MISSING','source','ORIGINAL_DOCUMENT_PARTIAL');
END;
$$;

-- This helper is called by insert triggers only, at the new source/physical posting boundary.
CREATE FUNCTION fn_cost_identity_at_posting(p_goods UUID,p_type TEXT,p_item UUID,p_source TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE original JSONB; captured JSONB;
BEGIN
    original:=fn_cost_original_document_identity(p_type,p_item,p_goods);
    SELECT jsonb_build_object('goodsId',g.id,'goodsCode',COALESCE(original->>'goodsCode',g.code),
        'goodsName',COALESCE(original->>'goodsName',g.name),'unitId',g.unit_id,'unitName',u.name,
        'state',CASE WHEN g.unit_id IS NOT NULL AND u.name IS NOT NULL AND g.code IS NOT NULL AND g.name IS NOT NULL
                     THEN 'COMPLETE' ELSE 'MISSING' END,
        'source',p_source,'capturedAt',statement_timestamp())
      INTO captured FROM goods g LEFT JOIN units u ON u.id=g.unit_id WHERE g.id=p_goods;
    RETURN COALESCE(captured,jsonb_build_object('goodsId',p_goods,'state','MISSING','source',p_source));
END;
$$;

CREATE FUNCTION fn_capture_cost_movement_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        NEW.cost_identity_snapshot:=fn_cost_identity_at_posting(NEW.goods_id,NEW.source_doc_type,NEW.source_item_id,'PHYSICAL_POSTING');
    ELSIF NEW.cost_identity_snapshot IS DISTINCT FROM OLD.cost_identity_snapshot THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='原实物过账身份快照不可改写或补成当前主档';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER stock_movement_cost_identity_insert BEFORE INSERT ON stock_movements
FOR EACH ROW EXECUTE FUNCTION fn_capture_cost_movement_identity();
CREATE TRIGGER stock_movement_cost_identity_immutable BEFORE UPDATE OF cost_identity_snapshot ON stock_movements
FOR EACH ROW EXECUTE FUNCTION fn_capture_cost_movement_identity();

CREATE FUNCTION fn_capture_cost_value_source_identity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE goods UUID;
BEGIN
    IF TG_OP='INSERT' THEN
        NEW.origin_identity_snapshot:=NULL;
        IF NEW.kind='SOURCE' THEN
            SELECT goods_id INTO goods FROM stock_value_pools WHERE id=NEW.pool_id;
            NEW.origin_identity_snapshot:=fn_cost_identity_at_posting(goods,NULL,NULL,'VALUE_SOURCE_ACQUISITION');
        END IF;
    ELSIF NEW.origin_identity_snapshot IS DISTINCT FROM OLD.origin_identity_snapshot THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='原价值取得身份快照不可改写或补成当前主档';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER stock_value_source_identity_insert BEFORE INSERT ON stock_value_nodes
FOR EACH ROW EXECUTE FUNCTION fn_capture_cost_value_source_identity();
CREATE TRIGGER stock_value_source_identity_immutable BEFORE UPDATE OF origin_identity_snapshot ON stock_value_nodes
FOR EACH ROW EXECUTE FUNCTION fn_capture_cost_value_source_identity();

-- Follow immutable custody/value lineage, stopping at each first physical or acquisition source.
-- No master-table lookup is permitted on this history-reading path. Ambiguous or absent evidence stays missing.
CREATE FUNCTION fn_production_cost_input_identity(p_node UUID,p_posting UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE expected_goods UUID; candidates JSONB; identities JSONB; visited_count INTEGER; unresolved BOOLEAN; original_item UUID; partial_identity JSONB;
BEGIN
    SELECT p.goods_id INTO expected_goods FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE n.id=p_node;
    WITH RECURSIVE walk AS (
        SELECT n.id,0 depth,ARRAY[n.id] visited,
            (m.id IS NOT NULL OR n.kind='SOURCE') terminal,
            CASE WHEN m.id IS NOT NULL THEN COALESCE(m.cost_identity_snapshot,
                    fn_cost_original_document_identity(m.source_doc_type,m.source_item_id,m.goods_id))
                 ELSE n.origin_identity_snapshot END identity
        FROM stock_value_nodes n LEFT JOIN stock_movements m ON m.id=n.movement_id WHERE n.id=p_node
        UNION ALL
        SELECT parent.id,walk.depth+1,walk.visited||parent.id,
            (m.id IS NOT NULL OR parent.kind='SOURCE'),
            CASE WHEN m.id IS NOT NULL THEN COALESCE(m.cost_identity_snapshot,
                    fn_cost_original_document_identity(m.source_doc_type,m.source_item_id,m.goods_id))
                 ELSE parent.origin_identity_snapshot END
        FROM walk CROSS JOIN LATERAL (
            SELECT t.source_root_id parent_id FROM stock_value_position_transfers t WHERE t.target_node_id=walk.id
            UNION SELECT e.parent_node_id FROM stock_value_edges e WHERE e.child_node_id=walk.id AND e.interval_to>e.interval_from
        ) edge JOIN stock_value_nodes parent ON parent.id=edge.parent_id
        JOIN stock_value_pools pool ON pool.id=parent.pool_id AND pool.goods_id=expected_goods
        LEFT JOIN stock_movements m ON m.id=parent.movement_id
        WHERE NOT walk.terminal AND walk.depth<64 AND NOT parent.id=ANY(walk.visited)
    ), bounded AS MATERIALIZED (SELECT * FROM walk LIMIT 2049), leaves AS (
        SELECT * FROM bounded node WHERE node.terminal OR node.depth=64
            OR NOT EXISTS(SELECT 1 FROM bounded child WHERE child.depth=node.depth+1 AND child.visited[child.depth]=node.id)
    )
    SELECT (SELECT count(*) FROM bounded),COALESCE(bool_or(identity IS NULL OR identity->>'state'<>'COMPLETE' OR NOT terminal),true),
        jsonb_agg(DISTINCT jsonb_build_object('goodsId',expected_goods,'goodsCode',identity->>'goodsCode',
            'goodsName',identity->>'goodsName','unitId',identity->>'unitId','unitName',identity->>'unitName')),
        jsonb_agg(DISTINCT id ORDER BY id)
      INTO visited_count,unresolved,identities,candidates FROM leaves;
    IF visited_count>2048 THEN RETURN jsonb_build_object('goodsId',expected_goods,'state','LIMIT','source','ORIGINAL_VALUE_LINEAGE'); END IF;
    IF identities IS NULL OR jsonb_array_length(identities)=0 THEN
        RETURN jsonb_build_object('goodsId',expected_goods,'state','MISSING','source','ORIGINAL_VALUE_LINEAGE');
    END IF;
    IF jsonb_array_length(identities)>1 THEN
        RETURN jsonb_build_object('goodsId',expected_goods,'state','CONFLICT','source','ORIGINAL_VALUE_LINEAGE','sourceNodes',candidates);
    END IF;
    IF (identities->0)->>'goodsCode' IS NULL AND p_posting IS NOT NULL
       AND to_regclass('public.production_material_stock_postings') IS NOT NULL THEN
        EXECUTE 'SELECT p.stock_document_item_id FROM production_material_stock_postings p
                 JOIN stock_value_production_cost_inputs i ON i.approved_posting_id=p.id
                 WHERE p.id=$1 AND i.input_node_id=$2 AND i.input_kind IN (''CONSUMED'',''NORMAL_LOSS'')'
            INTO original_item USING p_posting,p_node;
        partial_identity:=fn_cost_original_document_identity('STOCK_DOC',original_item,expected_goods);
        IF partial_identity IS NOT NULL THEN identities:=jsonb_build_array(partial_identity);unresolved:=true;END IF;
    END IF;
    RETURN identities->0 || jsonb_build_object('state',CASE WHEN unresolved THEN 'MISSING' ELSE 'COMPLETE' END,
        'source','ORIGINAL_VALUE_LINEAGE','sourceNodes',candidates);
END;
$$;

COMMENT ON COLUMN stock_movements.cost_identity_snapshot IS 'V756起新实物过账时冻结的货品与基本单位身份；旧行NULL不回填当前资料';
COMMENT ON COLUMN stock_value_nodes.origin_identity_snapshot IS 'V756起新价值取得来源的身份；派生节点沿原价值/保管链读取，不重取主档';

-- Coverage follows actual physical/value business dates, not finance-approved but unshipped document headers.
-- A FINAL zero-cost node is covered; an unpriced zero delta is pending even without a stock_value_postings row.
CREATE OR REPLACE VIEW v_stock_actual_sales_cost_coverage AS
SELECT item.id shipment_item_id,item.shipment_id,shipment.client_id,item.goods_id,
       (movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date business_date,
       bool_or(event.id IS NULL OR node.id IS NULL OR node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0) pending
FROM stock_movements movement JOIN sales_shipment_items item ON item.id=movement.source_item_id
JOIN sales_shipments shipment ON shipment.id=item.shipment_id
LEFT JOIN stock_value_events event ON event.movement_id=movement.id
LEFT JOIN stock_value_nodes node ON node.id=event.result_node_id
WHERE movement.source_doc_type='SALES_SHIPMENT' AND movement.movement_type IN(3,20)
GROUP BY item.id,item.shipment_id,shipment.client_id,item.goods_id,(movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date
UNION ALL
SELECT item.id,item.shipment_id,shipment.client_id,item.goods_id,
       (event.occurred_at AT TIME ZONE 'Asia/Shanghai')::date,
       (node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0)
FROM stock_value_position_transfers transfer
JOIN stock_value_events event ON event.id=transfer.event_id
JOIN stock_value_nodes node ON (node.id=transfer.source_root_id OR node.id=transfer.target_node_id) AND node.owner_kind='COGS'
JOIN sales_shipment_items item ON item.id=node.owner_id
JOIN sales_shipments shipment ON shipment.id=item.shipment_id;
