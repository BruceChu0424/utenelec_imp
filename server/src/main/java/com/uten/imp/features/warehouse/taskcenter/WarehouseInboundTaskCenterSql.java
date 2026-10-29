package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService;

import java.util.ArrayList;
import java.util.List;

/** Fixed physical projections. Filtering and LIMIT belong outside the UNION, never to each source. */
final class WarehouseInboundTaskCenterSql {
    private WarehouseInboundTaskCenterSql() {}

    // A viewer's command grants do not decide whether a physical workflow is finished.
    // The same lifecycle predicate is applied before rows, totals and header facets.
    private static final String ACTIVE_STATUS_PREDICATE = """
            workflow_status IN (
              'PURCHASE_READY_REGISTER','PURCHASE_BLOCKED','PURCHASE_CONTINUE_INSPECTION',
              'PURCHASE_EXCESS_PENDING_FINANCE','PURCHASE_WAITING_INSPECTION',
              'PURCHASE_PRE_STOCKED_WAITING_INSPECTION','PURCHASE_PASSED_WAITING_STOCK_IN',
              'PURCHASE_PARTIAL_PASSED','PURCHASE_RETURN_REQUIRED','PURCHASE_RECEIPT_DRAFT',
              'PURCHASE_EXCEPTION_PENDING_FINANCE','PURCHASE_EXCEPTION_RECEIPT_ADJUSTED',
              'PURCHASE_EXCEPTION_RETURN_REQUIRED','PURCHASE_EXCEPTION_RECEIPT_POSTED',
              'SUBCONTRACT_READY_REGISTER','SUBCONTRACT_BLOCKED','SUBCONTRACT_CONTINUE_INSPECTION',
              'SUBCONTRACT_EXCESS_PENDING_FINANCE','SUBCONTRACT_WAITING_INSPECTION',
              'SUBCONTRACT_PRE_STOCKED_WAITING_INSPECTION','SUBCONTRACT_PASSED_WAITING_STOCK_IN',
              'SUBCONTRACT_PARTIAL_PASSED','SUBCONTRACT_RETURN_REQUIRED','SUBCONTRACT_RECEIPT_DRAFT',
              'SUBCONTRACT_EXCEPTION_PENDING_FINANCE','SUBCONTRACT_EXCEPTION_RECEIPT_ADJUSTED',
              'SUBCONTRACT_EXCEPTION_RETURN_REQUIRED','SUBCONTRACT_EXCEPTION_RECEIPT_POSTED',
              'FINISHED_READY_REGISTER','FINISHED_READY_COUNT','FINISHED_RESIDUAL_COUNT',
              'FINISHED_WAITING_FQC','FINISHED_PRE_STOCKED_FQC','FINISHED_FQC_PARTIAL',
              'FINISHED_DRAFT','OTHER_DRAFT','RETURN_DRAFT','RETURN_PENDING_RECEIVE','RETURN_WORKSHOP_PENDING')
            """;

    record Access(boolean inbound, boolean purchaseHistory, boolean subcontractHistory,
                  boolean quality, boolean stock, boolean productionPool, String stockOwnerPredicate,
                  WarehouseWorkshopMaterialTaskProjection.Scope workshop) {
        Access(boolean inbound, boolean purchaseHistory, boolean subcontractHistory,
               boolean quality, boolean stock, boolean productionPool, String stockOwnerPredicate) {
            this(inbound,purchaseHistory,subcontractHistory,quality,stock,productionPool,stockOwnerPredicate,
                    WarehouseWorkshopMaterialTaskProjection.Scope.NONE);
        }
    }

    static String base(Access access, WarehouseTaskScope scope) {
        return base(access, scope, null);
    }

    static String base(Access access, WarehouseTaskScope scope, String keyword) {
        return base(access, scope, keyword, "TRUE");
    }
    static String base(Access access, WarehouseTaskScope scope, String keyword, String headers) {
        List<String> branches = new ArrayList<>();
        if (access.workshop().enabled()) branches.add(WarehouseWorkshopMaterialTaskProjection.inbound(access.workshop()));
        String ctes = "WITH " + WarehouseQualityResultService.taskCenterFactCtes() + ",\n"
                + ProductionFinishedInboundTaskService.taskCenterFactCtes() + ",\n" + DRAFT_CTES + ",\n";
        if (access.inbound()) {
            branches.add(expectations(scope));
            branches.add(exceptions(scope));
        }
        if (access.purchaseHistory() || access.quality()) {
            branches.add(receipts("PURCHASE", access.purchaseHistory(), scope));
        }
        if (access.subcontractHistory() || access.quality()) {
            branches.add(receipts("SUBCONTRACT", access.subcontractHistory(), scope));
        }
        if (access.stock()) {
            if (access.productionPool()) {
                branches.add(finishedTasks(scope));
                branches.add(finishedRegistrations(scope));
            }
            branches.add(stockDocuments(access, scope));
        }
        if (branches.isEmpty()) throw new IllegalArgumentException("No authorized warehouse source");
        return ctes + "inbound_source_rows AS (\n" + String.join("\nUNION ALL\n", branches)
                + "\n), inbound_rows AS (SELECT *, "
                + TaskKeywordSearch.rankNamesFirst(keyword, new String[]{}, new String[]{"goods_names"},
                        new String[]{"bill_no", "source_doc_no"}, "goods_codes")
                + " AS keyword_rank FROM inbound_source_rows WHERE "
                + TaskKeywordSearch.condition(keyword, "search_text", "warehouse_name", "responsible_name", "maker_name", "party_name")
                + " AND (" + headers + "))\n";
    }

