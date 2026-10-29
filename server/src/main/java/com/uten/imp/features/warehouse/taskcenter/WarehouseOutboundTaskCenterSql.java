package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.security.OwnerVisibility.OwnerScope;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** One physical item per row; authorization, filtering and paging happen before delivery. */
final class WarehouseOutboundTaskCenterSql {
    private WarehouseOutboundTaskCenterSql() {}

    private static final java.util.Set<String> ACTIVE_STATUSES = java.util.Set.of(
            "SALES_PENDING","SALES_LEGACY","SUBCONTRACT_PENDING","SUBCONTRACT_DRAFT",
            "DRAW_PENDING","DRAW_PARTIAL","DRAW_DISCOVERY_PENDING","DRAW_WORKSHOP_PENDING","OTHER_DRAFT","FINISHED_DRAFT");
    private static final String ACTIVE_STATUS_PREDICATE = "status IN ("
            + ACTIVE_STATUSES.stream().sorted().map(status -> "'" + status + "'")
                    .collect(java.util.stream.Collectors.joining(",")) + ")";

    static boolean visibleStatus(String status, WarehouseTaskCenterContracts.TaskView view) {
        return view == WarehouseTaskCenterContracts.TaskView.ALL
                || (view == WarehouseTaskCenterContracts.TaskView.ACTIVE) == ACTIVE_STATUSES.contains(status);
    }

    record Access(boolean sales, boolean subcontractTasks, boolean subcontractHistory,
                  boolean stock, boolean production, OwnerScope stockOwners,
                  WarehouseWorkshopMaterialTaskProjection.Scope workshop) {
        Access(boolean sales, boolean subcontractTasks, boolean subcontractHistory,
               boolean stock, boolean production, OwnerScope stockOwners) {
            this(sales, subcontractTasks, subcontractHistory, stock, production, stockOwners,
                    WarehouseWorkshopMaterialTaskProjection.Scope.NONE);
        }
    }

