package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** One physical identity per source entity; filtering and paging happen after the union. */
final class WarehouseOutboundTaskCenterSql {
    private WarehouseOutboundTaskCenterSql() {}

    record Access(boolean sales, boolean subcontractTasks, boolean subcontractHistory,
                  boolean stock, boolean production, OwnerScope stockOwners) {}

    record Plan(String cte, Map<String, Object> parameters, String orderBy) {
        String countSql() { return cte + " SELECT COUNT(*) FROM filtered"; }
        String rowsSql() {
            return cte + " " + projection() + " FROM filtered " + orderBy + " LIMIT :limit OFFSET :offset";
        }
        String identitySql() { return cte + " " + projection() + " FROM filtered WHERE source_type=:rowSource AND record_type=:rowRecord AND id=:rowId"; }
        private String projection() {
            return """
                    SELECT source_type,record_type,id,bill_no,source_doc_no,business_date,
                           party_name,warehouse_name,responsible_name,line_count,status,
                           maker_id,stock_status,issue_status,revision,request_id,materials_defined,actionable
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
        if (scope.active()) parameters.put("warehouseScope", scope.idsCsv());
        parameters.put("keyword", filter.keyword() == null ? "" : filter.keyword().toLowerCase(java.util.Locale.ROOT));
        parameters.put("billNo", filter.billNo());
        parameters.put("dateFrom", filter.dateFrom());
        parameters.put("dateTo", filter.dateTo());
        parameters.put("status", filter.status());
        String union = String.join("\nUNION ALL\n", branches);
        if (union.isEmpty()) throw new IllegalArgumentException("No authorized outbound source");
        // Status facets omit only their own filter, while retaining source/owner/scope/search/date.
        String cte = """
                WITH source_rows(source_type,record_type,id,bill_no,source_doc_no,business_date,
                     party_name,warehouse_name,responsible_name,line_count,status,search_text,
                     maker_id,stock_status,issue_status,revision,request_id,materials_defined,actionable) AS (
                """ + union + """
                ), physical_rows AS (
                  SELECT source_rows.*,
                    (POSITION(CAST(:keyword AS text) IN LOWER(COALESCE(search_text,'')))>0
                     AND (CAST(:dateFrom AS date) IS NULL OR business_date>=CAST(:dateFrom AS date))
                     AND (CAST(:dateTo AS date) IS NULL OR business_date<=CAST(:dateTo AS date))) AS context_match
                  FROM source_rows
                ), filtered AS (
                  SELECT * FROM physical_rows WHERE context_match
                    AND (CAST(:billNo AS text) IS NULL OR bill_no=CAST(:billNo AS text))
                    AND (CAST(:status AS text) IS NULL OR status=CAST(:status AS text))
                )
                """;
        String direction = "asc".equals(filter.order()) ? "ASC" : "DESC";
        String primary = "billNo".equals(filter.sort()) ? "bill_no " + direction + " NULLS LAST,business_date DESC NULLS LAST"
                : "business_date " + direction + " NULLS LAST";
        return new Plan(cte, Collections.unmodifiableMap(parameters),
                " ORDER BY " + primary + ",source_type,record_type,id ");
    }

    private static boolean selected(String requested, String source) {
        return "ALL".equals(requested) || source.equals(requested);
    }

    private static String sales(WarehouseTaskScope scope) {
        String scopePredicate = scope.active() ? scope.predicateAny(
                "array_remove(ARRAY[s.warehouse_id] || COALESCE(lines.warehouse_ids,ARRAY[]::uuid[]),NULL)",
                ":warehouseScope") : "TRUE";
        return """
                SELECT 'SALES','SALES_SHIPMENT',s.id,s.bill_no,s.source_doc_no,s.bill_date,
                       COALESCE(client.name,''),COALESCE(warehouse.name,''),COALESCE(worker.full_name,maker.full_name,''),
                       lines.line_count,
                       CASE WHEN s.status=-1 OR s.warehouse_work_status='REVERSED' THEN 'SALES_REVERSED'
                            WHEN s.rejected OR s.warehouse_work_status='CANCELLED' THEN 'SALES_CANCELLED'
                            WHEN s.warehouse_work_status='SHIPPED' THEN 'SALES_SHIPPED'
                            WHEN s.warehouse_work_status='PENDING_PICK' THEN 'SALES_PENDING'
                            ELSE 'SALES_LEGACY' END,
                       CONCAT_WS(' ',s.bill_no,s.source_doc_no,client.name,warehouse.name,lines.goods),
                       s.owner_employee_id,s.status::int,NULL::int,s.review_revision::bigint,NULL::uuid,TRUE,
                       (s.warehouse_work_status='PENDING_PICK' AND s.status=0 AND NOT s.rejected)
                FROM sales_shipments s
                LEFT JOIN clients client ON client.id=s.client_id
                LEFT JOIN warehouses warehouse ON warehouse.id=s.warehouse_id
                LEFT JOIN employees worker ON worker.id=s.sender_id
                LEFT JOIN employees maker ON maker.id=s.maker_id
                LEFT JOIN LATERAL (
                  SELECT COUNT(*)::int AS line_count,array_agg(DISTINCT item.warehouse_id) AS warehouse_ids,
                         STRING_AGG(CONCAT_WS(' ',COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                                                  COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)),' ') AS goods
                  FROM sales_shipment_items item LEFT JOIN goods ON goods.id=item.goods_id
                  WHERE item.shipment_id=s.id AND NOT item.is_deleted
                ) lines ON TRUE
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
                       COALESCE(supplier.name,''),COALESCE(warehouse.name,''),COALESCE(worker.full_name,issue.maker_name,''),
                       lines.line_count,
                       CASE WHEN issue.is_deleted THEN 'SUBCONTRACT_WITHDRAWN'
                            WHEN issue.status=-1 THEN 'SUBCONTRACT_REVERSED'
                            WHEN issue.is_closed THEN 'SUBCONTRACT_CLOSED'
                            WHEN issue.status=1 THEN 'SUBCONTRACT_SHIPPED'
                            WHEN lines.plan_line_count>0 THEN 'SUBCONTRACT_PENDING'
                            ELSE 'SUBCONTRACT_DRAFT' END,
                       CONCAT_WS(' ',issue.bill_no,issue.source_doc_no,plan.order_bill_no,supplier.name,warehouse.name,lines.goods),
                       issue.maker_id,issue.status::int,NULL::int,0::bigint,NULL::uuid,TRUE,
                       (NOT issue.is_deleted AND NOT issue.is_closed AND issue.status=0 AND lines.plan_line_count>0)
                FROM subcontract_material_issues issue
                LEFT JOIN LATERAL (
                  SELECT COUNT(*)::int AS line_count,COUNT(plan_item.id)::int AS plan_line_count,
                         (array_agg(plan_item.plan_id ORDER BY plan_item.plan_id))[1] AS plan_id,
                         STRING_AGG(CONCAT_WS(' ',COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                                                  COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)),' ') AS goods
                  FROM subcontract_material_issue_items item
                  LEFT JOIN goods ON goods.id=item.goods_id
                  LEFT JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id
                  WHERE item.issue_id=issue.id AND (NOT item.is_deleted OR issue.is_deleted)
                ) lines ON TRUE
                LEFT JOIN subcontract_material_plans plan ON plan.id=lines.plan_id
                LEFT JOIN suppliers supplier ON supplier.id=issue.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id=issue.warehouse_id
                LEFT JOIN employees worker ON worker.id=issue.maker_id
                WHERE
                """ + readable + " AND " + scopePredicate;
    }

    private static String stock(String docType, String source, String owners, WarehouseTaskScope scope) {
        boolean draw = "DRAW".equals(docType);
        String scopePredicate = scope.active()
                ? "fn_stock_document_matches_warehouse_scope(d.id,CAST(:warehouseScope AS text),"
                    + scope.includeUnassigned() + "," + (draw ? "''::text" : "CAST(:ownDraftMaker AS text)") + ")"
                : "TRUE";
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
                AND (fn_production_draw_requested(d.id) OR (d.status=-1 AND EXISTS (
                  SELECT 1 FROM production_planning_package_document_items provenance
                  WHERE provenance.document_type='DRAW' AND provenance.document_id=d.id)))
                """ : "";
        String actionable = draw ? "(d.status IN(0,1) AND NOT d.is_closed AND d.issue_status<2"
                + " AND fn_is_production_linked_stock_document(d.id) AND fn_production_draw_pending(d.id))"
                : "(d.status=0 AND NOT d.is_closed)";
        return "SELECT '" + source + "','STOCK_DOC',d.id,d.bill_no,COALESCE(NULLIF(d.plan_no,''),d.source_doc_no),d.bill_date,"
                + "COALESCE(department.name,client.name,supplier.name,''),COALESCE(warehouse.name,''),COALESCE(worker.full_name,maker.full_name,''),"
                + "lines.line_count," + state + ",CONCAT_WS(' ',d.bill_no,d.plan_no,d.source_doc_no,department.name,warehouse.name,lines.goods),"
                + "d.maker_id,d.status::int,d.issue_status::int,0::bigint,discovery.request_id,TRUE," + actionable + "\n"
                + """
                FROM stock_documents d
                LEFT JOIN warehouses warehouse ON warehouse.id=d.warehouse_id
                LEFT JOIN departments department ON department.id=d.department_id
                LEFT JOIN clients client ON client.id=d.client_id
                LEFT JOIN suppliers supplier ON supplier.id=d.supplier_id
                LEFT JOIN employees worker ON worker.id=d.worker_id
                LEFT JOIN employees maker ON maker.id=d.maker_id
                LEFT JOIN LATERAL (
                  SELECT COUNT(*)::int AS line_count,
                         STRING_AGG(CONCAT_WS(' ',COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code),
                                                  COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name)),' ') AS goods
                  FROM stock_document_items item LEFT JOIN goods ON goods.id=item.goods_id
                  WHERE item.doc_id=d.id AND NOT item.is_deleted
                ) lines ON TRUE
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
        String scopePredicate = scope.active() ? scope.predicateAny(
                "COALESCE(material.warehouse_ids,ARRAY[]::uuid[])", ":warehouseScope") : "TRUE";
        String visibleDocumentScope = scope.active()
                ? " AND fn_stock_document_matches_warehouse_scope(document.id,CAST(:warehouseScope AS text),"
                    + scope.includeUnassigned() + ",''::text) " : "";
        return """
                SELECT 'DRAW','MATERIAL_DISCOVERY',request.id,request.request_no,plan.bill_no,
                       (request.created_at AT TIME ZONE 'Asia/Shanghai')::date,
                       COALESCE(department.name,''),COALESCE(material.warehouse_names,''),COALESCE(worker.full_name,''),
                       GREATEST(material.line_count,jsonb_array_length(request.requested_materials))::int,
                       CASE WHEN request.status='CANCELLED' THEN 'DRAW_DISCOVERY_CANCELLED'
                            WHEN request.status='CONFIGURED' THEN 'DRAW_DISCOVERY_CONFIGURED'
                            WHEN segment.is_deleted OR plan.is_deleted OR plan.is_closed OR plan.is_canceled OR plan.is_stopped
                              OR segment.status IN('CANCELLED','REVERSED') THEN 'DRAW_DISCOVERY_BLOCKED'
                            ELSE 'DRAW_DISCOVERY_PENDING' END,
                       CONCAT_WS(' ',request.request_no,plan.bill_no,department.name,material.warehouse_names,
                                      request.requested_materials::text,material.goods),
                       NULL::uuid,NULL::int,NULL::int,request.row_version::bigint,request.id,
                       request.status='CONFIGURED',
                       (request.status='PENDING' AND NOT segment.is_deleted AND NOT plan.is_deleted
                        AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
                        AND segment.status IN('WAITING','READY','DISPATCHED'))
                FROM production_material_discovery_requests request
                JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                JOIN production_plans plan ON plan.id=segment.plan_id
                LEFT JOIN departments department ON department.id=segment.workshop_department_id
                LEFT JOIN employees worker ON worker.id=segment.responsible_employee_id
                LEFT JOIN LATERAL (
                  SELECT COUNT(*)::int AS line_count,array_agg(DISTINCT line.warehouse_id) AS warehouse_ids,
                         STRING_AGG(DISTINCT warehouse.name,'、' ORDER BY warehouse.name) AS warehouse_names,
                         STRING_AGG(CONCAT_WS(' ',goods.code,goods.name),' ') AS goods
                  FROM production_material_discovery_lines line
                  LEFT JOIN warehouses warehouse ON warehouse.id=line.warehouse_id
                  LEFT JOIN goods ON goods.id=line.goods_id
                  WHERE line.request_id=request.id
                ) material ON TRUE
                WHERE NOT EXISTS (
                  SELECT 1 FROM production_material_discovery_lines linked
                  JOIN production_planning_package_document_items mapping
                    ON mapping.demand_id=linked.demand_id AND mapping.document_type='DRAW'
                  JOIN stock_documents document ON document.id=mapping.document_id
                    AND document.doc_type='DRAW' AND NOT document.is_deleted
                  WHERE linked.request_id=request.id
                    AND fn_is_production_linked_stock_document(document.id)
                    AND (fn_production_draw_requested(document.id) OR document.status=-1)
                """ + visibleDocumentScope + ") AND " + scopePredicate;
    }
}