    static String predicate(boolean includeStatus) {
        return predicate(includeStatus,true);
    }

    static String predicate(boolean includeStatus,boolean includeBillNo) {
        return """
                 WHERE (:source = 'ALL' OR source_type = :source)
                   AND (CAST(:dateFrom AS date) IS NULL OR business_date >= CAST(:dateFrom AS date))
                   AND (CAST(:dateTo AS date) IS NULL OR business_date <= CAST(:dateTo AS date))
                """ + (includeBillNo?" AND (CAST(:billNo AS text) IS NULL OR bill_no=CAST(:billNo AS text))\n":"")
                + " AND (:view = 'ALL' OR (:view = 'ACTIVE') = (" + ACTIVE_STATUS_PREDICATE + "))\n"
                + (includeStatus ? " AND (:status = '' OR workflow_status = :status)\n" : "");
    }

    static String rows(String base) {
        return rows(base,null,null,"");
    }

    static String rows(String base,String sort,String order,String identityFilter) {
        String column=WarehouseTaskHeaderQuery.orderExpression(sort,true);
        String direction="asc".equalsIgnoreCase(order)?"ASC":"DESC";
        return base+" SELECT * FROM inbound_rows "+predicate(true)+identityFilter
                +" ORDER BY "+(sort==null||sort.isBlank()?"keyword_rank, ":"")+column+" "+direction+" NULLS LAST, sort_time DESC NULLS LAST, source_type, record_type, id, CAST(line_data->>'lineNo' AS integer) NULLS LAST, line_data->>'key'"
                +" LIMIT :limit OFFSET :offset";
    }

    static String count(String base) { return base + " SELECT COUNT(*) FROM inbound_rows " + predicate(true); }
    static String facets(String base) {
        return base + " SELECT workflow_status, COUNT(*) FROM inbound_rows " + predicate(false)
                + " GROUP BY workflow_status ORDER BY workflow_status";
    }

    static String billNoFacets(String base) {
        return base+"SELECT bill_no,COUNT(*) FROM inbound_rows "+predicate(true,false)
                +" AND bill_no IS NOT NULL GROUP BY bill_no ORDER BY bill_no LIMIT 500";
    }

    static String expectationBadgeSql(WarehouseTaskScope scope) {
        return "WITH " + DRAFT_CTES + " SELECT source_type, COUNT(*) FROM (" + expectations(scope)
                + ") task_rows GROUP BY source_type";
    }

    static String finishedBadgeSql(WarehouseTaskScope scope) {
        return "WITH " + ProductionFinishedInboundTaskService.taskCenterFactCtes()
                + " SELECT COUNT(*) FROM (" + finishedTasks(scope) + ") task_rows";
    }

    static String returnBadgeSql(WarehouseTaskScope scope) {
        var access = new Access(false, false, false, false, true, true, "FALSE");
        return "WITH " + ProductionFinishedInboundTaskService.taskCenterFactCtes()
                + " SELECT COUNT(*) FROM (" + stockDocuments(access, scope)
                + ") task_rows WHERE workflow_status='RETURN_PENDING_RECEIVE'";
    }

    private static String scope(WarehouseTaskScope scope, String array) {
        return scope.active() ? " AND " + scope.predicateAny(array, ":warehouseScope") : "";
    }

    private static final String DRAFT_CTES = """
            draft_receipt_lines AS (
                SELECT 'PURCHASE'::text AS order_type, r.id AS receipt_id, i.order_item_id,
                       i.qty, CASE WHEN i.quantity_semantics = 'CHARGED_PLUS_GIFT_V1'
                                  THEN COALESCE(i.gift_qty,0) ELSE 0 END AS gift_qty
                FROM (SELECT * FROM purchase_receipts archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('purchase_receipts',archive_origin.id)) r JOIN (SELECT * FROM purchase_receipt_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('purchase_receipt_items',archive_origin.id)) i ON i.receipt_id=r.id
                WHERE r.status=0 AND r.legacy_id IS NULL AND NOT r.is_deleted AND NOT i.is_deleted
                UNION ALL
                SELECT 'SUBCONTRACT', r.id, i.order_item_id, i.qty, 0::numeric
                FROM (SELECT * FROM subcontract_receipts archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_receipts',archive_origin.id)) r JOIN (SELECT * FROM subcontract_receipt_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_receipt_items',archive_origin.id)) i ON i.receipt_id=r.id
                WHERE r.status=0 AND r.legacy_id IS NULL AND NOT r.is_deleted AND NOT i.is_deleted
            )
            """;