    record Plan(String cte, Map<String, Object> parameters, String orderBy) {
        String countSql() { return cte + " SELECT COUNT(*) FROM filtered"; }
        String rowsSql() {
            return cte + " " + projection() + fromFiltered() + orderBy + " LIMIT :limit OFFSET :offset";
        }
        String identitySql() { return identitySql(false); }
        String identitySql(boolean selectedLine) {
            return cte + " " + projection() + fromFiltered()
                    + " WHERE source_type=:rowSource AND record_type=:rowRecord AND id=:rowId"
                    + (selectedLine ? " AND (line_key=:identityLineKey OR (record_type='WORKSHOP_REQUISITION'"
                        + " AND split_part(line_key,'~',1)=:identityLineKey))" : "")
                    + " ORDER BY line_no NULLS LAST,line_key LIMIT 1";
        }
        private String fromFiltered() {
            return " FROM filtered " + productionOrderJoin() + " ";
        }
        private String projection() {
            return """
                    SELECT source_type,record_type,id,bill_no,source_doc_no,business_date,
                           party_name,warehouse_name,responsible_name,maker_name,line_count,status,
                           maker_id,stock_status,issue_status,revision,request_id,materials_defined,actionable,
                           line_key,item_id,line_no,goods_code,goods_name,specification,color_name,unit_name,quantity,weight,
                           production_orders.production_order_no,
                           production_orders.production_orders::text
                    """;
        }
        /**
         * 领料单关联的生产工单（2026-10-29 用户批注）：工单 = production_execution_segments.segment_code。
         * 关联取三处权威链路（计划包单据 / 明细行执行段 / 计划包明细-需求）外加材料申请单自身的执行段；
         * 只在外层行查询对当页行求值，不进 UNION，避免全量历史逐行探测。
         * production_orders JSON 随行带回每个工单的 {code,planId}，前端弹窗按工单跳生产计划详情。
         */
        private String productionOrderJoin() {
            return """
                    LEFT JOIN LATERAL (
                      SELECT string_agg(DISTINCT segment.segment_code,'、' ORDER BY segment.segment_code) AS production_order_no,
                             jsonb_agg(DISTINCT jsonb_build_object('code',segment.segment_code,'planId',segment.plan_id::text)
                               ORDER BY jsonb_build_object('code',segment.segment_code,'planId',segment.plan_id::text)) AS production_orders
                      FROM production_execution_segments segment
                      WHERE segment.id IN (
                        SELECT package_document.execution_segment_id
                        FROM production_planning_package_documents package_document
                        WHERE package_document.document_id=filtered.id
                          AND package_document.document_type='DRAW'
                          AND package_document.execution_segment_id IS NOT NULL
                        UNION
                        SELECT draw_item.execution_segment_id
                        FROM stock_document_items draw_item
                        WHERE draw_item.doc_id=filtered.id AND NOT draw_item.is_deleted
                          AND draw_item.execution_segment_id IS NOT NULL
                        UNION
                        SELECT demand.execution_segment_id
                        FROM production_planning_package_document_items mapping
                        JOIN production_material_demands demand ON demand.id=mapping.demand_id
                        WHERE mapping.document_id=filtered.id AND mapping.document_type='DRAW'
                          AND demand.execution_segment_id IS NOT NULL
                        UNION
                        SELECT discovery_request.execution_segment_id
                        FROM production_material_discovery_requests discovery_request
                        WHERE filtered.record_type='MATERIAL_DISCOVERY' AND discovery_request.id=filtered.id
                      )
                    ) production_orders ON TRUE
                    """;
        }
        String facetsSql() {
            return cte + " " + """
                    SELECT status,COUNT(*) FROM physical_rows
                    WHERE context_match AND (CAST(:billNo AS text) IS NULL OR bill_no=CAST(:billNo AS text))
                    GROUP BY status ORDER BY status
                    """;
        }
        String billNoFacetsSql() {
            return cte + " " + """
                    SELECT bill_no,COUNT(*) FROM physical_rows
                    WHERE context_match AND (CAST(:status AS text) IS NULL OR status=CAST(:status AS text))
                      AND NULLIF(bill_no,'') IS NOT NULL
                    GROUP BY bill_no ORDER BY bill_no LIMIT 500
                    """;
        }
    }

