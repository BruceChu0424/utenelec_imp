package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.*;

/** Amount-free, correctly paged union of the warehouse's authorized outbound sources. */
@Service
public class WarehouseOutboundTaskCenterQueryService {
    private final EntityManager em;
    private final StockDocAccessPolicy stockAccess;
    private final SecurityContextCurrentUser currentUser;
    private final WarehouseTaskScopePort warehouseScopes;
    private final ProductionStockTaskAccessPolicy productionAccess;
    private final AuditDetailViewRecorder auditViews;
    private final WorkshopMaterialScope materialScopes;
    private final com.fasterxml.jackson.databind.ObjectMapper objectMapper;

    public WarehouseOutboundTaskCenterQueryService(EntityManager em, StockDocAccessPolicy stockAccess,
            SecurityContextCurrentUser currentUser, WarehouseTaskScopePort warehouseScopes,
            ProductionStockTaskAccessPolicy productionAccess, AuditDetailViewRecorder auditViews,
            WorkshopMaterialScope materialScopes, com.fasterxml.jackson.databind.ObjectMapper objectMapper) {
        this.em = em;
        this.stockAccess = stockAccess;
        this.currentUser = currentUser;
        this.warehouseScopes = warehouseScopes;
        this.productionAccess = productionAccess;
        this.auditViews = auditViews;
        this.materialScopes = materialScopes;
        this.objectMapper = objectMapper;
    }

    private static final Set<String> SOURCES = Set.of("ALL", "SALES", "SUBCONTRACT", "DRAW", "OTHER", "FINISHED");
    record State(String label, String tone) {}
    private static final Map<String, State> STATES = states();

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Page list(Filter requested) {
        Filter filter = normalize(requested);
        if (currentUser.get().isEmpty() || currentUser.get().orElseThrow().isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权查看仓库出库任务");
        }
        return warehouseScopes.withQueryScopeCache(() -> listScoped(filter));
    }