    private static String expectations(WarehouseTaskScope scope) {
        String receivable = ProcurementArrivalControlService.taskCenterReceivableQuantity();
        String gift = ProcurementArrivalControlService.taskCenterReceivableGiftQuantity();
        return """
                SELECT expectation.id, expectation.order_type AS source_type, 'EXPECTATION'::text AS record_type,
                       expectation.bill_no_snapshot AS bill_no, NULL::text AS source_doc_no,
                       COALESCE(expectation.expected_date,(expectation.created_at AT TIME ZONE 'Asia/Shanghai')::date) AS business_date, supplier.name AS party_name,
                       selected_warehouse.name AS warehouse_name, owner.full_name AS responsible_name,
                       NULL::text AS maker_name,
                       facts.line_count,
                       expectation.order_type || '_' || CASE
                         WHEN facts.exception_count > 0 THEN 'EXCESS_PENDING_FINANCE'
                         WHEN cardinality(facts.draft_ids)>0 THEN 'CONTINUE_INSPECTION'
                         WHEN facts.receivable AND expectation.supplier_id IS NOT NULL THEN 'READY_REGISTER'
                         WHEN facts.receivable THEN 'BLOCKED'
                         ELSE 'WAITING_INSPECTION' END AS workflow_status,
                       CASE WHEN cardinality(facts.draft_ids)>0 AND facts.exception_count=0
                            THEN 'ARRIVAL_CONTINUE'
                            WHEN facts.receivable AND facts.exception_count=0 AND expectation.supplier_id IS NOT NULL THEN 'ARRIVAL_REGISTER'
                            ELSE 'NONE' END AS action,
                       CASE WHEN cardinality(facts.draft_ids)>0 AND facts.exception_count=0
                            THEN facts.draft_ids[1] ELSE expectation.id END AS target_id,
                       jsonb_build_object('expectationId',expectation.id,'receiptType',expectation.order_type,
                           'expectationItemId',selected_item.id,'draftReceiptIds',to_jsonb(facts.draft_ids)) AS action_data,
                       NULL::uuid AS maker_id, FALSE AS production_linked, expectation.created_at AS sort_time,
                       concat_ws(' ',expectation.bill_no_snapshot,supplier.name,facts.goods_text) AS search_text,
                       facts.goods_codes, facts.goods_names,
                       jsonb_build_object('key',selected_item.id,'itemId',selected_item.id,'lineNo',selected_item.line_no,
                           'goodsCode',selected_goods.code,'goodsName',selected_goods.name,'specification',selected_goods.spec,
                           'colorName',selected_color.name,'unitName',selected_unit.name,
                           'quantity',facts.remaining_qty,'weight',NULL) AS line_data
                FROM inbound_expectations expectation
                JOIN inbound_expectation_items selected_item ON selected_item.expectation_id=expectation.id
                JOIN goods selected_goods ON selected_goods.id=selected_item.goods_id
                LEFT JOIN colors selected_color ON selected_color.id=selected_item.color_id
                LEFT JOIN units selected_unit ON selected_unit.id=selected_item.unit_id
                LEFT JOIN warehouses selected_warehouse ON selected_warehouse.id=
                    fn_procurement_item_inbound_warehouse_id(expectation.order_type,selected_item.order_item_id,selected_item.goods_id)
                LEFT JOIN suppliers supplier ON supplier.id=expectation.supplier_id
                LEFT JOIN employees owner ON owner.id=expectation.owner_employee_id
                CROSS JOIN LATERAL (
                    SELECT COUNT(DISTINCT item.id)::integer AS line_count,
                           MAX(GREATEST((%s)-COALESCE(inflight.qty,0),0)) AS remaining_qty,
                           COALESCE(array_agg(DISTINCT dr.receipt_id ORDER BY dr.receipt_id) FILTER(WHERE dr.receipt_id IS NOT NULL),
                                    ARRAY[]::uuid[]) AS draft_ids,
                           COUNT(DISTINCT exception.id)::integer AS exception_count,
                           COALESCE(bool_or((%s)>COALESCE(inflight.qty,0)
                                OR (%s)>COALESCE(inflight.gift_qty,0)),FALSE) AS receivable,
                           string_agg(DISTINCT concat_ws(' ',goods.code,goods.name),' ') AS goods_text,
                           array_agg(DISTINCT goods.code) AS goods_codes, array_agg(DISTINCT goods.name) AS goods_names
                    FROM inbound_expectation_items item
                    JOIN goods ON goods.id=item.goods_id
                    LEFT JOIN draft_receipt_lines dr ON dr.order_type=expectation.order_type
                                                    AND dr.order_item_id=item.order_item_id
                    LEFT JOIN LATERAL (
                        SELECT SUM(line.qty) AS qty, SUM(line.gift_qty) AS gift_qty
                        FROM draft_receipt_lines line WHERE line.order_type=expectation.order_type
                           AND line.order_item_id=item.order_item_id
                    ) inflight ON TRUE
                    LEFT JOIN procurement_arrival_exceptions exception
                      ON exception.order_type=expectation.order_type AND exception.order_item_id=item.order_item_id
                     AND exception.status NOT IN('CLOSED','CANCELED')
                    WHERE item.expectation_id=expectation.id AND item.id=selected_item.id
                      AND (expectation.order_type<>'SUBCONTRACT' OR (%s))
                ) facts
                WHERE facts.line_count>0 AND (facts.receivable OR cardinality(facts.draft_ids)>0 OR facts.exception_count>0)
                  AND (%s) AND (%s)
                """.formatted(receivable, receivable, gift, ProcurementArrivalControlService.taskCenterItemVisiblePredicate(),
                ProcurementArrivalControlService.taskCenterWorkRemainingPredicate(),
                ProcurementArrivalControlService.taskCenterExpectationVisiblePredicate())
                + scope(scope,"fn_inbound_expectation_warehouse_ids(expectation.id)")
                + scope(scope,"ARRAY[fn_procurement_item_inbound_warehouse_id(expectation.order_type,selected_item.order_item_id,selected_item.goods_id)]");
    }