    static Plan build(WarehouseTaskCenterContracts.Filter filter, Access access,
                      WarehouseTaskScope scope, String ownDraftMaker) {
        String source = filter.source();
        Map<String, Object> parameters = new LinkedHashMap<>();
        List<String> branches = new ArrayList<>();
        if (selected(source, "DRAW") && access.workshop().enabled()) {
            branches.add(WarehouseWorkshopMaterialTaskProjection.outbound(access.workshop()));
            parameters.putAll(access.workshop().parameters());
        }
        if (selected(source, "SALES") && access.sales()) branches.add(sales(scope));
        if (selected(source, "SUBCONTRACT") && (access.subcontractTasks() || access.subcontractHistory())) {
            branches.add(subcontract(scope, access));
        }
        boolean stockBranch = false;
        if (access.stock()) {
            String ownerPredicate = access.stockOwners().seeAll() ? "TRUE"
                    : access.stockOwners().visibleOwners().isEmpty() ? "FALSE" : "d.maker_id IN (:stockOwners)";
            if (selected(source, "DRAW")) {
                String drawReadable = access.production()
                        ? "(" + ownerPredicate + " OR fn_is_production_linked_stock_document(d.id))" : ownerPredicate;
                branches.add(stock("DRAW", "DRAW", drawReadable, scope));
                if (access.production()) branches.add(discovery(scope));
                stockBranch = true;
            }
            if (selected(source, "OTHER")) {
                branches.add(stock("OTHER_OUT", "OTHER", ownerPredicate, scope));
                stockBranch = true;
            }
            if (selected(source, "FINISHED")) {
                branches.add(stock("FINISHED_OUT", "FINISHED", ownerPredicate, scope));
                stockBranch = true;
            }
            if (stockBranch && ownerPredicate.contains(":stockOwners")) {
                parameters.put("stockOwners", access.stockOwners().visibleOwners());
            }
            if (scope.active() && (selected(source, "OTHER") || selected(source, "FINISHED"))) {
                parameters.put("ownDraftMaker", ownDraftMaker);
            }
        }
        parameters.putAll(TaskKeywordSearch.parameters(filter.keyword()));
        var headers = WarehouseTaskHeaderQuery.criteria(filter.columnSearch(), false);
        parameters.putAll(headers.parameters());
        parameters.put("billNo", filter.billNo());
        parameters.put("dateFrom", filter.dateFrom());
        parameters.put("dateTo", filter.dateTo());
        parameters.put("status", filter.status());
        parameters.put("view", filter.view().name());
        String union = String.join("\nUNION ALL\n", branches);
        if (union.isEmpty()) throw new IllegalArgumentException("No authorized outbound source");
        if (union.contains(":warehouseScope")) parameters.put("warehouseScope", scope.idsCsv());
        // Status facets omit only their own filter, while retaining source/owner/scope/search/date.
        String cte = """
                WITH source_rows(source_type,record_type,id,bill_no,source_doc_no,business_date,
                     party_name,warehouse_name,responsible_name,maker_name,line_count,status,search_text,
                     maker_id,stock_status,issue_status,revision,request_id,materials_defined,actionable,goods_codes,goods_names,
                     line_key,item_id,line_no,goods_code,goods_name,specification,color_name,unit_name,quantity,weight) AS (
                """ + union + """
                ), physical_rows AS (
                  SELECT source_rows.*, %s AS keyword_rank,
                    ((:view='ALL' OR (:view='ACTIVE')=(%s))
                     AND (%s) AND (%s)
                     AND (CAST(:dateFrom AS date) IS NULL OR business_date>=CAST(:dateFrom AS date))
                     AND (CAST(:dateTo AS date) IS NULL OR business_date<=CAST(:dateTo AS date))) AS context_match
                  FROM source_rows
                ), filtered AS (
                  SELECT * FROM physical_rows WHERE context_match
                    AND (CAST(:billNo AS text) IS NULL OR bill_no=CAST(:billNo AS text))
                    AND (CAST(:status AS text) IS NULL OR status=CAST(:status AS text))
                )
                """.formatted(TaskKeywordSearch.rankNamesFirst(filter.keyword(), new String[]{}, new String[]{"goods_names"},
                        new String[]{"bill_no", "source_doc_no"}, "goods_codes"),
                        ACTIVE_STATUS_PREDICATE, TaskKeywordSearch.condition(filter.keyword(),
                                "search_text", "party_name", "warehouse_name", "responsible_name", "maker_name"),headers.predicate());
        String direction = "asc".equals(filter.order()) ? "ASC" : "DESC";
        String primary = WarehouseTaskHeaderQuery.orderExpression(filter.sort(),false) + " " + direction + " NULLS LAST";
        // 平级次序补单号：同日期行按单号自然分组（同单明细相邻），不再依赖随机 UUID。
        return new Plan(cte, Collections.unmodifiableMap(parameters),
                " ORDER BY " + (filter.sort()==null||filter.sort().isBlank()?"keyword_rank,":"")
                        + primary + ",source_type,record_type,bill_no,id,line_no NULLS LAST,line_key ");
    }

    private static boolean selected(String requested, String source) {
        return "ALL".equals(requested) || source.equals(requested);
    }

