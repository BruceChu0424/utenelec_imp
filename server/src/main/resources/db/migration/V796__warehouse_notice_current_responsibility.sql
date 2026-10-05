-- Current responsibility controls both new delivery and already delivered cards.
-- No historical notices or responsible-person assignments are rewritten.
CREATE OR REPLACE FUNCTION fn_warehouse_keeper_user_ids(p_warehouse_ids uuid[])
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    WITH RECURSIVE lineage(id) AS (
        SELECT id FROM warehouses WHERE id=ANY(COALESCE(p_warehouse_ids,ARRAY[]::uuid[])) AND NOT is_deleted
        UNION
        SELECT parent.id FROM lineage child JOIN warehouses current ON current.id=child.id
        JOIN warehouses parent ON parent.id=current.parent_id AND NOT parent.is_deleted
    )
    SELECT COALESCE(array_agg(DISTINCT account.id ORDER BY account.id),ARRAY[]::uuid[])
    FROM warehouse_keepers keeper JOIN lineage ON lineage.id=keeper.warehouse_id
    JOIN employees employee ON employee.id=keeper.employee_id AND NOT employee.is_deleted AND employee.status<>'resigned'
    JOIN users account ON account.employee_id=employee.id AND NOT account.is_deleted AND account.status='active';
$$;

CREATE FUNCTION fn_warehouse_supervisor_user_ids() RETURNS UUID[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT account.id), ARRAY[]::uuid[])
    FROM users account JOIN employees employee ON employee.id=account.employee_id
    WHERE NOT account.is_deleted AND account.status='active'
      AND NOT employee.is_deleted AND employee.status<>'resigned'
      AND (account.is_super_admin OR EXISTS (
          SELECT 1 FROM warehouse_keepers keeper
          JOIN warehouses parent ON parent.id=keeper.warehouse_id AND NOT parent.is_deleted
          JOIN warehouses child ON child.parent_id=parent.id AND NOT child.is_deleted AND NOT child.is_line_side
          WHERE keeper.employee_id=employee.id));
$$;

CREATE FUNCTION fn_stock_document_matches_warehouse_scope(p_document uuid,p_ids text,p_unassigned boolean)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE ids uuid[]:=COALESCE(string_to_array(p_ids,',')::uuid[],ARRAY[]::uuid[]);
BEGIN
    RETURN EXISTS(SELECT 1 FROM stock_documents document WHERE document.id=p_document AND (
        (document.doc_type='TRANSFER' AND (document.warehouse_id=ANY(ids) OR document.to_warehouse_id=ANY(ids)))
        OR (document.doc_type<>'TRANSFER' AND NOT EXISTS (
            SELECT 1 FROM (
                SELECT COALESCE(item.warehouse_id,document.warehouse_id) AS warehouse_id
                FROM stock_document_items item WHERE item.doc_id=document.id AND NOT item.is_deleted
                UNION ALL SELECT document.warehouse_id WHERE NOT EXISTS (
                    SELECT 1 FROM stock_document_items item WHERE item.doc_id=document.id AND NOT item.is_deleted)
            ) actual WHERE (actual.warehouse_id IS NULL AND NOT p_unassigned)
                OR (actual.warehouse_id IS NOT NULL AND NOT actual.warehouse_id=ANY(ids))
        ))));
END;
$$;