    private static String exceptions(WarehouseTaskScope scope) {
        return """
                SELECT exception.id, exception.order_type AS source_type, 'ARRIVAL_EXCEPTION'::text AS record_type,
                       exception.receipt_bill_no_snapshot AS bill_no, exception.order_bill_no_snapshot AS source_doc_no,
                       (exception.detected_at AT TIME ZONE 'Asia/Shanghai')::date AS business_date, supplier.name AS party_name,
                       warehouse.name AS warehouse_name, detector.full_name AS responsible_name, NULL::text AS maker_name,
                       1 AS line_count,
                       exception.order_type || '_EXCEPTION_' || exception.status AS workflow_status,
                       'ARRIVAL_EXCEPTION'::text AS action, exception.id AS target_id,
                       jsonb_strip_nulls(jsonb_build_object('exceptionId',exception.id,
                          'receiptType',exception.order_type,'receiptId',exception.receipt_id,
                          'expectedVersion',exception.version,'acceptedQty',exception.accepted_qty,
                          'unacceptedQty',exception.unaccepted_qty,'unitName',unit.name,
                          'goodsName',goods.name)) AS action_data,
                       NULL::uuid AS maker_id, FALSE AS production_linked,
                       exception.detected_at AS sort_time,
                       concat_ws(' ',exception.id,exception.receipt_bill_no_snapshot,exception.order_bill_no_snapshot,
                                 supplier.name,goods.code,goods.name) AS search_text,
                       ARRAY[goods.code] AS goods_codes, ARRAY[goods.name] AS goods_names,
                       jsonb_build_object('key',exception.id,'itemId',exception.receipt_item_id,
                           'goodsCode',goods.code,'goodsName',goods.name,'specification',goods.spec,
                           'colorName',color.name,'unitName',unit.name,'quantity',exception.declared_qty,'weight',NULL) AS line_data
                FROM procurement_arrival_exceptions exception
                JOIN goods ON goods.id=exception.goods_id
                LEFT JOIN suppliers supplier ON supplier.id=exception.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id=exception.warehouse_id
                LEFT JOIN units unit ON unit.id=exception.unit_id
                LEFT JOIN colors color ON color.id=exception.color_id
                LEFT JOIN employees detector ON detector.id=exception.detected_by_employee_id
                WHERE exception.order_type IN('PURCHASE','SUBCONTRACT')
                """ + scope(scope,"ARRAY[exception.warehouse_id]");
    }