    private static String sales(WarehouseTaskScope scope) {
        String scopePredicate = scope.active() ? scope.predicate(
                "COALESCE(item.warehouse_id,s.warehouse_id)", ":warehouseScope") : "TRUE";
        return """
                SELECT 'SALES','SALES_SHIPMENT',s.id,s.bill_no,s.source_doc_no,s.bill_date,
                       COALESCE(client.name,''),COALESCE(warehouse.name,''),
                       COALESCE(worker.full_name,''),COALESCE(maker.full_name,''),
                       CASE WHEN item.id IS NULL THEN 0 ELSE 1 END,
                       CASE WHEN s.status=-1 OR s.warehouse_work_status='REVERSED' THEN 'SALES_REVERSED'
                            WHEN s.rejected OR s.warehouse_work_status='CANCELLED' THEN 'SALES_CANCELLED'
                            WHEN s.warehouse_work_status='SHIPPED' THEN 'SALES_SHIPPED'
                            WHEN s.warehouse_work_status='PENDING_PICK' THEN 'SALES_PENDING'
                            ELSE 'SALES_LEGACY' END,
                       CONCAT_WS(' ',s.bill_no,s.source_doc_no,client.name,warehouse.name,
                         COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                         COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),goods.spec,color.name),
                       s.owner_employee_id,s.status::int,NULL::int,s.review_revision::bigint,NULL::uuid,TRUE,
                       (s.warehouse_work_status='PENDING_PICK' AND s.status=0 AND NOT s.rejected),
                       ARRAY[COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code)],
                       ARRAY[COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)],
                       COALESCE(item.id::text,'empty'),item.id,item.line_no,
                       COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                       COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),goods.spec,color.name,unit.name,item.qty,item.weight
                FROM (SELECT * FROM sales_shipments archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('sales_shipments',archive_origin.id)) s
                LEFT JOIN (SELECT * FROM sales_shipment_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('sales_shipment_items',archive_origin.id)) item ON item.shipment_id=s.id AND NOT item.is_deleted
                LEFT JOIN goods ON goods.id=item.goods_id
                LEFT JOIN colors color ON color.id=item.color_id
                LEFT JOIN units unit ON unit.id=item.unit_id
                LEFT JOIN clients client ON client.id=s.client_id
                LEFT JOIN warehouses warehouse ON warehouse.id=COALESCE(item.warehouse_id,s.warehouse_id)
                LEFT JOIN employees worker ON worker.id=s.sender_id
                LEFT JOIN employees maker ON maker.id=s.maker_id
                WHERE NOT s.is_deleted AND s.finance_audit=1 AND
                """ + scopePredicate;
    }

    private static String subcontract(WarehouseTaskScope scope, Access access) {
        String scopePredicate = scope.active() ? scope.predicate("issue.warehouse_id", ":warehouseScope") : "TRUE";
        String readable = "(" + (access.subcontractTasks()
                ? "(NOT issue.is_deleted AND NOT issue.is_closed AND issue.status=0 AND lines.plan_line_count>0)" : "FALSE")
                + " OR " + (access.subcontractHistory()
                ? "(NOT issue.is_deleted OR (issue.status=0 AND lines.plan_line_count>0))" : "FALSE") + ")";
        return """
                SELECT 'SUBCONTRACT','SUBCONTRACT_MATERIAL_ISSUE',issue.id,issue.bill_no,
                       COALESCE(plan.order_bill_no,issue.source_doc_no),issue.bill_date,
                       COALESCE(supplier.name,''),COALESCE(warehouse.name,''),NULL::text,
                       COALESCE(worker.full_name,issue.maker_name,''),
                       CASE WHEN item.id IS NULL THEN 0 ELSE 1 END,
                       CASE WHEN issue.is_deleted THEN 'SUBCONTRACT_WITHDRAWN'
                            WHEN issue.status=-1 THEN 'SUBCONTRACT_REVERSED'
                            WHEN issue.is_closed THEN 'SUBCONTRACT_CLOSED'
                            WHEN issue.status=1 THEN 'SUBCONTRACT_SHIPPED'
                            WHEN lines.plan_line_count>0 THEN 'SUBCONTRACT_PENDING'
                            ELSE 'SUBCONTRACT_DRAFT' END,
                       CONCAT_WS(' ',issue.bill_no,issue.source_doc_no,plan.order_bill_no,supplier.name,warehouse.name,
                         COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                         COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),goods.spec,color.name),
                       issue.maker_id,issue.status::int,NULL::int,0::bigint,NULL::uuid,TRUE,
                       (NOT issue.is_deleted AND NOT issue.is_closed AND issue.status=0 AND lines.plan_line_count>0),
                       ARRAY[COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code)],
                       ARRAY[COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)],
                       COALESCE(item.id::text,'empty'),item.id,item.line_no,
                       COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                       COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),goods.spec,color.name,unit.name,item.qty,item.weight
                FROM (SELECT * FROM subcontract_material_issues archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_material_issues',archive_origin.id)) issue
                LEFT JOIN LATERAL (
                  SELECT COUNT(plan_item.id)::int AS plan_line_count
                  FROM (SELECT * FROM subcontract_material_issue_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_material_issue_items',archive_origin.id)) item
                  LEFT JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id
                  WHERE item.issue_id=issue.id AND (NOT item.is_deleted OR issue.is_deleted)
                ) lines ON TRUE
                LEFT JOIN (SELECT * FROM subcontract_material_issue_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_material_issue_items',archive_origin.id)) item ON item.issue_id=issue.id AND (NOT item.is_deleted OR issue.is_deleted)
                LEFT JOIN goods ON goods.id=item.goods_id
                LEFT JOIN colors color ON color.id=item.color_id
                LEFT JOIN units unit ON unit.id=item.unit_id
                LEFT JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id
                LEFT JOIN subcontract_material_plans plan ON plan.id=plan_item.plan_id
                LEFT JOIN suppliers supplier ON supplier.id=issue.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id=issue.warehouse_id
                LEFT JOIN employees worker ON worker.id=issue.maker_id
                WHERE
                """ + readable + " AND " + scopePredicate;
    }