CREATE FUNCTION fn_notice_warehouse_visible(p_user uuid,p_event text,p_kind text,p_id uuid,p_route text,p_permissions text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    warehouses uuid[];
    source_id uuid := p_id;
    route_id uuid;
    workshop_id uuid;
    permissions text[] := string_to_array(COALESCE(p_permissions,''), ',');
    required text[];
    route text := COALESCE(p_route,'');
    event text := COALESCE(p_event,'');
    choose_allowed boolean := false;
BEGIN
    -- Shared business events also notify finance, buyers, and production. Only
    -- their warehouse route is subject to warehouse responsibility.
    IF event IN ('PROCUREMENT_FINANCE_APPROVED','PROCUREMENT_IQC_RESOLVED',
                 'SUBCONTRACT_OUTBOUND_COMPLETED','SUBCONTRACT_OUTBOUND_REVERSED',
                 'PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED') AND route NOT LIKE '/warehouse/%' THEN RETURN true; END IF;
    CASE event
        WHEN 'PRODUCTION_FINISHED_INBOUND_PENDING' THEN required:=ARRAY['stock_doc:approve'];
        WHEN 'PRODUCTION_FINISHED_ARRIVAL_PENDING' THEN required:=ARRAY['stock_doc:view','stock_doc:approve'];
        WHEN 'PRODUCTION_DRAW_PENDING','PRODUCTION_MATERIAL_DISCOVERY_PENDING' THEN required:=ARRAY['stock_doc:view','stock_doc:approve','stock_doc:issue'];
        WHEN 'PROCUREMENT_IQC_STOCK_IN_PENDING','PROCUREMENT_IQC_RESOLVED' THEN required:=ARRAY['warehouse_iqc_stock_in:view'];
        WHEN 'SALES_SHIPMENT_PENDING_PICK','SALES_SHIPMENT_FINANCE_RELEASE_REVOKED' THEN required:=ARRAY['warehouse_sales_outbound:execute'];
        WHEN 'SUBCONTRACT_OUTBOUND_READY' THEN required:=ARRAY['subcontract_outbound:view','subcontract_outbound:execute'];
        WHEN 'SUBCONTRACT_OUTBOUND_COMPLETED','SUBCONTRACT_OUTBOUND_REVERSED','PROCUREMENT_FINANCE_APPROVED' THEN required:=ARRAY['warehouse_inbound:view'];
        WHEN 'PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED' THEN required:=ARRAY['warehouse_inbound:stock_in'];
        WHEN 'STOCK_COUNT_PENDING_WAREHOUSE_REVIEW' THEN required:=ARRAY['stock:count:warehouse_review'];
        WHEN 'WORKSHOP_MATERIAL_REQUISITION_PENDING','WORKSHOP_MATERIAL_RETURN_PENDING' THEN required:=ARRAY['workshop_material:issue'];
        WHEN 'WORKSHOP_MATERIAL_CLOSE_FAILING' THEN required:=ARRAY['workshop_material:setup'];
        WHEN 'WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK' THEN
            required:=ARRAY['workshop_material:issue'];
            choose_allowed:='workshop_material:choose'=ANY(permissions);
        ELSE RETURN true;
    END CASE;
    IF NOT 'notice:read'=ANY(permissions) OR (NOT required<@permissions AND NOT choose_allowed) THEN RETURN false; END IF;
    IF NOT EXISTS(SELECT 1 FROM users u JOIN employees e ON e.id=u.employee_id
                  WHERE u.id=p_user AND NOT u.is_deleted AND u.status='active'
                    AND NOT e.is_deleted AND e.status<>'resigned') THEN RETURN false; END IF;
    -- Old cards with a concrete detail route can be checked against that actual
    -- object. Unanchored generic routes never become access to another warehouse.
    route_id := substring(route FROM '/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:[?]|$)')::uuid;
    IF source_id IS NULL AND event IN ('PRODUCTION_FINISHED_INBOUND_PENDING','PRODUCTION_DRAW_PENDING',
            'SALES_SHIPMENT_PENDING_PICK','SALES_SHIPMENT_FINANCE_RELEASE_REVOKED','PROCUREMENT_IQC_RESOLVED') THEN source_id:=route_id; END IF;
    CASE event
        WHEN 'PRODUCTION_FINISHED_INBOUND_PENDING','PRODUCTION_DRAW_PENDING' THEN
            SELECT array_agg(DISTINCT COALESCE(item.warehouse_id,document.warehouse_id)) INTO warehouses
            FROM stock_documents document LEFT JOIN stock_document_items item ON item.doc_id=document.id AND NOT item.is_deleted
            WHERE document.id=source_id;
        WHEN 'PRODUCTION_FINISHED_ARRIVAL_PENDING' THEN
            SELECT array_agg(DISTINCT goods.owning_warehouse_id) INTO warehouses
            FROM v_production_report_items_pending_registration pending
            JOIN production_daily_report_items item ON item.id=pending.report_item_id
            JOIN goods ON goods.id=item.goods_id WHERE pending.report_id=source_id;
        WHEN 'PRODUCTION_MATERIAL_DISCOVERY_PENDING' THEN
            SELECT array_agg(package.warehouse_id) INTO warehouses FROM production_material_discovery_requests request
            JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
            JOIN production_planning_packages package ON package.id=segment.package_id WHERE request.id=source_id;
        WHEN 'PROCUREMENT_IQC_STOCK_IN_PENDING' THEN
            SELECT array_agg(inspection.warehouse_id) INTO warehouses FROM procurement_inspection_events pass
            JOIN procurement_inspection_items inspection ON inspection.id=pass.inspection_item_id WHERE pass.id=source_id;
        WHEN 'PROCUREMENT_IQC_RESOLVED' THEN
            SELECT array_agg(DISTINCT warehouse) INTO warehouses FROM (
                SELECT warehouse_id AS warehouse FROM procurement_inspection_items WHERE receipt_id=source_id
                  AND receipt_type=CASE WHEN route LIKE '%/SUBCONTRACT/%' THEN 'SUBCONTRACT' ELSE 'PURCHASE' END AND status<>'REVERSED'
                UNION SELECT pre_stocked_warehouse_id FROM procurement_inspection_items WHERE receipt_id=source_id
                  AND receipt_type=CASE WHEN route LIKE '%/SUBCONTRACT/%' THEN 'SUBCONTRACT' ELSE 'PURCHASE' END AND status<>'REVERSED'
                  AND pre_stocked_warehouse_id IS NOT NULL
            ) receipt_warehouses;
        WHEN 'SALES_SHIPMENT_PENDING_PICK','SALES_SHIPMENT_FINANCE_RELEASE_REVOKED' THEN
            SELECT array_agg(DISTINCT warehouse) INTO warehouses FROM (
                SELECT COALESCE(item.warehouse_id,shipment.warehouse_id) AS warehouse FROM sales_shipments shipment
                LEFT JOIN sales_shipment_items item ON item.shipment_id=shipment.id AND NOT item.is_deleted
                WHERE shipment.id=source_id
            ) shipment_warehouses;
        WHEN 'SUBCONTRACT_OUTBOUND_READY' THEN
            SELECT array_agg(DISTINCT warehouse) INTO warehouses FROM (
                SELECT item.preparation_warehouse_id AS warehouse FROM subcontract_material_plan_items item
                WHERE item.plan_id=COALESCE((SELECT plan_id FROM subcontract_material_plan_items WHERE id=source_id),route_id)
                  AND NOT item.is_deleted AND (item.preparation_warehouse_id IS NOT NULL OR NOT EXISTS (
                      SELECT 1 FROM subcontract_material_issue_items detail JOIN subcontract_material_issues draft ON draft.id=detail.issue_id
                      WHERE detail.plan_item_id=item.id AND NOT detail.is_deleted AND draft.status=0 AND NOT draft.is_deleted))
                UNION SELECT issue.warehouse_id FROM subcontract_material_issue_items detail
                JOIN subcontract_material_issues issue ON issue.id=detail.issue_id
                JOIN subcontract_material_plan_items item ON item.id=detail.plan_item_id
                WHERE item.plan_id=COALESCE((SELECT plan_id FROM subcontract_material_plan_items WHERE id=source_id),route_id)
                  AND NOT item.is_deleted AND NOT detail.is_deleted AND issue.status=0 AND NOT issue.is_deleted
            ) outbound_warehouses;
        WHEN 'SUBCONTRACT_OUTBOUND_COMPLETED','SUBCONTRACT_OUTBOUND_REVERSED' THEN
            SELECT array_agg(warehouse_id) INTO warehouses FROM subcontract_orders
            WHERE id=source_id AND p_kind='SUBCONTRACT_ORDER';
        WHEN 'PROCUREMENT_FINANCE_APPROVED' THEN
            SELECT array_agg(DISTINCT warehouse_id) INTO warehouses FROM inbound_expectations
            WHERE order_id=source_id AND order_type='PURCHASE';
        WHEN 'PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED' THEN
            SELECT array_agg(warehouse_id) INTO warehouses FROM procurement_arrival_exceptions WHERE id=source_id;
        WHEN 'STOCK_COUNT_PENDING_WAREHOUSE_REVIEW' THEN
            SELECT array_agg(warehouse_id) INTO warehouses FROM stock_count_requests WHERE id=source_id AND review_route='WAREHOUSE';
        WHEN 'WORKSHOP_MATERIAL_REQUISITION_PENDING','WORKSHOP_MATERIAL_RETURN_PENDING' THEN
            SELECT array_agg(DISTINCT suggested_leaf_warehouse_id) INTO warehouses
            FROM workshop_material_requisition_lines WHERE requisition_id=source_id;
        WHEN 'WORKSHOP_MATERIAL_CLOSE_FAILING','WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK' THEN
            workshop_id:=substring(route FROM '[?&]workshopId=([0-9a-fA-F-]{36})(?:&|$)')::uuid;
            SELECT array_agg(periodic_bin_warehouse_id) INTO warehouses FROM workshop_material_settings WHERE workshop_department_id=workshop_id;
            IF choose_allowed AND workshop_id IS NOT NULL AND EXISTS (
                WITH RECURSIVE tree(id) AS (
                    SELECT workshop_id UNION SELECT d.id FROM departments d JOIN tree p ON d.parent_id=p.id WHERE NOT d.is_deleted
                ) SELECT 1 FROM users u JOIN employees e ON e.id=u.employee_id
                WHERE u.id=p_user AND (e.department_id IN (SELECT id FROM tree)
                    OR EXISTS(SELECT 1 FROM employee_secondary_departments s WHERE s.employee_id=e.id AND s.department_id IN(SELECT id FROM tree))
                    OR EXISTS(SELECT 1 FROM departments d WHERE d.manager_id=e.id AND d.id IN(SELECT id FROM tree)))
            ) THEN RETURN true; END IF;
        ELSE RETURN false;
    END CASE;
    IF warehouses IS NULL OR cardinality(warehouses)=0 OR NOT required<@permissions THEN RETURN false; END IF;
    IF event IN ('SALES_SHIPMENT_PENDING_PICK','SALES_SHIPMENT_FINANCE_RELEASE_REVOKED','SUBCONTRACT_OUTBOUND_READY',
                 'PRODUCTION_FINISHED_INBOUND_PENDING','PRODUCTION_DRAW_PENDING',
                 'WORKSHOP_MATERIAL_REQUISITION_PENDING','WORKSHOP_MATERIAL_RETURN_PENDING') THEN
        RETURN NOT EXISTS(SELECT 1 FROM unnest(warehouses) warehouse WHERE
            (warehouse IS NULL AND NOT p_user=ANY(fn_warehouse_supervisor_user_ids()))
            OR (warehouse IS NOT NULL AND NOT p_user=ANY(fn_warehouse_keeper_user_ids(ARRAY[warehouse]))));
    END IF;
    RETURN p_user=ANY(fn_warehouse_keeper_user_ids(array_remove(warehouses,NULL)))
        OR (array_position(warehouses,NULL) IS NOT NULL AND p_user=ANY(fn_warehouse_supervisor_user_ids()));
END;
$$;