    private static String receipts(String type, boolean history, WarehouseTaskScope scope) {
        String table = type.equals("PURCHASE") ? "purchase_receipts" : "subcontract_receipts";
        String itemTable = type.equals("PURCHASE") ? "purchase_receipt_items" : "subcontract_receipt_items";
        String historyType = type.equals("PURCHASE") ? "purchase-receipts" : "subcontract-receipts";
        String stage = """
                CASE WHEN h.status=-1 THEN 'RECEIPT_REVERSED'
                     WHEN h.is_closed THEN 'RECEIPT_CLOSED'
                     WHEN h.status=0 THEN 'RECEIPT_DRAFT'
                     WHEN inspection.receipt_id IS NULL THEN 'HISTORICAL_APPROVED'
                     WHEN (%s)='ALL_PASSED' THEN 'PASSED_WAITING_STOCK_IN'
                     WHEN (%s)='PARTIAL_PASSED' THEN 'PARTIAL_PASSED'
                     WHEN (%s)='RETURN_REQUIRED' THEN 'RETURN_REQUIRED'
                     WHEN (%s)='WAITING_INSPECTION' AND inspection.pre_stocked_line_count>0
                          THEN 'PRE_STOCKED_WAITING_INSPECTION'
                     WHEN (%s)='WAITING_INSPECTION' THEN 'WAITING_INSPECTION'
                     WHEN stocked.qty>0 AND inspection.failed_line_count>0 THEN 'STOCKED_WITH_RETURN'
                     WHEN stocked.qty>0 THEN 'STOCKED'
                     WHEN inspection.failed_line_count>0 THEN 'RETURNED'
                     ELSE 'RECEIPT_CLOSED' END
                """.formatted(java.util.Collections.nCopies(5,
                        WarehouseQualityResultService.taskCenterStatusExpression()).toArray());
        return ("""
                SELECT h.id, '%s'::text AS source_type, '%s_RECEIPT'::text AS record_type,
                       h.bill_no, h.source_doc_no, h.bill_date AS business_date, supplier.name AS party_name,
                       COALESCE(physical.warehouse_name,warehouse.name) AS warehouse_name, NULL::text AS responsible_name,
                       COALESCE(NULLIF(h.maker_name,''),maker.full_name) AS maker_name,
                       physical.line_count, '%s_' || (%s) AS workflow_status,
                       CASE WHEN h.status=1 AND inspection.receipt_id IS NOT NULL
                            THEN 'QUALITY_RESULT' ELSE 'HISTORY_DETAIL' END AS action, h.id AS target_id,
                       jsonb_strip_nulls(jsonb_build_object('receiptType','%s','receiptId',h.id,'historyType','%s','receiptItemId',line.id,
                          'inspectionItemIds',COALESCE(to_jsonb(inspection.item_ids),'[]'::jsonb),
                          'pendingSliceCount',COALESCE(pending_release.pending_slice_count,0),
                          'pendingReturnCount',COALESCE(pending_return.pending_return_count,0),
                          'openItemCount',COALESCE(inspection.open_item_count,0),
                          'preStockedLineCount',COALESCE(inspection.pre_stocked_line_count,0))) AS action_data,
                       h.maker_id, FALSE AS production_linked, h.created_at AS sort_time,
                       concat_ws(' ',h.bill_no,h.source_doc_no,supplier.name,warehouse.name,physical.goods_text) AS search_text,
                       physical.goods_codes, physical.goods_names, physical.line_data
                FROM %s h
                LEFT JOIN %s line ON line.receipt_id=h.id AND NOT line.is_deleted
                LEFT JOIN suppliers supplier ON supplier.id=h.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id=h.warehouse_id
                LEFT JOIN employees maker ON maker.id=h.maker_id
                LEFT JOIN LATERAL (
                    SELECT CASE WHEN COUNT(*)>0 THEN h.id END AS receipt_id,
                           array_agg(i.id ORDER BY i.id) AS item_ids,
                           COUNT(*) FILTER(WHERE i.passed_base_qty>0) AS passed_line_count,
                           COUNT(*) FILTER(WHERE i.failed_base_qty>0) AS failed_line_count,
                           COUNT(*) FILTER(WHERE i.status IN('PENDING','PARTIAL')) AS open_item_count,
                           COUNT(*) FILTER(WHERE i.status IN('PENDING','PARTIAL') AND i.pre_stocked_at IS NOT NULL) AS pre_stocked_line_count
                    FROM procurement_inspection_items i
                    WHERE i.receipt_type='%s' AND i.receipt_id=h.id AND i.status<>'REVERSED'
                      AND (line.id IS NULL OR i.receipt_item_id=line.id)
                ) inspection ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COUNT(DISTINCT event.id) AS pending_slice_count
                    FROM procurement_inspection_events event
                    JOIN procurement_inspection_items i ON i.id=event.inspection_item_id
                    WHERE i.receipt_type='%s' AND i.receipt_id=h.id AND i.status<>'REVERSED'
                      AND (line.id IS NULL OR i.receipt_item_id=line.id)
                      AND event.action='PASS' AND event.requires_warehouse_stock_in
                      AND i.passed_base_qty>i.warehouse_stocked_base_qty
                      AND event.base_qty>COALESCE((SELECT SUM(batch.base_qty) FROM procurement_iqc_stock_in_batch_items batch
                                                   WHERE batch.pass_event_id=event.id),0)
                ) pending_release ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COUNT(*) AS pending_return_count FROM procurement_iqc_rejection_cases rejection
                    JOIN procurement_inspection_items i ON i.id=rejection.inspection_item_id
                    WHERE i.receipt_type='%s' AND i.receipt_id=h.id AND i.status<>'REVERSED'
                      AND (line.id IS NULL OR i.receipt_item_id=line.id)
                      AND NOT COALESCE(rejection.is_deleted,FALSE) AND rejection.return_recorded_at IS NULL
                      AND rejection.status<>'REVERSED'
                ) pending_return ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(i.warehouse_stocked_base_qty),0) AS qty
                    FROM procurement_inspection_items i
                    WHERE i.receipt_type='%s' AND i.receipt_id=h.id AND i.status<>'REVERSED'
                      AND (line.id IS NULL OR i.receipt_item_id=line.id)
                ) stocked ON TRUE
                CROSS JOIN LATERAL (
                    SELECT CASE WHEN line.id IS NULL THEN 0 ELSE 1 END AS line_count,
                           concat_ws(' ',line.goods_code_snapshot,line.goods_name_snapshot,goods.code,goods.name) AS goods_text,
                           ARRAY[COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code)] AS goods_codes,
                           ARRAY[COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name)] AS goods_names,
                           ARRAY(SELECT COALESCE(scoped.warehouse_id,h.warehouse_id)
                                 FROM procurement_inspection_items scoped
                                 WHERE scoped.receipt_type='%s' AND scoped.receipt_id=h.id
                                   AND scoped.status<>'REVERSED' AND (line.id IS NULL OR scoped.receipt_item_id=line.id)
                                 UNION SELECT h.warehouse_id WHERE NOT EXISTS (
                                   SELECT 1 FROM procurement_inspection_items scoped WHERE scoped.receipt_type='%s'
                                     AND scoped.receipt_id=h.id AND scoped.receipt_item_id=line.id AND scoped.status<>'REVERSED')) AS warehouse_ids,
                           (SELECT wh.name FROM procurement_inspection_items scoped JOIN warehouses wh ON wh.id=scoped.warehouse_id
                            WHERE scoped.receipt_type='%s' AND scoped.receipt_id=h.id AND scoped.receipt_item_id=line.id
                              AND scoped.status<>'REVERSED' ORDER BY scoped.id LIMIT 1) AS warehouse_name,
                           CASE WHEN line.id IS NOT NULL THEN jsonb_build_object('key',line.id,'itemId',line.id,'lineNo',line.line_no,
                               'goodsCode',COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code),
                               'goodsName',COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name),'specification',goods.spec,
                               'colorName',color.name,'unitName',unit.name,'quantity',line.qty,'weight',line.weight) END AS line_data
                    FROM (SELECT 1) single_line LEFT JOIN goods ON goods.id=line.goods_id
                    LEFT JOIN colors color ON color.id=line.color_id LEFT JOIN units unit ON unit.id=line.unit_id
                ) physical
                WHERE NOT h.is_deleted
                """).formatted(type,type,type,stage,type,historyType,table,itemTable,type,type,type,type,type,type,type)
                + (history ? "" : " AND h.status=1 AND h.legacy_id IS NULL AND inspection.receipt_id IS NOT NULL")
                + scope(scope,"physical.warehouse_ids");
    }