    private static String stock(String docType, String source, String owners, WarehouseTaskScope scope) {
        boolean draw = "DRAW".equals(docType);
        String scopePredicate = "TRUE";
        if (scope.active()) {
            String lineScope = scope.predicate("COALESCE(item.warehouse_id,d.warehouse_id)", ":warehouseScope");
            // V787: an explicit item warehouse overrides the header, including a header outside this scope.
            // Preserve the existing own-draft exception without changing the legacy document-scope function.
            scopePredicate = "(" + lineScope + (draw ? "" : " OR (d.status=0 AND d.maker_id::text=CAST(:ownDraftMaker AS text))") + ")";
        }
        String state = draw ? """
                CASE WHEN d.status=-1 THEN 'DRAW_REVERSED'
                     WHEN d.is_closed OR d.issue_status=2 THEN 'DRAW_SHIPPED'
                     WHEN d.issue_status=1 THEN 'DRAW_PARTIAL' ELSE 'DRAW_PENDING' END
                """ : """
                CASE WHEN d.status=-1 THEN '%s_REVERSED'
                     WHEN d.is_closed THEN '%s_CLOSED'
                     WHEN d.status=1 THEN '%s_APPROVED' ELSE '%s_DRAFT' END
                """.formatted(source,source,source,source);
        String requested = draw ? """
                -- Line-side DRAW records prove workshop custody and cost lineage. They are
                -- handled by production commands and never become ordinary warehouse tasks,
                -- including their fully issued or reversed history.
                AND NOT COALESCE(warehouse.is_line_side,FALSE)
                AND NOT COALESCE(item_warehouse.is_line_side,FALSE)
                AND (fn_production_draw_requested(d.id) OR (d.status=-1 AND EXISTS (
                  SELECT 1 FROM production_planning_package_document_items provenance
                  WHERE provenance.document_type='DRAW' AND provenance.document_id=d.id)))
                """ : "";
        String actionable = draw ? "(d.status IN(0,1) AND NOT d.is_closed AND d.issue_status<2"
                + " AND fn_is_production_linked_stock_document(d.id) AND fn_production_draw_pending(d.id))"
                : "(d.status=0 AND NOT d.is_closed)";
        return "SELECT '" + source + "','STOCK_DOC',d.id,d.bill_no,COALESCE(NULLIF(d.plan_no,''),d.source_doc_no),d.bill_date,"
                + "COALESCE(department.name,client.name,supplier.name,''),COALESCE(item_warehouse.name,warehouse.name,''),"
                + "COALESCE(worker.full_name,''),COALESCE(maker.full_name,''),"
                + "CASE WHEN item.id IS NULL THEN 0 ELSE 1 END," + state + ",CONCAT_WS(' ',d.bill_no,d.plan_no,d.source_doc_no,department.name,item_warehouse.name,warehouse.name,"
                + "COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),goods.spec,color.name),"
                + "d.maker_id,d.status::int,d.issue_status::int,0::bigint,discovery.request_id,TRUE," + actionable
                + ",ARRAY[COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code)],ARRAY[COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)],"
                + "COALESCE(item.id::text,'empty'),item.id,item.line_no,COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),"
                + "COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name),goods.spec,color.name,unit.name,item.qty,item.weight\n"
                + """
                FROM (SELECT * FROM stock_documents archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_documents',archive_origin.id)) d
                LEFT JOIN (SELECT * FROM stock_document_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_document_items',archive_origin.id)) item ON item.doc_id=d.id AND NOT item.is_deleted
                LEFT JOIN goods ON goods.id=item.goods_id
                LEFT JOIN colors color ON color.id=item.color_id
                LEFT JOIN units unit ON unit.id=item.unit_id
                LEFT JOIN warehouses item_warehouse ON item_warehouse.id=item.warehouse_id
                LEFT JOIN warehouses warehouse ON warehouse.id=d.warehouse_id
                LEFT JOIN departments department ON department.id=d.department_id
                LEFT JOIN clients client ON client.id=d.client_id
                LEFT JOIN suppliers supplier ON supplier.id=d.supplier_id
                LEFT JOIN employees worker ON worker.id=d.worker_id
                LEFT JOIN employees maker ON maker.id=d.maker_id
                LEFT JOIN LATERAL (
                  SELECT CASE WHEN COUNT(DISTINCT request.id)=1 THEN MIN(request.id::text)::uuid END AS request_id
                  FROM production_material_discovery_lines line
                  JOIN production_material_discovery_requests request ON request.id=line.request_id
                  JOIN production_planning_package_document_items mapping
                    ON mapping.demand_id=line.demand_id AND mapping.document_type='DRAW'
                  WHERE mapping.document_id=d.id
                ) discovery ON TRUE
                WHERE NOT d.is_deleted AND
                """ + "d.doc_type='" + docType + "' AND (" + owners + ") AND " + scopePredicate + " " + requested;
    }

