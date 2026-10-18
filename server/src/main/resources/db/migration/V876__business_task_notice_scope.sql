-- Action reminders use current business state and actual task responsibility.
-- No notice, permission, owner, quantity or audit history is rewritten.
-- The Java read scope is resolved once with TaskAudiencePort; read delegation never becomes write responsibility.
CREATE FUNCTION fn_notice_task_owner(p_scopes jsonb, p_scope text, p_owner uuid, p_write boolean)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_owner IS NOT NULL AND (COALESCE((p_scopes->p_scope->>'all')::boolean,FALSE)
        OR COALESCE(p_scopes->p_scope->CASE WHEN p_write THEN 'write' ELSE 'read' END,'[]'::jsonb) ? p_owner::text);
$$;

CREATE FUNCTION fn_notice_workshop_member(p_user uuid, p_workshop uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    WITH RECURSIVE tree(id) AS (
        SELECT id FROM departments WHERE id=p_workshop AND NOT is_deleted
        UNION SELECT child.id FROM departments child JOIN tree parent ON child.parent_id=parent.id WHERE NOT child.is_deleted
    ) SELECT EXISTS(SELECT 1 FROM users account JOIN employees employee ON employee.id=account.employee_id
        WHERE account.id=p_user AND NOT account.is_deleted AND account.status='active'
          AND NOT employee.is_deleted AND employee.status IN('active','probation','onLeave')
          AND (employee.department_id IN(SELECT id FROM tree)
            OR EXISTS(SELECT 1 FROM employee_secondary_departments secondary
                WHERE secondary.employee_id=employee.id AND secondary.department_id IN(SELECT id FROM tree))
            OR EXISTS(SELECT 1 FROM departments managed WHERE managed.manager_id=employee.id
                AND managed.id IN(SELECT id FROM tree))));
$$;

-- Same UUID.nameUUIDFromBytes(period + ':' + suffix) identity as WorkshopMaterialNoticeService.
CREATE FUNCTION fn_notice_workshop_period_key(p_period uuid,p_suffix text)
RETURNS uuid LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE value bytea:=decode(md5(p_period::text||':'||p_suffix),'hex');
BEGIN
    value:=set_byte(value,6,(get_byte(value,6)&15)|48);
    value:=set_byte(value,8,(get_byte(value,8)&63)|128);
    RETURN encode(value,'hex')::uuid;
END;
$$;

CREATE FUNCTION fn_notice_business_action_visible(
    p_user uuid,p_event text,p_kind text,p_id uuid,p_route text,
    p_permissions text,p_events text,p_catalog text,p_scopes text,p_warehouse_pools text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    permissions text[]:=COALESCE(string_to_array(p_permissions,','),ARRAY[]::text[]);
    events text[]:=COALESCE(string_to_array(p_events,','),ARRAY[]::text[]);
    scopes jsonb:=COALESCE(NULLIF(p_scopes,''),'{}')::jsonb;
    pools jsonb:=COALESCE(NULLIF(p_warehouse_pools,''),'{}')::jsonb;
    employee_id uuid;
    warehouses uuid[];
    pool uuid[];
    pending boolean:=false;
    expected_kind text;
    period record;
    suffix text;
    non_popup boolean:=p_event IN('PRODUCTION_FINISHED_INBOUND_PENDING','PRODUCTION_FINISHED_ARRIVAL_PENDING',
        'PROCUREMENT_IQC_PRE_STOCKED','PREPLAN_SUPPLY_ACTION_CREATED','PREPLAN_SUPPLY_DOCUMENT_CREATED',
        'SUBCONTRACT_OUTBOUND_COMPLETED','PROCUREMENT_SUPPLIER_RETURN_REQUIRED','PROCUREMENT_ARRIVAL_RECEIPT_POSTED',
        'PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED','RD_TASK_FORWARDED','SALES_QUOTE_FINANCE_RETURNED',
        'SALES_QUOTE_FINANCE_CONFIRMED','SALES_ORDER_FINANCE_REJECTED','PROCUREMENT_FINANCE_REJECTED',
        'PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED','SUBCONTRACT_LOSS_CLAIM_OPENED');
BEGIN
    -- Ordinary information, result receipts and human-authored notices retain their delivery audience.
    IF p_event IS NULL OR NOT p_event=ANY(COALESCE(string_to_array(p_catalog,','),ARRAY[]::text[])) THEN RETURN true; END IF;
    IF non_popup AND p_id IS NULL THEN
        p_id:=substring(COALESCE(p_route,'') FROM '/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:[?]|$)')::uuid;
    END IF;
    IF p_id IS NULL OR (p_kind IS NULL AND NOT non_popup) OR NOT p_event=ANY(events) OR NOT 'notice:read'=ANY(permissions) THEN RETURN false; END IF;
    SELECT employee.id INTO employee_id FROM users account JOIN employees employee ON employee.id=account.employee_id
      WHERE account.id=p_user AND NOT account.is_deleted AND account.status='active'
        AND NOT employee.is_deleted AND employee.status IN('active','probation','onLeave');
    IF employee_id IS NULL THEN RETURN false; END IF;
    CASE p_event
        WHEN 'PRODUCTION_FINISHED_INBOUND_PENDING' THEN
            expected_kind:='STOCK_DOCUMENT';
            SELECT ARRAY[document.warehouse_id] INTO warehouses FROM stock_documents document
              WHERE document.id=p_id AND document.status=0 AND NOT document.is_deleted AND document.doc_type='FINISHED_IN';
            pending:=warehouses IS NOT NULL;
        WHEN 'PRODUCTION_FINISHED_ARRIVAL_PENDING' THEN
            expected_kind:='PRODUCTION_DAILY_REPORT';
            SELECT array_agg(DISTINCT goods.owning_warehouse_id) INTO warehouses
              FROM v_production_report_items_pending_registration task
              JOIN production_daily_report_items item ON item.id=task.report_item_id JOIN goods ON goods.id=item.goods_id
              WHERE task.report_id=p_id;
            pending:=warehouses IS NOT NULL;
        WHEN 'PROCUREMENT_IQC_PRE_STOCKED' THEN
            expected_kind:='IQC_INSPECTION';
            pending:=EXISTS(SELECT 1 FROM procurement_inspection_items task WHERE task.receipt_id=p_id
                AND task.status IN('PENDING','PARTIAL') AND task.pre_stocked_at IS NOT NULL);
        WHEN 'PREPLAN_SUPPLY_ACTION_CREATED','PREPLAN_SUPPLY_DOCUMENT_CREATED' THEN
            expected_kind:='SUPPLY_APPLICATION';
            IF p_route LIKE '/purchase/requests/%' THEN
                pending:=ARRAY['purchase_request:view','purchase_order:create','purchase_order:decompose']<@permissions
                    AND EXISTS(SELECT 1 FROM v_procurement_decomposition_tasks task WHERE task.department='PURCHASE'
                        AND task.action_doc_id=p_id AND task.task_status='WAITING_ORDER' AND task.open_qty>0);
            ELSIF p_route LIKE '/subcontract/applications/%' THEN
                pending:=ARRAY['subcontract_application:view','subcontract_order:create','subcontract_order:decompose']<@permissions
                    AND EXISTS(SELECT 1 FROM v_procurement_decomposition_tasks task WHERE task.department='SUBCONTRACT'
                        AND task.action_doc_id=p_id AND task.task_status='WAITING_ORDER' AND task.open_qty>0);
            END IF;
        WHEN 'SUBCONTRACT_OUTBOUND_COMPLETED' THEN
            expected_kind:='SUBCONTRACT_ORDER';
            pending:=EXISTS(SELECT 1 FROM subcontract_orders document JOIN subcontract_order_items item ON item.order_id=document.id
                WHERE document.id=p_id AND document.status=1 AND NOT document.is_deleted AND NOT document.is_closed
                  AND NOT item.is_deleted AND fn_subcontract_returnable_qty(item.id)>COALESCE((
                    SELECT SUM(detail.qty) FROM subcontract_receipt_items detail JOIN subcontract_receipts receipt ON receipt.id=detail.receipt_id
                    WHERE detail.order_item_id=item.id AND NOT detail.is_deleted AND receipt.status=1 AND NOT receipt.is_deleted),0));
            warehouses:=fn_procurement_order_inbound_warehouse_ids('SUBCONTRACT',p_id);
        WHEN 'PROCUREMENT_SUPPLIER_RETURN_REQUIRED','PROCUREMENT_ARRIVAL_RECEIPT_POSTED' THEN
            expected_kind:='PROCUREMENT_ARRIVAL_EXCEPTION';
            pending:=EXISTS(SELECT 1 FROM supplier_return_tasks task WHERE task.arrival_exception_id=p_id AND task.status='PENDING_RETURN'
                AND (task.owner_user_id=p_user OR task.owner_employee_id=employee_id));
        WHEN 'PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED' THEN
            expected_kind:='PROCUREMENT_ARRIVAL_EXCEPTION';
            SELECT ARRAY[task.warehouse_id] INTO warehouses FROM procurement_arrival_exceptions task
              WHERE task.id=p_id AND task.status='RECEIPT_ADJUSTED' AND task.accepted_qty>0;
            pending:=warehouses IS NOT NULL;
        WHEN 'PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED' THEN
            expected_kind:='PROCUREMENT_ARRIVAL_EXCEPTION';
            pending:=EXISTS(SELECT 1 FROM procurement_arrival_exceptions task WHERE task.id=p_id AND task.status='PENDING_FINANCE');
        WHEN 'SUBCONTRACT_LOSS_CLAIM_OPENED' THEN
            expected_kind:='SUBCONTRACT_LOSS_CASE';
            pending:=EXISTS(SELECT 1 FROM subcontract_loss_cases task WHERE task.id=p_id AND task.status='OPEN');
        WHEN 'RD_TASK_FORWARDED' THEN
            expected_kind:='RD_TASK';
            pending:=EXISTS(SELECT 1 FROM rd_tasks task WHERE task.id=p_id AND NOT task.is_deleted AND task.category='BOM'
                AND task.goods_id IS NOT NULL AND task.status IN('OPEN','IN_PROGRESS')
                AND (task.assignee_employee_id IS NULL OR task.assignee_employee_id=employee_id));
        WHEN 'SALES_QUOTE_FINANCE_RETURNED','SALES_QUOTE_FINANCE_CONFIRMED' THEN
            expected_kind:='SALES_QUOTE_ACTION';
            pending:=EXISTS(SELECT 1 FROM sales_quotes document WHERE document.id=p_id AND NOT document.is_deleted
                AND NOT document.is_closed AND fn_notice_task_owner(scopes,'sales',document.maker_id,TRUE)
                AND CASE WHEN p_event='SALES_QUOTE_FINANCE_RETURNED' THEN document.status=0 AND document.finance_return_reason IS NOT NULL
                    ELSE document.status=1 AND document.finance_confirmed_at IS NOT NULL
                      AND NOT EXISTS(SELECT 1 FROM sales_orders target WHERE target.source_quote_id=document.id)
                      AND CASE WHEN document.customer_accepted_at IS NOT NULL AND document.customer_accepted_revision=document.review_revision THEN
                        ARRAY['sales_quote:convert','sales_order:create']<@permissions
                        ELSE 'sales_quote:edit'=ANY(permissions) END END);
        WHEN 'SALES_ORDER_FINANCE_REJECTED' THEN
            expected_kind:='SALES_ORDER';
            pending:=EXISTS(SELECT 1 FROM sales_orders document WHERE document.id=p_id AND NOT document.is_deleted
                AND document.finance_rejected AND NOT document.is_closed AND NOT document.is_stopped
                AND fn_notice_task_owner(scopes,'sales',document.owner_employee_id,TRUE));
        WHEN 'PROCUREMENT_FINANCE_REJECTED' THEN
            expected_kind:='PROCUREMENT_ORDER_REWORK';
            IF p_route LIKE '/purchase/orders/%' THEN
                pending:=ARRAY['purchase_order:view','purchase_order:edit']<@permissions
                    AND EXISTS(SELECT 1 FROM purchase_orders document WHERE document.id=p_id AND NOT document.is_deleted
                        AND document.status=0 AND fn_notice_task_owner(scopes,'purchase',document.maker_id,TRUE)
                        AND EXISTS(SELECT 1 FROM v_procurement_decomposition_tasks task WHERE task.department='PURCHASE'
                            AND task.action_doc_id=document.id AND task.task_status='FINANCE_REJECTED'));
            ELSIF p_route LIKE '/subcontract/orders/%' THEN
                pending:=ARRAY['subcontract_order:view','subcontract_order:edit']<@permissions
                    AND EXISTS(SELECT 1 FROM subcontract_orders document WHERE document.id=p_id AND NOT document.is_deleted
                        AND document.status=0 AND fn_notice_task_owner(scopes,'subcontract',document.maker_id,TRUE)
                        AND EXISTS(SELECT 1 FROM v_procurement_decomposition_tasks task WHERE task.department='SUBCONTRACT'
                            AND task.action_doc_id=document.id AND task.task_status='FINANCE_REJECTED'));
            END IF;
        WHEN 'SUBCONTRACT_ORDER_KIT_READY' THEN
            expected_kind:='SUBCONTRACT_APPLICATION_ITEM';
            pending:=EXISTS(SELECT 1 FROM fn_subcontract_application_orderable_batch(ARRAY[p_id]) available
                WHERE available.application_item_id=p_id AND available.orderable_qty>0);
        WHEN 'SUBCONTRACT_DRAW_AVAILABLE' THEN
            expected_kind:='SUBCONTRACT_ORDER_ITEM';
            pending:=EXISTS(SELECT 1 FROM subcontract_order_items item
                JOIN subcontract_orders document ON document.id=item.order_id
                JOIN subcontract_material_plans plan ON plan.order_id=document.id AND NOT plan.is_deleted
                CROSS JOIN LATERAL fn_subcontract_draw_summary(item.id) available
                WHERE item.id=p_id AND NOT item.is_deleted AND NOT document.is_deleted AND document.status=1
                  AND NOT document.is_closed AND plan.status='OPEN' AND available.drawable_qty>0
                  AND fn_notice_task_owner(scopes,'subcontract',document.maker_id,FALSE)
                  AND GREATEST(COALESCE(item.received_qty,0)-COALESCE(item.returned_qty,0),0)
                      +fn_subcontract_settled_loss_qty(item.id)<item.qty
                  AND EXISTS(SELECT 1 FROM subcontract_material_plan_items line WHERE line.plan_id=plan.id
                    AND line.order_item_id=item.id AND NOT line.is_deleted AND line.draw_closed_at IS NULL
                    AND line.issued_qty<fn_subcontract_draw_needed_qty(line.order_item_id,line.planned_qty,line.bom_unit_qty)));
        WHEN 'SUBCONTRACT_SHORT_DELIVERY_DETECTED','SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE' THEN
            expected_kind:='SUBCONTRACT_SHORT_DELIVERY_CASE';
            pending:=EXISTS(SELECT 1 FROM subcontract_short_delivery_cases task WHERE task.id=p_id
                AND fn_notice_task_owner(scopes,'subcontract',task.owner_employee_id,TRUE)
                AND ((task.status='PENDING_OWNER' AND task.severity IN('SEVERE','BELOW_FLOOR'))
                  OR (task.status='WAITING_MORE' AND task.severity<>'WITHIN_TOLERANCE' AND task.expected_complete_by<CURRENT_DATE)));
        WHEN 'SUBCONTRACT_OUTBOUND_READY' THEN
            expected_kind:='SUBCONTRACT_MATERIAL_ISSUE';
            SELECT ARRAY[document.warehouse_id] INTO warehouses FROM subcontract_material_issues document
              WHERE document.id=p_id AND document.status=0 AND NOT document.is_deleted;
            pending:=warehouses IS NOT NULL;
        WHEN 'SALES_SHIPMENT_PENDING_FINANCE_AUDIT','SALES_SHIPMENT_PENDING_PICK',
             'SALES_SHIPMENT_FINANCE_REJECTED','DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED' THEN
            expected_kind:='SALES_SHIPMENT';
            SELECT CASE p_event
                WHEN 'SALES_SHIPMENT_PENDING_FINANCE_AUDIT' THEN document.finance_audit=0 AND NOT document.finance_rejected
                  AND (document.finance_gate_version<2 OR(document.sales_confirmed_at IS NOT NULL
                    AND document.sales_confirmed_revision=document.review_revision))
                WHEN 'SALES_SHIPMENT_PENDING_PICK' THEN document.finance_audit=1 AND NOT document.finance_rejected
                ELSE document.finance_rejected AND fn_notice_task_owner(scopes,'sales',document.owner_employee_id,TRUE) END
              INTO pending FROM sales_shipments document WHERE document.id=p_id AND document.status=0
                AND NOT document.is_deleted AND NOT document.rejected AND document.warehouse_work_status='PENDING_PICK';
            IF p_event='SALES_SHIPMENT_PENDING_PICK' THEN
                SELECT array_agg(DISTINCT COALESCE(item.warehouse_id,document.warehouse_id)) INTO warehouses
                  FROM sales_shipments document LEFT JOIN sales_shipment_items item ON item.shipment_id=document.id AND NOT item.is_deleted
                  WHERE document.id=p_id;
            END IF;
        WHEN 'SALES_ORDER_PENDING_FINANCE_CONFIRM' THEN
            expected_kind:='SALES_ORDER';
            pending:=EXISTS(SELECT 1 FROM sales_orders document WHERE document.id=p_id AND document.status=1
                AND NOT document.is_deleted AND NOT document.is_closed AND NOT document.is_stopped
                AND NOT document.finance_confirmed AND NOT document.finance_rejected AND document.requoted_to_id IS NULL);
        WHEN 'SALES_ORDER_APPROVED' THEN
            expected_kind:='SALES_ORDER';
            pending:=EXISTS(SELECT 1 FROM sales_orders document WHERE document.id=p_id AND document.status=1
                AND NOT document.is_deleted AND NOT document.is_closed AND NOT document.is_stopped
                AND document.finance_confirmed AND NOT document.finance_rejected AND document.requoted_to_id IS NULL
                AND NOT EXISTS(SELECT 1 FROM production_material_analysis_items taken
                    JOIN sales_order_items original ON original.id=taken.sales_order_item_id
                    WHERE original.order_id=document.id AND taken.source_type='SALES_ORDER_ITEM')
                AND EXISTS(SELECT 1 FROM sales_order_items item JOIN goods ON goods.id=item.goods_id
                    WHERE item.order_id=document.id AND NOT item.is_deleted AND NOT goods.is_deleted
                      AND GREATEST(COALESCE(item.qty,0)-COALESCE(item.shipped_qty,0)+COALESCE(item.returned_qty,0)
                        -COALESCE(item.flag_qty,0)-COALESCE(item.reserved_qty,0)
                        -GREATEST(COALESCE(item.planned_qty,0)-COALESCE(item.produced_qty,0),0)
                        -COALESCE((SELECT SUM(CASE WHEN link.id IS NOT NULL THEN link.submitted_qty ELSE plan_item.qty END)
                            FROM production_plan_items plan_item JOIN production_plans plan ON plan.id=plan_item.plan_id
                            LEFT JOIN production_material_analysis_plan_links link ON link.plan_id=plan.id
                              AND link.analysis_id=plan.material_analysis_id AND link.analysis_item_id=plan.material_analysis_item_id
                            WHERE plan_item.sales_order_item_id=item.id AND NOT plan_item.is_deleted AND NOT plan.is_deleted
                              AND plan.status=0 AND NOT plan.is_canceled),0),0)>0));
        WHEN 'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' THEN
            expected_kind:='SALES_ORDER';
            pending:=EXISTS(SELECT 1 FROM sales_orders document WHERE document.id=p_id AND document.status=1
                AND NOT document.is_deleted AND NOT document.is_closed AND NOT document.is_stopped
                AND document.finance_confirmed AND NOT document.finance_rejected AND document.requoted_to_id IS NULL
                AND fn_notice_task_owner(scopes,'sales',document.owner_employee_id,TRUE)
                AND EXISTS(SELECT 1 FROM sales_order_items item WHERE item.order_id=document.id AND NOT item.is_deleted
                    GROUP BY item.order_id HAVING SUM(item.qty)>0 AND SUM(COALESCE(item.produced_qty,0))>=SUM(item.qty))
                AND EXISTS(SELECT 1 FROM sales_order_items item WHERE item.order_id=document.id AND NOT item.is_deleted
                  AND LEAST(COALESCE(item.reserved_qty,0),
                    GREATEST(item.qty-COALESCE(item.shipped_qty,0)+COALESCE(item.returned_qty,0)-COALESCE(item.flag_qty,0),0),
                    COALESCE((SELECT SUM(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0))
                        FROM stock_reservations reservation WHERE reservation.order_item_id=item.id AND NOT reservation.is_deleted
                          AND reservation.status=0),0)/COALESCE(NULLIF(item.unit_rate,0),1))
                    >COALESCE((SELECT SUM(detail.qty) FROM sales_shipment_items detail
                        JOIN sales_shipments shipment ON shipment.id=detail.shipment_id WHERE detail.order_item_id=item.id
                          AND NOT detail.is_deleted AND NOT shipment.is_deleted AND shipment.status=0 AND NOT shipment.rejected),0)));
        WHEN 'SALES_QUOTE_PENDING_FINANCE_REVIEW' THEN
            expected_kind:='SALES_QUOTE';
            pending:=EXISTS(SELECT 1 FROM sales_quotes document WHERE document.id=p_id AND document.status=2
                AND NOT document.is_deleted AND NOT document.is_closed AND document.submitted_by IS DISTINCT FROM employee_id);
        WHEN 'PROCUREMENT_FINANCE_SUBMITTED','PROCUREMENT_FINANCE_CHANGE_SUBMITTED' THEN
            expected_kind:='PROCUREMENT_APPROVAL_CASE';
            pending:=EXISTS(SELECT 1 FROM procurement_order_approval_cases task WHERE task.id=p_id AND task.status='PENDING');
        WHEN 'PROCUREMENT_FINANCE_APPROVED' THEN
            expected_kind:='PROCUREMENT_ORDER';
            SELECT array_agg(DISTINCT source.warehouse_id) INTO warehouses FROM inbound_expectations task
              CROSS JOIN LATERAL unnest(fn_inbound_expectation_warehouse_ids(task.id)) source(warehouse_id)
              WHERE task.order_id=p_id AND task.status NOT IN('CLOSED','CANCELED');
            pending:=warehouses IS NOT NULL;
        WHEN 'PROCUREMENT_IQC_PENDING' THEN
            expected_kind:='IQC_INSPECTION';
            pending:=EXISTS(SELECT 1 FROM procurement_inspection_items task WHERE task.receipt_id=p_id AND task.status IN('PENDING','PARTIAL'));
        WHEN 'PROCUREMENT_IQC_STOCK_IN_PENDING' THEN
            expected_kind:='PROCUREMENT_INSPECTION_PASS';
            SELECT ARRAY[inspection.warehouse_id] INTO warehouses FROM procurement_inspection_events event
              JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id AND inspection.status<>'REVERSED'
              WHERE event.id=p_id AND event.action='PASS' AND event.requires_warehouse_stock_in
                AND event.base_qty>COALESCE((SELECT SUM(item.base_qty) FROM procurement_iqc_stock_in_batch_items item
                    WHERE item.pass_event_id=event.id),0);
            pending:=warehouses IS NOT NULL;
        WHEN 'PROCUREMENT_IQC_REJECTION_OPENED','PROCUREMENT_IQC_REJECTION_RETURNED' THEN
            expected_kind:='IQC_REJECTION_CASE';
            pending:=EXISTS(SELECT 1 FROM procurement_iqc_rejection_cases task
                JOIN procurement_inspection_items inspection ON inspection.id=task.inspection_item_id
                WHERE task.id=p_id AND NOT task.is_deleted AND
                  CASE WHEN p_event='PROCUREMENT_IQC_REJECTION_OPENED' THEN
                    task.status IN('PENDING_RETURN','FINANCE_EXCEPTION') AND task.return_recorded_at IS NULL
                      AND inspection.status='RESOLVED' AND 'procurement_iqc_rejection:record_return'=ANY(permissions)
                  ELSE (task.status='FINANCE_EXCEPTION' AND ARRAY['procurement_iqc_rejection:confirm_credit','procurement_iqc_rejection:amount:view']<@permissions)
                    OR (task.status='RETURN_RECORDED' AND
                      ((ARRAY['procurement_iqc_rejection:confirm_credit','procurement_iqc_rejection:amount:view']<@permissions
                          AND (task.failed_amount_original IS NULL OR task.failed_amount_original>0))
                        OR ('procurement_iqc_rejection:close_no_credit'=ANY(permissions)
                            AND task.failed_amount_original=0 AND task.failed_amount_local=0))) END);
        WHEN 'PRODUCTION_DRAW_PENDING' THEN
            expected_kind:='STOCK_DOCUMENT';
            SELECT array_agg(DISTINCT COALESCE(item.warehouse_id,document.warehouse_id)) INTO warehouses
              FROM stock_documents document LEFT JOIN stock_document_items item ON item.doc_id=document.id AND NOT item.is_deleted
              WHERE document.id=p_id AND NOT document.is_deleted AND document.status IN(0,1)
                AND document.doc_type='DRAW' AND fn_production_draw_pending(document.id);
            pending:=warehouses IS NOT NULL;
        WHEN 'PRODUCTION_MATERIAL_DISCOVERY_PENDING' THEN
            expected_kind:='PRODUCTION_MATERIAL_DISCOVERY_REQUEST';
            SELECT ARRAY[package.warehouse_id] INTO warehouses FROM production_material_discovery_requests task
              JOIN production_execution_segments segment ON segment.id=task.execution_segment_id
              JOIN production_planning_packages package ON package.id=segment.package_id
              JOIN production_plans plan ON plan.id=segment.plan_id
              WHERE task.id=p_id AND task.status='PENDING' AND NOT segment.is_deleted
                AND segment.status IN('READY','DISPATCHED') AND plan.status=1 AND NOT plan.is_deleted;
            pending:=warehouses IS NOT NULL;
        WHEN 'PRODUCTION_OVER_LIMIT_PENDING' THEN
            expected_kind:='PRODUCTION_OVER_LIMIT_DISPOSITION';
            pending:=EXISTS(SELECT 1 FROM production_over_limit_dispositions task JOIN production_plans plan ON plan.id=task.plan_id
                WHERE task.id=p_id AND task.status IN('PENDING','HELD','RETURNED') AND NOT plan.is_deleted
                  AND fn_notice_task_owner(scopes,'production_plan',plan.maker_id,FALSE));
        WHEN 'PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED' THEN
            expected_kind:='PRODUCTION_OVERPRODUCTION_RATE_REQUEST';
            pending:=EXISTS(SELECT 1 FROM production_overproduction_rate_requests task WHERE task.id=p_id AND task.status='PENDING');
        WHEN 'PRODUCTION_MATERIAL_INCREMENT_SUBMITTED' THEN
            expected_kind:='PRODUCTION_MATERIAL_INCREMENT_REQUEST';
            pending:=EXISTS(SELECT 1 FROM production_material_increment_requests task WHERE task.id=p_id AND task.status='PENDING');
        WHEN 'PRODUCTION_PLANNING_URGED' THEN
            expected_kind:='PRODUCTION_PLANNING_URGE';
            pending:=EXISTS(SELECT 1 FROM production_planning_urges task
                JOIN production_material_analyses analysis ON analysis.id=task.material_analysis_id
                WHERE task.id=p_id AND task.status='OPEN' AND NOT analysis.is_deleted
                  AND fn_notice_task_owner(scopes,'production_plan',analysis.maker_id,TRUE));
        WHEN 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' THEN
            expected_kind:='PRODUCTION_EXECUTION_SEGMENT';
            pending:=EXISTS(SELECT 1 FROM production_execution_segments task JOIN production_plans plan ON plan.id=task.plan_id
                WHERE task.id=p_id AND NOT task.is_deleted AND NOT plan.is_deleted AND plan.status=1
                  AND task.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS') AND NOT plan.is_closed AND NOT plan.is_stopped AND NOT plan.is_canceled);
            -- Precise direct assignment/leadership scope is also applied by NoticeRepository.
        WHEN 'PROFILE_CHANGE_SUBMITTED' THEN
            expected_kind:='PROFILE_CHANGE';
            pending:=EXISTS(SELECT 1 FROM profile_change_requests task WHERE task.batch_id=p_id AND task.status='pending');
        WHEN 'VISITOR_APPLY_SUBMITTED' THEN
            expected_kind:='VISITOR_APPLICATION';
            pending:=EXISTS(SELECT 1 FROM visitor_applications task WHERE task.id=p_id AND task.status IN('pending','hostReviewing'));
        WHEN 'VISITOR_HOST_CONFIRM_REQUIRED' THEN
            expected_kind:='VISITOR_HOST_CONFIRM';
            pending:=EXISTS(SELECT 1 FROM visitor_applications task WHERE task.id=p_id AND task.status='hostReviewing'
                AND task.host_employee_id=employee_id);
        WHEN 'EXPENSE_CLAIM_SUBMITTED','EXPENSE_CLAIM_PENDING_PAYMENT','EXPENSE_CLAIM_REJECTED' THEN
            expected_kind:='EXPENSE_CLAIM';
            pending:=EXISTS(SELECT 1 FROM expense_claims task WHERE task.id=p_id AND NOT task.is_deleted
                AND CASE p_event WHEN 'EXPENSE_CLAIM_SUBMITTED' THEN task.status='SUBMITTED' AND task.applicant_id<>employee_id
                    WHEN 'EXPENSE_CLAIM_PENDING_PAYMENT' THEN task.status='APPROVED' AND task.applicant_id<>employee_id
                        AND task.approved_by IS DISTINCT FROM employee_id
                    ELSE task.status='REJECTED' AND task.applicant_id=employee_id END);
        WHEN 'PAYROLL_BATCH_SUBMITTED','PAYROLL_BATCH_PENDING_PUBLISH' THEN
            expected_kind:='PAYROLL_BATCH';
            pending:=EXISTS(SELECT 1 FROM payroll_batches task WHERE task.id=p_id AND
                CASE p_event WHEN 'PAYROLL_BATCH_SUBMITTED' THEN task.status='SUBMITTED' AND task.generated_by<>employee_id
                    ELSE task.status='APPROVED' AND task.approved_by IS DISTINCT FROM employee_id END);
        WHEN 'SUGGESTION_SUBMITTED' THEN
            expected_kind:='SUGGESTION';
            pending:=EXISTS(SELECT 1 FROM suggestions task WHERE task.id=p_id AND task.status NOT IN('resolved','rejected')
                AND task.submitter_id IS DISTINCT FROM p_user);
        WHEN 'STOCK_COUNT_PENDING_FINANCE_REVIEW','STOCK_COUNT_PENDING_WAREHOUSE_REVIEW' THEN
            expected_kind:='STOCK_COUNT_REQUEST';
            SELECT ARRAY[task.warehouse_id] INTO warehouses FROM stock_count_requests task WHERE task.id=p_id AND task.status='PENDING'
                AND task.review_route=CASE WHEN p_event='STOCK_COUNT_PENDING_WAREHOUSE_REVIEW' THEN 'WAREHOUSE' ELSE 'FINANCE' END;
            pending:=warehouses IS NOT NULL;
            IF p_event='STOCK_COUNT_PENDING_FINANCE_REVIEW' THEN warehouses:=NULL; END IF;
        WHEN 'WORKSHOP_MATERIAL_REQUISITION_PENDING','WORKSHOP_MATERIAL_RETURN_PENDING' THEN
            expected_kind:='WORKSHOP_MATERIAL_REQUISITION';
            SELECT array_agg(DISTINCT line.suggested_leaf_warehouse_id) INTO warehouses FROM workshop_material_requisitions task
              JOIN workshop_material_requisition_lines line ON line.requisition_id=task.id
              WHERE task.id=p_id AND task.status='PENDING'
                AND task.kind=CASE WHEN p_event='WORKSHOP_MATERIAL_REQUISITION_PENDING' THEN 'ISSUE' ELSE 'RETURN' END;
            pending:=warehouses IS NOT NULL;
        WHEN 'WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT','WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT',
             'WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK','WORKSHOP_MATERIAL_CLOSE_FAILING' THEN
            expected_kind:='WORKSHOP_MATERIAL_PERIOD';
            suffix:=CASE p_event WHEN 'WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT' THEN 'REPORT'
                WHEN 'WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT' THEN 'WEIGHT'
                WHEN 'WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK' THEN 'STOCK' ELSE 'FAILING' END;
            SELECT task.* INTO period FROM workshop_material_periods task
              WHERE task.workshop_department_id=substring(COALESCE(p_route,'') FROM '[?&]workshopId=([0-9a-fA-F-]{36})')::uuid
                AND task.status<>'CLOSED' AND fn_notice_workshop_period_key(task.id,suffix)=p_id;
            IF NOT FOUND THEN RETURN false; END IF;
            IF suffix='FAILING' THEN pending:=period.close_state='FAILED';
            ELSIF suffix='REPORT' THEN
                pending:=EXISTS(SELECT 1 FROM fn_workshop_material_close_blockers(period.id) blocker
                    JOIN production_daily_reports report ON report.id=blocker.report_id
                    WHERE blocker.kind='DRAFT_REPORT' AND
                      (('production_daily_report:approve'=ANY(permissions) AND fn_notice_workshop_member(p_user,period.workshop_department_id))
                        OR (permissions&&ARRAY['production_daily_report:edit','production_daily_report:delete']
                            AND fn_notice_task_owner(scopes,'production_plan',report.maker_id,TRUE))));
            ELSIF suffix='WEIGHT' THEN pending:=EXISTS(SELECT 1 FROM fn_workshop_material_close_blockers(period.id) blocker WHERE blocker.kind='MISSING_WEIGHT');
            ELSE
                pending:=EXISTS(SELECT 1 FROM fn_workshop_material_close_blockers(period.id) blocker WHERE blocker.kind='THEORY_WITHOUT_STOCK');
                IF pending AND 'workshop_material:choose'=ANY(permissions) AND fn_notice_workshop_member(p_user,period.workshop_department_id) THEN RETURN true; END IF;
                SELECT array_agg(source_warehouse_id) INTO warehouses FROM workshop_bins WHERE workshop_department_id=period.workshop_department_id;
            END IF;
        ELSE RETURN false;
    END CASE;
    IF (p_kind IS DISTINCT FROM expected_kind AND NOT(non_popup AND p_kind IS NULL)) OR pending IS NOT TRUE THEN RETURN false; END IF;
    IF pools ? p_event THEN
        SELECT COALESCE(array_agg(value::uuid),ARRAY[]::uuid[]) INTO pool FROM jsonb_array_elements_text(pools->p_event);
        RETURN p_user=ANY(fn_warehouse_notice_recipients(COALESCE(warehouses,ARRAY[]::uuid[]),pool));
    END IF;
    RETURN true;
END;
$$;

COMMENT ON FUNCTION fn_notice_business_action_visible(uuid,text,text,uuid,text,text,text,text,text,text) IS
    'V876: current action grant, source state, owner write/read responsibility and warehouse routing before every notice page/count';