    private static String finishedTasks(WarehouseTaskScope scope) {
        return """
                SELECT task.task_id AS id, 'FINISHED'::text AS source_type,
                       CASE WHEN task.task_stage='ARRIVAL_REGISTRATION' THEN 'FINISHED_REGISTER'
                            ELSE 'FINISHED_COUNT' END AS record_type,
                       COALESCE(task.document_no,task.report_nos) AS bill_no, task.plan_no AS source_doc_no,
                       task.document_date AS business_date, NULL::text AS party_name,
                       COALESCE(physical.warehouse_name,task.warehouse_name) AS warehouse_name, NULL::text AS responsible_name,
                       NULL::text AS maker_name, 1 AS line_count,
                       CASE WHEN task.task_stage='ARRIVAL_REGISTRATION' THEN 'FINISHED_READY_REGISTER'
                            WHEN task.residual_task THEN 'FINISHED_RESIDUAL_COUNT'
                            ELSE 'FINISHED_READY_COUNT' END AS workflow_status,
                       CASE WHEN task.task_stage='ARRIVAL_REGISTRATION' THEN 'FINISHED_REGISTER'
                            ELSE 'FINISHED_COUNT' END AS action, task.task_id AS target_id,
                       jsonb_strip_nulls(jsonb_build_object('taskId',task.task_id,'reportId',task.report_id,
                           'documentId',task.document_id,'docType','FINISHED_IN','pendingQty',task.pending_qty,
                           'residualTask',task.residual_task,'publicQty',task.public_qty,
                           'actualSurplusQty',task.actual_surplus_qty)) || jsonb_strip_nulls(physical.action_data) AS action_data,
                       NULL::uuid AS maker_id, TRUE AS production_linked, task.created_at AS sort_time,
                       concat_ws(' ',task.document_no,task.report_nos,task.plan_no,physical.goods_code,physical.goods_name) AS search_text,
                       ARRAY[physical.goods_code] AS goods_codes, ARRAY[physical.goods_name] AS goods_names,
                       physical.line_data
                FROM task_documents task
                CROSS JOIN LATERAL (
                    SELECT goods.code AS goods_code,goods.name AS goods_name,warehouse.name AS warehouse_name,
                           ARRAY[goods.owning_warehouse_id] AS warehouse_ids,
                           jsonb_build_object('sourceReportItemId',item.id,'lotId',item.output_lot_id,
                               'pendingQty',item.qty,
                               'publicQty',CASE WHEN item.is_public_output AND NOT item.is_actual_surplus THEN item.qty ELSE 0 END,
                               'actualSurplusQty',CASE WHEN item.is_actual_surplus THEN item.qty ELSE 0 END) AS action_data,
                           jsonb_build_object('key',item.id,'itemId',item.id,'lineNo',item.line_no,
                               'goodsCode',goods.code,'goodsName',goods.name,'specification',goods.spec,
                               'colorName',color.name,'unitName',unit.name,'quantity',item.qty,'weight',item.weight) AS line_data
                    FROM (SELECT * FROM production_daily_report_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_daily_report_items',archive_origin.id)) item
                    JOIN v_production_report_items_pending_registration pending ON pending.report_item_id=item.id
                    JOIN goods ON goods.id=item.goods_id
                    LEFT JOIN colors color ON color.id=COALESCE(item.color_id,goods.color_id)
                    LEFT JOIN units unit ON unit.id=COALESCE(item.unit_id,goods.unit_id)
                    LEFT JOIN warehouses warehouse ON warehouse.id=goods.owning_warehouse_id
                    WHERE task.task_stage='ARRIVAL_REGISTRATION' AND item.report_id=task.report_id
                      AND item.destination='WAREHOUSE'
                    UNION ALL
                    SELECT COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                           COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),warehouse.name,
                           ARRAY[COALESCE(item.warehouse_id,document.warehouse_id)],
                           jsonb_build_object('documentItemId',item.id,'sourceReportItemId',item.source_daily_report_item_id),
                           jsonb_build_object('key',item.id,'itemId',item.id,'lineNo',item.line_no,
                               'goodsCode',COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                               'goodsName',COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),'specification',goods.spec,
                               'colorName',color.name,'unitName',unit.name,'quantity',item.qty,'weight',item.weight)
                    FROM (SELECT * FROM stock_document_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_document_items',archive_origin.id)) item JOIN (SELECT * FROM stock_documents archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_documents',archive_origin.id)) document ON document.id=item.doc_id
                    LEFT JOIN goods ON goods.id=item.goods_id LEFT JOIN colors color ON color.id=item.color_id
                    LEFT JOIN units unit ON unit.id=item.unit_id
                    LEFT JOIN warehouses warehouse ON warehouse.id=COALESCE(item.warehouse_id,document.warehouse_id)
                    WHERE task.task_stage='FINAL_COUNT' AND item.doc_id=task.document_id AND NOT item.is_deleted
                      AND (item.source_daily_report_item_id IS NOT NULL OR item.execution_segment_id IS NOT NULL)
                ) physical WHERE TRUE
                """ + scope(scope,"physical.warehouse_ids");
    }