    private Page listScoped(Filter filter) {
        var scope = warehouseScopes.current(filter.scopeWarehouseId());
        var access = access(scope);
        Set<String> allowed = allowedSources(access);
        if (allowed.isEmpty() || (!"ALL".equals(filter.source()) && !allowed.contains(filter.source()))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权查看所选出库来源");
        }
        String ownDraftMaker = filter.scopeWarehouseId() == null
                ? currentUser.employeeId().map(UUID::toString).orElse("") : "";
        var sql = WarehouseOutboundTaskCenterSql.build(filter, access, scope, ownDraftMaker);
        long total = ((Number) bind(em.createNativeQuery(sql.countSql()), sql).getSingleResult()).longValue();
        int totalPages = (int) Math.min(Integer.MAX_VALUE, (total + filter.size() - 1L) / filter.size());
        int page = totalPages == 0 ? 1 : Math.min(filter.page(), totalPages);
        Query rows = bind(em.createNativeQuery(sql.rowsSql()), sql)
                .setParameter("limit", filter.size()).setParameter("offset", (long) (page - 1) * filter.size());
        List<Row> items = NativeQueryResults.objectArrayRows(rows).stream()
                .map(row -> map(row, access)).toList();
        Map<String, Long> counts = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(bind(em.createNativeQuery(sql.facetsSql()), sql))) {
            counts.put(String.valueOf(row[0]), ((Number) row[1]).longValue());
        }
        List<StatusFacet> facets = new ArrayList<>();
        STATES.forEach((key, value) -> {
            if (!WarehouseOutboundTaskCenterSql.visibleStatus(key,filter.view())) return;
            String source = key.substring(0, key.indexOf('_'));
            if (!allowed.contains(source) || (!"ALL".equals(filter.source()) && !source.equals(filter.source()))) return;
            if (source.equals("SUBCONTRACT") && !access.subcontractHistory() && !key.equals("SUBCONTRACT_PENDING")) return;
            if (key.startsWith("DRAW_DISCOVERY_") && !access.production()) return;
            facets.add(new StatusFacet(key, value.label(), counts.getOrDefault(key, 0L)));
        });
        List<StatusFacet> billNumbers = NativeQueryResults.objectArrayRows(bind(em.createNativeQuery(sql.billNoFacetsSql()), sql))
                .stream().map(row -> new StatusFacet(String.valueOf(row[0]), String.valueOf(row[0]), ((Number) row[1]).longValue())).toList();
        return new Page(items, page, filter.size(), total, totalPages, Map.of("status", facets, "billNo", billNumbers));
    }

    private Query bind(Query query, WarehouseOutboundTaskCenterSql.Plan sql) {
        sql.parameters().forEach(query::setParameter);
        return query;
    }

    private boolean has(String permission) { return stockAccess.hasAuthority(permission); }

    private WarehouseOutboundTaskCenterSql.Access access(WarehouseTaskScopePort.WarehouseTaskScope scope) {
        return new WarehouseOutboundTaskCenterSql.Access(
                has("warehouse_sales_outbound:view"), has("subcontract_outbound:view"),
                has("warehouse_subcontract_outbound_history:view"), has("stock_doc:view"),
                has("stock_doc:view") && productionAccess.canAccessWarehouseTasks(), stockAccess.scope(),
                WarehouseWorkshopMaterialTaskProjection.scope(has("workshop_material:view"),materialScopes,scope));
    }

    public record PhysicalLine(UUID id, Integer lineNo, String goodsCode, String goodsName,
                               String colorName, String unitName, BigDecimal quantity,
                               BigDecimal requestedQuantity, BigDecimal issuedQuantity,
                               BigDecimal weightKg, String stockPlace) {
        public String getQuantityExact(){return quantity==null?null:quantity.toPlainString();}
        public String getRequestedQuantityExact(){return requestedQuantity==null?null:requestedQuantity.toPlainString();}
        public String getIssuedQuantityExact(){return issuedQuantity==null?null:issuedQuantity.toPlainString();}
        public String getWeightKgExact(){return weightKg==null?null:weightKg.toPlainString();}
    }
    public record PhysicalDetail(Row document, List<PhysicalLine> lines,
                                 int page, int size, long total, int totalPages) {
        public PhysicalDetail { lines = List.copyOf(lines); }
    }

    /** Resolves the same authorized union row before reading a fixed physical line whitelist. */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public PhysicalDetail detail(String rowKey, UUID requestedWarehouse, int linePage, int lineSize) {
        return detail(rowKey,requestedWarehouse,linePage,lineSize,Map.of(),null,null);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public PhysicalDetail detail(String rowKey,UUID requestedWarehouse,int linePage,int lineSize,
            Map<String,String> columns,String sort,String order) {
        if (currentUser.get().isEmpty() || currentUser.get().orElseThrow().isVisitor()) throw notFound();
        String[] parts = rowKey == null ? new String[0] : rowKey.split(":", -1);
        if ((parts.length != 3 && parts.length != 4) || !SOURCES.contains(parts[0]) || parts[0].equals("ALL")
                || (parts.length == 4 && parts[3].isBlank())) throw notFound();
        UUID id;
        try {
            id = UUID.fromString(parts[2]);
            if (!id.toString().equalsIgnoreCase(parts[2])) throw notFound();
        } catch (IllegalArgumentException ex) { throw notFound(); }
        UUID documentId = id;
        return warehouseScopes.withQueryScopeCache(() -> {
            var scope = warehouseScopes.current(requestedWarehouse);
            var access = access(scope);
            if (!allowedSources(access).contains(parts[0])) throw notFound();
            var filter = normalize(new Filter(parts[0], null, null, null, null, null, requestedWarehouse, 1, 1,
                    null, null, TaskView.ALL));
            var sql = WarehouseOutboundTaskCenterSql.build(filter, access, scope,
                    requestedWarehouse == null ? currentUser.employeeId().map(UUID::toString).orElse("") : "");
            Query rowQuery = bind(em.createNativeQuery(sql.identitySql(parts.length == 4)), sql)
                    .setParameter("rowSource", parts[0]).setParameter("rowRecord", parts[1]).setParameter("rowId", documentId);
            if (parts.length == 4) rowQuery.setParameter("identityLineKey", parts[3]);
            List<Object[]> found = NativeQueryResults.objectArrayRows(rowQuery);
            if (found.isEmpty()) throw notFound();
            Row document = map(java.util.Arrays.copyOf(found.getFirst(), 19), access);
            if (document.recordType().equals("WORKSHOP_REQUISITION")) {
                Object warehouses=bindDetail(em.createNativeQuery(sql.cte()+"""
                         SELECT string_agg(DISTINCT warehouse_name,'、' ORDER BY warehouse_name) FROM filtered visible
                         WHERE visible.source_type=:rowSource AND visible.record_type=:rowRecord AND visible.id=:rowId
                           AND (:detailLineKey='' OR visible.line_key=:detailLineKey
                             OR split_part(visible.line_key,'~',1)=:detailLineKey)
                        """),sql,parts,documentId).getSingleResult();
                document=document.withWarehouseName(warehouses==null?"":warehouses.toString());
            }
            int size = Math.max(1, Math.min(500, lineSize));
            // The task's visible header never grants access to sibling items from another warehouse.
            String lineSql = scopedPhysicalLines(document);
            var headers=WarehousePhysicalDetailHeaders.criteria(columns,"to_jsonb(physical_detail)");
            String detailOrder=WarehousePhysicalDetailHeaders.order(sort,order,"to_jsonb(physical_detail)");
            lineSql="SELECT physical_detail.* FROM ("+lineSql+") physical_detail WHERE ("+headers.predicate()+")";
            Query countQuery=bindDetail(em.createNativeQuery(sql.cte()+" SELECT COUNT(*) FROM ("+lineSql+") physical_detail"),sql,parts,documentId)
                    .setParameter("documentId",documentId);
            headers.bind(countQuery);
            long total=((Number)countQuery.getSingleResult()).longValue();
            int pages = (int) ((total + size - 1) / size);
            int page = pages == 0 ? 1 : Math.max(1, Math.min(linePage, pages));
            Query lineQuery=bindDetail(em.createNativeQuery(
                    sql.cte() + " SELECT * FROM (" + lineSql + ") physical_detail ORDER BY "+detailOrder+" LIMIT :lineLimit OFFSET :lineOffset"), sql, parts, documentId)
                    .setParameter("documentId", documentId).setParameter("lineLimit", size)
                    .setParameter("lineOffset", (long) (page - 1) * size);
            headers.bind(lineQuery);
            List<PhysicalLine> lines=NativeQueryResults.objectArrayRows(lineQuery).stream().map(raw -> new PhysicalLine(
                        NativeValueConverters.uuid(raw[0]), raw[1] instanceof Number n ? n.intValue() : null,
                        NativeValueConverters.text(raw[2]), NativeValueConverters.text(raw[3]),
                        NativeValueConverters.text(raw[4]), NativeValueConverters.text(raw[5]),
                        decimalOrNull(raw[6]), decimalOrNull(raw[7]), decimalOrNull(raw[8]),
                        decimalOrNull(raw[9]), NativeValueConverters.text(raw[10]))).toList();
            String target = document.recordType().equals("WORKSHOP_REQUISITION") ? "workshop_material_requisitions"
                    : document.recordType().equals("SALES_SHIPMENT") ? "sales_shipments"
                    : document.recordType().equals("SUBCONTRACT_MATERIAL_ISSUE") ? "subcontract_material_issues"
                    : document.recordType().equals("MATERIAL_DISCOVERY") ? "production_material_discovery_requests" : "stock_documents";
            String action = document.recordType().equals("SALES_SHIPMENT") ? "view_sales_shipment_detail"
                    : document.recordType().equals("SUBCONTRACT_MATERIAL_ISSUE") ? "view_subcontract_material_issue_detail"
                    : "view_stock_document_detail";
            auditViews.recordHistory(action, target, documentId, document.billNo(), null, "仓库出库实物记录");
            return new PhysicalDetail(document, lines, page, size, total, pages);
        });
    }

    private Query bindDetail(Query query, WarehouseOutboundTaskCenterSql.Plan sql, String[] identity, UUID id) {
        return bind(query, sql).setParameter("rowSource", identity[0]).setParameter("rowRecord", identity[1])
                .setParameter("rowId", id).setParameter("detailLineKey", identity.length == 4 ? identity[3] : "");
    }

    static String scopedPhysicalLines(Row document) {
        return "SELECT detail.* FROM (" + physicalLines(document) + ") detail WHERE EXISTS ("
                + "SELECT 1 FROM filtered visible WHERE visible.source_type=:rowSource AND visible.record_type=:rowRecord"
                + " AND visible.id=:rowId AND (:detailLineKey='' OR visible.line_key=:detailLineKey"
                + " OR (visible.record_type='WORKSHOP_REQUISITION' AND split_part(visible.line_key,'~',1)=:detailLineKey))"
                + " AND (visible.item_id=detail.id OR (visible.item_id IS NULL AND visible.line_no=detail.line_no)))";
    }

    private static BigDecimal decimalOrNull(Object value) {
        return value == null ? null : NativeValueConverters.toBigDecimal(value);
    }

    private static ApiException notFound() { return new ApiException(ErrorCode.NOT_FOUND, "出库记录不存在或无权查看"); }

    static String physicalLines(Row document) {
        if (document.recordType().equals("WORKSHOP_REQUISITION")) {
            return """
                    SELECT physical.item_id AS id,line.line_no,goods.code AS "goodsCode",goods.name AS "goodsName",
                           color.name AS "colorName",unit.name AS "unitName",physical.quantity,
                           physical.requested_qty AS "requestedQuantity",physical.fulfilled_qty AS "issuedQuantity",
                           NULL::numeric AS "weightKg",goods.stock_place AS "stockPlace"
                    FROM workshop_material_requisition_lines line
                    JOIN workshop_material_requisitions request ON request.id=line.requisition_id
                    %s
                    JOIN goods ON goods.id=line.goods_id LEFT JOIN colors color ON color.id=line.color_id
                    LEFT JOIN units unit ON unit.id=line.unit_id WHERE line.requisition_id=:documentId
                    """.formatted(com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionFacts.physicalJoin());
        }
        if (document.recordType().equals("MATERIAL_DISCOVERY")) {
            if (document.status().equals("DRAW_DISCOVERY_PENDING") || document.status().equals("DRAW_DISCOVERY_CANCELLED")
                    || document.status().equals("DRAW_DISCOVERY_BLOCKED")) {
                return """
                        SELECT NULL::uuid AS id,suggestion.ordinality::int AS line_no,
                               COALESCE(NULLIF(suggestion.item->>'goodsCode',''),goods.code) AS "goodsCode",
                               COALESCE(NULLIF(suggestion.item->>'goodsName',''),goods.name) AS "goodsName",
                               COALESCE(NULLIF(suggestion.item->>'colorName',''),color.name) AS "colorName",
                               COALESCE(NULLIF(suggestion.item->>'unitName',''),unit.name) AS "unitName",
                               NULLIF(suggestion.item->>'qty','')::numeric AS quantity,NULL::numeric AS "requestedQuantity",
                               NULL::numeric AS "issuedQuantity",NULL::numeric AS "weightKg",suggestion.item->>'stockPlace' AS "stockPlace"
                        FROM production_material_discovery_requests request
                        CROSS JOIN LATERAL jsonb_array_elements(request.requested_materials) WITH ORDINALITY suggestion(item,ordinality)
                        LEFT JOIN goods ON goods.id=NULLIF(suggestion.item->>'goodsId','')::uuid
                        LEFT JOIN colors color ON color.id=NULLIF(suggestion.item->>'colorId','')::uuid
                        LEFT JOIN units unit ON unit.id=NULLIF(suggestion.item->>'unitId','')::uuid
                        WHERE request.id=:documentId
                        """;
            }
            return """
                    SELECT item.id,ROW_NUMBER() OVER(ORDER BY item.id)::int AS line_no,
                           goods.code AS "goodsCode",goods.name AS "goodsName",color.name AS "colorName",unit.name AS "unitName",
                           item.qty AS quantity,NULL::numeric AS "requestedQuantity",NULL::numeric AS "issuedQuantity",
                           NULL::numeric AS "weightKg",goods.stock_place AS "stockPlace"
                    FROM production_material_discovery_lines item
                    LEFT JOIN goods ON goods.id=item.goods_id LEFT JOIN colors color ON color.id=item.color_id
                    LEFT JOIN units unit ON unit.id=item.unit_id WHERE item.request_id=:documentId
                    """;
        }
        String table = document.recordType().equals("SALES_SHIPMENT") ? "sales_shipment_items"
                : document.recordType().equals("SUBCONTRACT_MATERIAL_ISSUE") ? "subcontract_material_issue_items" : "stock_document_items";
        String foreignKey = document.recordType().equals("SALES_SHIPMENT") ? "shipment_id"
                : document.recordType().equals("SUBCONTRACT_MATERIAL_ISSUE") ? "issue_id" : "doc_id";
        String requested = document.recordType().equals("SUBCONTRACT_MATERIAL_ISSUE") ? "item.requested_qty" : "NULL::numeric";
        String issued = document.sourceType().equals("DRAW") ? "item.issued_qty" : "NULL::numeric";
        String deleted = document.status().equals("SUBCONTRACT_WITHDRAWN") ? "" : " AND NOT item.is_deleted";
        return "SELECT item.id,item.line_no,COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code) AS \"goodsCode\","
                + "COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name) AS \"goodsName\",color.name AS \"colorName\","
                + "unit.name AS \"unitName\",item.qty AS quantity," + requested + " AS \"requestedQuantity\"," + issued
                + " AS \"issuedQuantity\",item.weight AS \"weightKg\",goods.stock_place AS \"stockPlace\" FROM " + table
                + " item LEFT JOIN goods ON goods.id=item.goods_id LEFT JOIN colors color ON color.id=item.color_id"
                + " LEFT JOIN units unit ON unit.id=item.unit_id WHERE item." + foreignKey + "=:documentId" + deleted;
    }

    static Set<String> allowedSources(WarehouseOutboundTaskCenterSql.Access access) {
        Set<String> sources = new java.util.LinkedHashSet<>();
        if (access.sales()) sources.add("SALES");
        if (access.subcontractTasks() || access.subcontractHistory()) sources.add("SUBCONTRACT");
        if (access.stock()) sources.addAll(List.of("DRAW", "OTHER", "FINISHED"));
        if (access.workshop().enabled()) sources.add("DRAW");
        return Set.copyOf(sources);
    }

    static Filter normalize(Filter filter) {
        String source = filter.source() == null || filter.source().isBlank() ? "ALL" : filter.source().trim().toUpperCase(Locale.ROOT);
        String status = clean(filter.status());
        if (status != null) status = status.toUpperCase(Locale.ROOT);
        if (!SOURCES.contains(source)) throw new ApiException(ErrorCode.VALIDATION_FAILED, "出库来源不正确");
        if (status != null && !STATES.containsKey(status)) throw new ApiException(ErrorCode.VALIDATION_FAILED, "出库状态不正确");
        if (filter.dateFrom() != null && filter.dateTo() != null && filter.dateFrom().isAfter(filter.dateTo())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "开始日期不能晚于结束日期");
        }
        String keyword = clean(filter.keyword());
        String billNo = clean(filter.billNo());
        if ((keyword != null && keyword.length() > 300) || (billNo != null && billNo.length() > 200)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "查询内容过长");
        }
        String sort = clean(filter.sort());
        if (sort != null && !WarehouseTaskHeaderQuery.sortable(sort)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "排序列不正确");
        }
        String order = clean(filter.order());
        order = order == null ? "desc" : order.toLowerCase(Locale.ROOT);
        if (!Set.of("asc", "desc").contains(order)) throw new ApiException(ErrorCode.VALIDATION_FAILED, "排序方向不正确");
        return new Filter(source, status, keyword, billNo, filter.dateFrom(), filter.dateTo(), filter.scopeWarehouseId(),
                Math.max(1, filter.page()), Math.max(1, Math.min(100, filter.size())), sort, order, filter.view(), filter.columnSearch());
    }

    private static String clean(String value) { return value == null || value.isBlank() ? null : value.trim(); }

    Row map(Object[] raw, WarehouseOutboundTaskCenterSql.Access access) {
        String source = String.valueOf(raw[0]);
        String record = String.valueOf(raw[1]);
        UUID id = NativeValueConverters.uuid(raw[2]);
        String status = String.valueOf(raw[11]);
        State state = STATES.get(status);
        if (state == null) throw new IllegalStateException("Unrecognized outbound projection status");
        UUID owner = NativeValueConverters.uuid(raw[12]);
        int stockStatus = raw[13] instanceof Number number ? number.intValue() : 0;
        int issueStatus = raw[14] instanceof Number number ? number.intValue() : 0;
        long revision = raw[15] instanceof Number number ? number.longValue() : 0L;
        UUID requestId = NativeValueConverters.uuid(raw[16]);
        boolean defined = Boolean.TRUE.equals(raw[17]);
        // Impersonation retains the same readable facts but never advertises command capability.
        boolean actionable = Boolean.TRUE.equals(raw[18])
                && currentUser.get().filter(actor -> actor.getImpersonatedBy() == null).isPresent();
        Map<String, Object> data = new LinkedHashMap<>();
        String action;
        boolean canHandle;
        switch (source) {
            case "SALES" -> {
                canHandle = actionable && owner != null && has("warehouse_sales_outbound:execute");
                action = status.equals("SALES_PENDING") ? "SALES_OUTBOUND" : "HISTORY_DETAIL";
                data.put("warehouseWorkStatus", status.equals("SALES_PENDING") ? "PENDING_PICK"
                        : status.equals("SALES_SHIPPED") ? "SHIPPED" : status.equals("SALES_REVERSED") ? "REVERSED"
                        : status.equals("SALES_CANCELLED") ? "CANCELLED" : "LEGACY_PENDING");
                data.put("allowedWarehouseTargets", canHandle ? List.of("SHIPPED") : List.of());
                data.put("reviewRevision", revision);
            }
            case "SUBCONTRACT" -> {
                canHandle = actionable && access.subcontractTasks()
                        && List.of("subcontract_outbound:execute", "subcontract_material_issue:view",
                                   "subcontract_material_issue:edit", "subcontract_material_issue:approve").stream().allMatch(this::has);
                action = actionable && access.subcontractTasks() ? "SUBCONTRACT_OUTBOUND" : "HISTORY_DETAIL";
                data.put("issueId", id);
                if (action.equals("HISTORY_DETAIL")) {
                    data.put("historyType", "subcontract-material-issues");
                    if (status.equals("SUBCONTRACT_WITHDRAWN")) {
                        data.put("retained", true);
                        data.put("historyEndpoint", "/warehouse/task-center/outbound/SUBCONTRACT:SUBCONTRACT_MATERIAL_ISSUE:" + id + "/detail");
                    }
                }
            }
            case "DRAW" -> {
                if (record.equals("WORKSHOP_REQUISITION")) {
                    canHandle = actionable && has("workshop_material:issue");
                    action = canHandle ? "WORKSHOP_REQUISITION" : "HISTORY_DETAIL";
                    if (!canHandle) data.put("historyEndpoint", "/warehouse/task-center/outbound/DRAW:WORKSHOP_REQUISITION:" + id + "/detail");
                    data.put("requisitionId",id);
                    data.put("kind","ISSUE");
                    data.put("expectedVersion",revision);
                    if (raw.length >= 29) data.put("requisitionLineId",UUID.fromString(String.valueOf(raw[19]).split("~",2)[0]));
                } else if (record.equals("MATERIAL_DISCOVERY")) {
                    canHandle = actionable && access.production() && has("stock_doc:approve") && has("stock_doc:issue");
                    action = canHandle ? "MATERIAL_DISCOVERY" : "HISTORY_DETAIL";
                    data.put("requestId", id);
                    data.put("materialsDefined", defined);
                    data.put("expectedVersion", revision);
                } else {
                    canHandle = actionable && access.production() && has("stock_doc:issue")
                            && (stockStatus != 0 || has("stock_doc:approve"));
                    action = canHandle ? "PRODUCTION_DRAW"
                            : status.equals("DRAW_REVERSED") ? "HISTORY_DETAIL" : "STOCK_DETAIL";
                    data.put("docType", "DRAW");
                    data.put("documentId", id);
                    data.put("stockStatus", stockStatus);
                    data.put("issueStatus", issueStatus);
                    data.put("materialsDefined", true);
                    if (requestId != null) data.put("requestId", requestId);
                }
            }
            case "OTHER", "FINISHED" -> {
                boolean canEdit = actionable && owner != null && has("stock_doc:edit")
                        && (access.stockOwners().seeAll() || access.stockOwners().writableOwners().contains(owner));
                boolean canApprove = actionable && owner != null && has("stock_doc:approve")
                        && (access.stockOwners().seeAll() || access.stockOwners().writableOwners().contains(owner));
                canHandle = canEdit || canApprove;
                action = canEdit ? "STOCK_EDIT" : canApprove ? "STOCK_REVIEW" : "STOCK_DETAIL";
                data.put("docType", source.equals("OTHER") ? "OTHER_OUT" : "FINISHED_OUT");
                data.put("documentId", id);
                data.put("canEdit", canEdit);
                data.put("canApprove", canApprove);
            }
            default -> throw new IllegalStateException("Unrecognized outbound source");
        }
        String documentKey = source + ":" + record + ":" + id;
        if (raw.length >= 29) {
            data.put("documentRowKey", documentKey);
            data.put("lineKey", String.valueOf(raw[19]));
            UUID itemId = NativeValueConverters.uuid(raw[20]);
            if (itemId != null) data.put("itemId", itemId);
        }
        Row row = new Row(documentKey, id, source, record,
                raw[3] == null ? null : raw[3].toString(), raw[4] == null ? null : raw[4].toString(),
                NativeValueConverters.toLocalDate(raw[5]),
                raw[6] == null ? "" : raw[6].toString(), raw[7] == null ? "" : raw[7].toString(),
                raw[8] == null ? "" : raw[8].toString(), raw[9] == null ? "" : raw[9].toString(),
                raw[10] instanceof Number number ? number.intValue() : 0,
                status, state.label(), state.tone(), action, id, canHandle, data, null, null);
        // 生产工单逐单 {code,planId}：供前端「生产工单」格弹窗按单跳生产计划详情；
        // 解析失败只少一个跳转通道，不影响显示列（productionOrderNo 文本仍完整）。
        if (raw.length > 30 && raw[30] != null) {
            try {
                data.put("productionOrders", objectMapper.readValue(raw[30].toString(),
                        objectMapper.getTypeFactory().constructCollectionType(List.class, Map.class)));
            } catch (java.io.IOException ignored) {
            }
        }
        Row mapped = raw.length < 29 ? row : row.withLine(new Line(String.valueOf(raw[19]), NativeValueConverters.uuid(raw[20]),
                raw[21] instanceof Number number ? number.intValue() : null,
                NativeValueConverters.text(raw[22]), NativeValueConverters.text(raw[23]), NativeValueConverters.text(raw[24]),
                NativeValueConverters.text(raw[25]), NativeValueConverters.text(raw[26]), decimalOrNull(raw[27]), decimalOrNull(raw[28])));
        return raw.length > 29 && raw[29] != null ? mapped.withProductionOrderNo(raw[29].toString()) : mapped;
    }

    private static Map<String, State> states() {
        Map<String, State> states = new LinkedHashMap<>();
        states.put("SALES_PENDING", new State("销售出库 · 待出库", "success"));
        states.put("SALES_SHIPPED", new State("销售出库 · 已出库", "neutral"));
        states.put("SALES_CANCELLED", new State("销售出库 · 已取消", "neutral"));
        states.put("SALES_REVERSED", new State("销售出库 · 已撤回", "danger"));
        states.put("SALES_LEGACY", new State("销售出库 · 历史状态待核对", "orange"));
        states.put("SUBCONTRACT_PENDING", new State("委外出库 · 待发料", "success"));
        states.put("SUBCONTRACT_DRAFT", new State("委外出库 · 草稿", "neutral"));
        states.put("SUBCONTRACT_SHIPPED", new State("委外出库 · 已发料", "neutral"));
        states.put("SUBCONTRACT_REVERSED", new State("委外出库 · 已撤回", "danger"));
        states.put("SUBCONTRACT_WITHDRAWN", new State("委外出库 · 领料已撤回", "neutral"));
        states.put("SUBCONTRACT_CLOSED", new State("委外出库 · 已完成", "neutral"));
        states.put("DRAW_PENDING", new State("生产领料 · 待出库", "success"));
        states.put("DRAW_PARTIAL", new State("生产领料 · 部分出库", "violet"));
        states.put("DRAW_SHIPPED", new State("生产领料 · 已出完", "neutral"));
        states.put("DRAW_REVERSED", new State("生产领料 · 已撤回", "danger"));
        states.put("DRAW_DISCOVERY_PENDING", new State("生产领料 · 待填写材料", "success"));
        states.put("DRAW_DISCOVERY_CONFIGURED", new State("生产领料 · 材料已登记", "neutral"));
        states.put("DRAW_DISCOVERY_CANCELLED", new State("生产领料 · 材料申请已取消", "neutral"));
        states.put("DRAW_DISCOVERY_BLOCKED", new State("生产领料 · 材料申请已失效", "danger"));
        states.put("DRAW_WORKSHOP_PENDING", new State("生产领料 · 内料仓待发料", "success"));
        states.put("DRAW_WORKSHOP_DONE", new State("生产领料 · 内料仓已发料", "neutral"));
        states.put("DRAW_WORKSHOP_CANCELLED", new State("生产领料 · 内料仓已取消", "neutral"));
        for (String source : List.of("OTHER", "FINISHED")) {
            String label = source.equals("OTHER") ? "其它出库" : "产成品出库";
            states.put(source + "_DRAFT", new State(label + " · 草稿待审核", "neutral"));
            states.put(source + "_APPROVED", new State(label + " · 已出库", "success"));
            states.put(source + "_REVERSED", new State(label + " · 已撤回", "danger"));
            states.put(source + "_CLOSED", new State(label + " · 已完成", "neutral"));
        }
        return java.util.Collections.unmodifiableMap(states);
    }
}