    private static String discovery(WarehouseTaskScope scope) {
        String scopePredicate = scope.active() ? scope.predicate("material.warehouse_id", ":warehouseScope") : "TRUE";
        String visibleDocumentScope = scope.active()
                ? " AND " + scope.predicate("COALESCE(document_item.warehouse_id,document.warehouse_id)", ":warehouseScope") : "";
        return """
                SELECT 'DRAW','MATERIAL_DISCOVERY',request.id,request.request_no,plan.bill_no,
                       (request.created_at AT TIME ZONE 'Asia/Shanghai')::date,
                       COALESCE(department.name,''),COALESCE(material.warehouse_name,''),COALESCE(worker.full_name,''),NULL::text,
                       CASE WHEN material.line_key IS NULL THEN 0 ELSE 1 END,
                       CASE WHEN request.status='CANCELLED' THEN 'DRAW_DISCOVERY_CANCELLED'
                            WHEN request.status='CONFIGURED' THEN 'DRAW_DISCOVERY_CONFIGURED'
                            WHEN segment.is_deleted OR plan.is_deleted OR plan.is_closed OR plan.is_canceled OR plan.is_stopped
                              OR segment.status IN('CANCELLED','REVERSED') THEN 'DRAW_DISCOVERY_BLOCKED'
                            ELSE 'DRAW_DISCOVERY_PENDING' END,
                       CONCAT_WS(' ',request.request_no,plan.bill_no,department.name,material.warehouse_name,
                                      material.goods_code,material.goods_name,material.specification,material.color_name),
                       NULL::uuid,NULL::int,NULL::int,request.row_version::bigint,request.id,
                       request.status='CONFIGURED',
                       (request.status='PENDING' AND NOT segment.is_deleted AND NOT plan.is_deleted
                        AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
                        AND segment.status IN('WAITING','READY','DISPATCHED')),
                       ARRAY[material.goods_code],ARRAY[material.goods_name],COALESCE(material.line_key,'empty'),
                       material.item_id,material.line_no,material.goods_code,material.goods_name,
                       material.specification,material.color_name,material.unit_name,material.quantity,NULL::numeric
                FROM production_material_discovery_requests request
                JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                JOIN (SELECT * FROM production_plans archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_plans',archive_origin.id)) plan ON plan.id=segment.plan_id
                LEFT JOIN departments department ON department.id=segment.workshop_department_id
                LEFT JOIN employees worker ON worker.id=segment.responsible_employee_id
                LEFT JOIN LATERAL (
                  SELECT line.id::text AS line_key,line.id AS item_id,ROW_NUMBER() OVER(ORDER BY line.id)::int AS line_no,
                         line.warehouse_id,warehouse.name AS warehouse_name,goods.code AS goods_code,goods.name AS goods_name,
                         goods.spec AS specification,color.name AS color_name,unit.name AS unit_name,line.qty AS quantity
                  FROM production_material_discovery_lines line
                  LEFT JOIN warehouses warehouse ON warehouse.id=line.warehouse_id
                  LEFT JOIN goods ON goods.id=line.goods_id
                  LEFT JOIN colors color ON color.id=line.color_id
                  LEFT JOIN units unit ON unit.id=line.unit_id
                  WHERE line.request_id=request.id AND request.status='CONFIGURED'
                  UNION ALL
                  SELECT 'suggestion-' || suggestion.ordinality,NULL::uuid,suggestion.ordinality::int,
                         NULL::uuid,NULL::text,
                         COALESCE(NULLIF(suggestion.item->>'goodsCode',''),goods.code),
                         COALESCE(NULLIF(suggestion.item->>'goodsName',''),goods.name),
                         COALESCE(NULLIF(suggestion.item->>'spec',''),goods.spec),
                         COALESCE(NULLIF(suggestion.item->>'colorName',''),color.name),
                         COALESCE(NULLIF(suggestion.item->>'unitName',''),unit.name),
                         NULLIF(suggestion.item->>'qty','')::numeric
                  FROM jsonb_array_elements(request.requested_materials) WITH ORDINALITY suggestion(item,ordinality)
                  LEFT JOIN goods ON goods.id=NULLIF(suggestion.item->>'goodsId','')::uuid
                  LEFT JOIN colors color ON color.id=NULLIF(suggestion.item->>'colorId','')::uuid
                  LEFT JOIN units unit ON unit.id=NULLIF(suggestion.item->>'unitId','')::uuid
                  WHERE request.status<>'CONFIGURED'
                ) material ON TRUE
                WHERE NOT EXISTS (
                  SELECT 1 FROM production_material_discovery_lines linked
                  JOIN production_planning_package_document_items mapping
                    ON mapping.demand_id=linked.demand_id AND mapping.document_type='DRAW'
                  JOIN (SELECT * FROM stock_documents archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_documents',archive_origin.id)) document ON document.id=mapping.document_id
                    AND document.doc_type='DRAW' AND NOT document.is_deleted
                  JOIN (SELECT * FROM stock_document_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('stock_document_items',archive_origin.id)) document_item ON document_item.id=mapping.document_item_id
                    AND document_item.doc_id=document.id AND NOT document_item.is_deleted
                  WHERE linked.request_id=request.id
                    AND (material.item_id IS NULL OR linked.id=material.item_id)
                    AND fn_is_production_linked_stock_document(document.id)
                    AND (fn_production_draw_requested(document.id) OR document.status=-1)
                """ + visibleDocumentScope + ") AND " + scopePredicate;
    }
}