    private static String finishedRegistrations(WarehouseTaskScope scope) {
        return """
                SELECT registration.id, 'FINISHED'::text AS source_type, 'FINISHED_REGISTRATION'::text AS record_type,
                       report.bill_no, sheet.sheet_no AS source_doc_no, report.bill_date AS business_date,
                       NULL::text AS party_name, registration.warehouse_name_snapshot AS warehouse_name,
                       registration.receiver_name_snapshot AS responsible_name, NULL::text AS maker_name,
                       facts.line_count,
                       CASE WHEN reversal.id IS NOT NULL THEN 'FINISHED_REGISTRATION_REVERSED'
                            WHEN report.status<>1 THEN 'FINISHED_SOURCE_REVERSED'
                            WHEN facts.active_count>0 AND facts.decided_count>0 THEN 'FINISHED_FQC_PARTIAL'
                            WHEN facts.active_count>0 AND registration.stock_in_before_inspection
                                 THEN 'FINISHED_PRE_STOCKED_FQC'
                            WHEN facts.active_count>0 THEN 'FINISHED_WAITING_FQC'
                            WHEN facts.failed_count>0 THEN 'FINISHED_FQC_REJECTED'
                            ELSE 'FINISHED_REGISTRATION_CLOSED' END AS workflow_status,
                       'FINISHED_ARRIVAL_DETAIL'::text AS action, registration.id AS target_id,
                       jsonb_strip_nulls(jsonb_build_object('registrationId',registration.id,
                          'reportId',registration.source_report_id,'sheetId',sheet.id,'registrationItemId',selected_item.id,
                          'sourceReportItemId',selected_item.source_report_item_id,
                          'reversible',reversal.id IS NULL AND report.status=1 AND NOT EXISTS (
                            SELECT 1 FROM production_finished_arrival_registration_items reversible_item
                            LEFT JOIN production_fqc_inspections reversible_inspection
                              ON reversible_inspection.source_report_item_id=reversible_item.source_report_item_id
                             AND reversible_inspection.status<>'CANCELLED'
                            WHERE reversible_item.registration_id=registration.id AND reversible_item.reversal_id IS NULL
                              AND (reversible_inspection.id IS NULL OR reversible_inspection.status<>'PENDING'
                                   OR reversible_inspection.passed_qty<>0 OR reversible_inspection.failed_qty<>0
                                   OR EXISTS(SELECT 1 FROM production_fqc_decision_events decision
                                             WHERE decision.inspection_id=reversible_inspection.id)
                                   OR EXISTS(SELECT 1 FROM production_fqc_release_commands command
                                             WHERE command.inspection_id=reversible_inspection.id)
                                   OR EXISTS(SELECT 1 FROM production_fqc_recovery_authorizations recovery
                                             WHERE recovery.source_inspection_id=reversible_inspection.id))))) AS action_data,
                       NULL::uuid AS maker_id, TRUE AS production_linked, registration.created_at AS sort_time,
                       concat_ws(' ',report.bill_no,sheet.sheet_no,registration.warehouse_name_snapshot,facts.goods_text) AS search_text,
                       facts.goods_codes, facts.goods_names,
                       jsonb_build_object('key',selected_item.id,'itemId',selected_item.id,'lineNo',selected_source.line_no,
                           'goodsCode',selected_goods.code,'goodsName',selected_goods.name,'specification',selected_goods.spec,
                           'colorName',selected_color.name,'unitName',selected_unit.name,'quantity',selected_source.qty,
                           'weight',selected_source.weight) AS line_data
                FROM production_finished_arrival_registrations registration
                JOIN production_finished_arrival_registration_items selected_item ON selected_item.registration_id=registration.id
                JOIN (SELECT * FROM production_daily_report_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_daily_report_items',archive_origin.id)) selected_source ON selected_source.id=selected_item.source_report_item_id
                LEFT JOIN goods selected_goods ON selected_goods.id=selected_source.goods_id
                LEFT JOIN colors selected_color ON selected_color.id=COALESCE(selected_source.color_id,selected_goods.color_id)
                LEFT JOIN units selected_unit ON selected_unit.id=COALESCE(selected_source.unit_id,selected_goods.unit_id)
                JOIN (SELECT * FROM production_daily_reports archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_daily_reports',archive_origin.id)) report ON report.id=registration.source_report_id AND NOT report.is_deleted
                LEFT JOIN production_finished_arrival_registration_reversals reversal
                  ON reversal.registration_id=registration.id
                LEFT JOIN LATERAL (
                    SELECT sheet.id,sheet.sheet_no FROM production_fqc_inspection_sheet_items item
                    JOIN production_fqc_inspection_sheets sheet ON sheet.id=item.sheet_id
                    WHERE item.registration_id=registration.id ORDER BY sheet.created_at,sheet.id LIMIT 1
                ) sheet ON TRUE
                CROSS JOIN LATERAL (
                    SELECT COUNT(DISTINCT item.id)::integer AS line_count,
                           COUNT(DISTINCT inspection.id) FILTER(WHERE inspection.status IN('PENDING','PARTIAL')) AS active_count,
                           COUNT(DISTINCT inspection.id) FILTER(WHERE inspection.passed_qty>0 OR inspection.failed_qty>0) AS decided_count,
                           COUNT(DISTINCT inspection.id) FILTER(WHERE inspection.failed_qty>0) AS failed_count,
                           string_agg(DISTINCT concat_ws(' ',goods.code,goods.name),' ') AS goods_text,
                           array_agg(DISTINCT goods.code) AS goods_codes, array_agg(DISTINCT goods.name) AS goods_names
                    FROM production_finished_arrival_registration_items item
                    JOIN (SELECT * FROM production_daily_report_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_daily_report_items',archive_origin.id)) report_item ON report_item.id=item.source_report_item_id
                    LEFT JOIN goods ON goods.id=report_item.goods_id
                    LEFT JOIN production_fqc_inspections inspection
                      ON inspection.source_report_item_id=item.source_report_item_id AND inspection.status<>'CANCELLED'
                    WHERE item.registration_id=registration.id AND item.id=selected_item.id
                ) facts
                WHERE TRUE
                """ + scope(scope,"ARRAY[registration.warehouse_id]");
    }

    private static String stockDocuments(Access access, WarehouseTaskScope scope) {
        String pool = access.productionPool()
                ? " OR (document.doc_type='FINISHED_IN' AND fn_is_production_linked_stock_document(document.id))"
                  + " OR (document.doc_type='WDRAW' AND fn_is_production_material_return_request(document.id))"
                : "";
        String scoped = scope.active() ? " AND ("
                + scope.predicate("COALESCE(physical.warehouse_id,document.warehouse_id)", ":warehouseScope")
                + " OR (document.status=0 AND document.maker_id::text=NULLIF(:ownDraftMaker,'')"
                + " AND NOT fn_is_production_material_return_request(document.id)))" : "";
        return """
                SELECT document.id,
                       CASE document.doc_type WHEN 'FINISHED_IN' THEN 'FINISHED' WHEN 'WDRAW' THEN 'RETURN'
                            ELSE 'OTHER' END AS source_type, 'STOCK_DOCUMENT'::text AS record_type,
                       document.bill_no, document.source_doc_no, document.bill_date AS business_date,
                       NULL::text AS party_name, COALESCE(physical.warehouse_name,warehouse.name) AS warehouse_name,
                       COALESCE(worker.full_name,'') AS responsible_name, maker.full_name AS maker_name,
                       physical.line_count,
                       CASE document.doc_type WHEN 'FINISHED_IN' THEN 'FINISHED_' WHEN 'WDRAW' THEN 'RETURN_'
                            ELSE 'OTHER_' END || CASE
                          WHEN document.status=-1 THEN 'REVERSED'
                          WHEN document.is_closed THEN 'CLOSED'
                          WHEN document.status=1 THEN 'STOCKED'
                          WHEN document.doc_type='WDRAW' AND fn_is_production_material_return_request(document.id)
                               THEN 'PENDING_RECEIVE'
                          WHEN document.doc_type='FINISHED_IN' AND NOT fn_is_production_linked_stock_document(document.id)
                               THEN 'LEGACY_DRAFT'
                          ELSE 'DRAFT' END AS workflow_status,
                       CASE WHEN document.status=0 AND NOT document.is_closed AND document.doc_type='WDRAW'
                                  AND fn_is_production_material_return_request(document.id) THEN 'RETURN_RECEIVE'
                            WHEN document.status=0 AND NOT document.is_closed AND document.doc_type<>'WDRAW'
                                  AND document.doc_type<>'FINISHED_IN'
                                  AND NOT fn_is_production_linked_stock_document(document.id)
                                  AND NOT EXISTS(SELECT 1 FROM stock_balance_adjustment_requests adjustment
                                                 WHERE adjustment.stock_document_id=document.id) THEN 'STOCK_EDIT'
                            ELSE 'STOCK_DETAIL' END AS action, document.id AS target_id,
                       jsonb_strip_nulls(jsonb_build_object('documentId',document.id,'documentItemId',physical.item_id,'docType',document.doc_type,
                           'reportId',document.source_daily_report_id,'authorizedBalanceAdjustment',
                           EXISTS(SELECT 1 FROM stock_balance_adjustment_requests adjustment
                                  WHERE adjustment.stock_document_id=document.id))) AS action_data,
                       document.maker_id, fn_is_production_linked_stock_document(document.id) AS production_linked,
                       document.created_at AS sort_time,
                       concat_ws(' ',document.bill_no,document.source_doc_no,warehouse.name,physical.goods_text) AS search_text,
                       physical.goods_codes, physical.goods_names, physical.line_data
                FROM (SELECT * FROM stock_documents archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_documents',archive_origin.id)) document
                LEFT JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                LEFT JOIN employees maker ON maker.id=document.maker_id
                LEFT JOIN employees worker ON worker.id=document.worker_id
                LEFT JOIN LATERAL (
                    SELECT 1 AS line_count,item.id AS item_id,
                           concat_ws(' ',item.goods_code_snapshot,item.goods_name_snapshot,goods.code,goods.name) AS goods_text,
                           ARRAY[COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code)] AS goods_codes,
                           ARRAY[COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)] AS goods_names,
                           COALESCE(item.warehouse_id,document.warehouse_id) AS warehouse_id,line_warehouse.name AS warehouse_name,
                           jsonb_build_object('key',item.id,'itemId',item.id,'lineNo',item.line_no,
                               'goodsCode',COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                               'goodsName',COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),'specification',goods.spec,
                               'colorName',color.name,'unitName',unit.name,'quantity',item.qty,'weight',item.weight) AS line_data
                    FROM (SELECT * FROM stock_document_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_document_items',archive_origin.id)) item LEFT JOIN goods ON goods.id=item.goods_id
                    LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=item.unit_id
                    LEFT JOIN warehouses line_warehouse ON line_warehouse.id=COALESCE(item.warehouse_id,document.warehouse_id)
                    WHERE item.doc_id=document.id AND NOT item.is_deleted
                ) physical ON TRUE
                WHERE document.doc_type IN('FINISHED_IN','OTHER_IN','WDRAW') AND NOT document.is_deleted
                  AND (%s %s)
                """.formatted(access.stockOwnerPredicate(),pool)
                + (access.productionPool() ? " AND NOT EXISTS(SELECT 1 FROM final_count_tasks task WHERE task.document_id=document.id)" : "")
                + scoped;
    }
}
