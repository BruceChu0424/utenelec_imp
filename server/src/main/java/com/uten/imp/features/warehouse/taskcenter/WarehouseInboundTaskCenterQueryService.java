package com.uten.imp.features.warehouse.taskcenter;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInPermissions;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Page;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Row;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.StatusFacet;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** A single authorized relation for every inbound stage; commands remain in their original services. */
@Service
@RequiredArgsConstructor
public class WarehouseInboundTaskCenterQueryService {
    private static final Set<String> SOURCES = Set.of("ALL","PURCHASE","SUBCONTRACT","FINISHED","OTHER","RETURN");
    private static final Map<String, Presentation> STATUSES = statuses();
    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final SecurityContextCurrentUser currentUser;
    private final WarehouseTaskScopePort warehouseScopes;
    private final StockDocAccessPolicy stockAccess;
    private final ProductionStockTaskAccessPolicy productionAccess;

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Page list(Filter filter) {
        return list(filter,null);
    }

    private Page list(Filter filter,Identity identity) {
        String source = normalize(filter.source(), "ALL");
        if (!SOURCES.contains(source)) throw invalid("入库来源不正确");
        String status = normalize(filter.status(), "");
        if (!status.isEmpty() && !STATUSES.containsKey(status)) throw invalid("入库状态不正确");
        if (filter.sort()!=null && !filter.sort().isBlank() && !Set.of("billNo","businessDate").contains(filter.sort())) {
            throw invalid("入库排序字段不正确");
        }
        if (filter.order()!=null && !filter.order().isBlank() && !Set.of("asc","desc").contains(filter.order().toLowerCase(Locale.ROOT))) {
            throw invalid("入库排序方向不正确");
        }
        if (filter.dateFrom()!=null && filter.dateTo()!=null && filter.dateFrom().isAfter(filter.dateTo())) {
            throw invalid("开始日期不能晚于结束日期");
        }
        AuthUser actor = currentUser.get().filter(user -> !user.isVisitor())
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN,"没有仓库入库查看权限"));
        Rights rights = new Rights(actor, productionAccess.canAccessWarehouseTasks(), stockAccess.scope());
        if (!rights.anyView() || !rights.sourceAllowed(source)) {
            throw new ApiException(ErrorCode.FORBIDDEN,"没有该入库来源的查看权限");
        }
        return warehouseScopes.withQueryScopeCache(() -> listScoped(filter, identity, source, status, actor, rights));
    }

    private Page listScoped(Filter filter, Identity identity, String source, String status, AuthUser actor, Rights rights) {
        var scope = warehouseScopes.current(filter.scopeWarehouseId());
        var owner = stockAccess.nativeReadScope("document.maker_id", "stockOwners", rights.owner());
        var access = new WarehouseInboundTaskCenterSql.Access(rights.inbound(),rights.purchaseHistory(),
                rights.subcontractHistory(),rights.quality(),rights.stock(),rights.productionPool(),owner.predicate());
        String base = WarehouseInboundTaskCenterSql.base(access,scope,filter.keyword());
        int page = Math.max(1,filter.page());
        int size = Math.max(1,Math.min(100,filter.size()));
        MapSqlParameterSource parameters = new MapSqlParameterSource()
                .addValue("type","ALL").addValue("source",source).addValue("status",status)
                .addValue("view",filter.view().name())
                .addValue("billNo",text(filter.billNo()).isEmpty()?null:text(filter.billNo()))
                .addValue("dateFrom",filter.dateFrom()).addValue("dateTo",filter.dateTo())
                .addValue("warehouseScope",scope.idsCsv())
                .addValue("ownDraftMaker",filter.scopeWarehouseId()==null && actor.getEmployeeId()!=null
                        ? actor.getEmployeeId().toString():"")
                .addValue("limit",size).addValue("offset",((long)page-1)*size);
        parameters.addValues(TaskKeywordSearch.parameters(filter.keyword()));
        if (owner.parameterName()!=null) parameters.addValue(owner.parameterName(),owner.owners());
        String identityFilter="";
        if(identity!=null) {
            parameters.addValue("rowId",identity.id()).addValue("recordType",identity.record());
            identityFilter=" AND id=:rowId AND record_type=:recordType";
        }
        Long total = jdbc.queryForObject(WarehouseInboundTaskCenterSql.count(base)+identityFilter,parameters,Long.class);
        long count=total==null?0:total;
        long pages=count==0?0:(count+size-1)/size;
        int effectivePage=count==0?1:(int)Math.min(page,Math.min(Integer.MAX_VALUE,pages));
        parameters.addValue("offset",((long)effectivePage-1)*size);
        List<Row> rows = jdbc.query(WarehouseInboundTaskCenterSql.rows(base,filter.sort(),filter.order(),identityFilter),parameters,
                (rs,index) -> row(rs,rights));
        if(identity!=null) return new Page(rows,1,1,count,rows.isEmpty()?0:1,Map.of());
        List<StatusFacet> facets = jdbc.query(WarehouseInboundTaskCenterSql.facets(base),parameters,(rs,index) -> {
            String code=rs.getString(1);
            Presentation presentation=presentation(code);
            return new StatusFacet(code,presentation.label(),rs.getLong(2));
        });
        List<StatusFacet> billNos=jdbc.query(WarehouseInboundTaskCenterSql.billNoFacets(base),parameters,
                (rs,index)->new StatusFacet(rs.getString(1),rs.getString(1),rs.getLong(2)));
        return new Page(rows,effectivePage,size,count,(int)Math.min(Integer.MAX_VALUE,pages),Map.of("status",facets,"billNo",billNos));
    }

    /** Visible rows have a scope-checked physical read target even when the business document was reversed. */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> detail(String rowKey,UUID warehouseId) {
        return detail(rowKey,warehouseId,1,50);
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> detail(String rowKey,UUID warehouseId,int linePage,int lineSize) {
        String[] parts=rowKey==null?new String[0]:rowKey.split(":",-1);
        if(parts.length!=3 || !SOURCES.contains(parts[0]) || parts[0].equals("ALL")) throw invalid("入库记录身份不正确");
        UUID id;
        try { id=UUID.fromString(parts[2]); } catch(IllegalArgumentException failure) { throw invalid("入库记录身份不正确"); }
        return warehouseScopes.withQueryScopeCache(() -> detailScoped(parts, id, warehouseId, linePage, lineSize));
    }

    private Map<String,Object> detailScoped(String[] parts, UUID id, UUID warehouseId, int linePage, int lineSize) {
        Page page=list(new Filter(parts[0],"","",null,null,null,warehouseId,1,1,null,null,
                WarehouseTaskCenterContracts.TaskView.ALL),new Identity(id,parts[1]));
        if(page.items().isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,"入库记录不存在或已不在当前范围");
        Row row=page.items().getFirst();
        MapSqlParameterSource parameters=new MapSqlParameterSource("id",id);
        String sql=switch(row.recordType()) {
            case "PURCHASE_RECEIPT","SUBCONTRACT_RECEIPT" -> """
                    SELECT item.id, item.line_no AS "lineNo", COALESCE(NULLIF(item.goods_code_snapshot,''),goods.code) AS "goodsCode",
                           COALESCE(NULLIF(item.goods_name_snapshot,''),goods.name) AS "goodsName",
                           color.name AS "colorName", unit.name AS "unitName", base_unit.name AS "baseUnitName", item.qty AS quantity,
                           item.weight, %s AS "giftQty",quality.passed AS "passedBaseQty",
                           quality.failed AS "failedBaseQty",quality.stocked AS "stockedBaseQty",
                           item.receipt_id AS "receiptId",item.order_item_id AS "orderItemId"
                    FROM %s item LEFT JOIN goods ON goods.id=item.goods_id
                    LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=item.unit_id
                    LEFT JOIN units base_unit ON base_unit.id=goods.unit_id
                    LEFT JOIN LATERAL (
                        SELECT SUM(inspection.passed_base_qty) AS passed,SUM(inspection.failed_base_qty) AS failed,
                               SUM(inspection.warehouse_stocked_base_qty) AS stocked
                        FROM procurement_inspection_items inspection
                        WHERE inspection.receipt_type='%s' AND inspection.receipt_item_id=item.id
                          AND inspection.status<>'REVERSED'
                    ) quality ON TRUE
                    WHERE item.receipt_id=:id AND NOT item.is_deleted ORDER BY item.line_no,item.id
                    """.formatted(row.sourceType().equals("PURCHASE")?"item.gift_qty":"NULL::numeric",
                        row.sourceType().equals("PURCHASE")?"purchase_receipt_items":"subcontract_receipt_items",row.sourceType());
            case "STOCK_DOCUMENT","FINISHED_COUNT" -> """
                    SELECT item.id,item.line_no AS "lineNo",item.goods_code_snapshot AS "goodsCode",
                           item.goods_name_snapshot AS "goodsName",color.name AS "colorName",unit.name AS "unitName",
                           item.qty AS quantity,item.weight,item.place,item.count_qty AS "countedQty"
                    FROM stock_document_items item LEFT JOIN colors color ON color.id=item.color_id
                    LEFT JOIN units unit ON unit.id=item.unit_id
                    WHERE item.doc_id=:id AND NOT item.is_deleted ORDER BY item.line_no,item.id
                    """;
            case "FINISHED_REGISTRATION" -> """
                    SELECT item.id,item.registration_id AS "registrationId",item.source_report_item_id AS "sourceReportItemId",
                           source.output_lot_id AS "lotId",goods.code AS "goodsCode",goods.name AS "goodsName",
                           color.name AS "colorName",unit.name AS "unitName",source.qty AS quantity,item.place_snapshot AS place,
                           lineage.document_nos AS "stockDocumentNos",lineage.document_ids AS "stockDocumentIds"
                    FROM production_finished_arrival_registration_items item
                    JOIN production_daily_report_items source ON source.id=item.source_report_item_id
                    LEFT JOIN goods ON goods.id=source.goods_id LEFT JOIN colors color ON color.id=source.color_id
                    LEFT JOIN units unit ON unit.id=goods.unit_id
                    LEFT JOIN LATERAL (
                        SELECT string_agg(DISTINCT document.bill_no,'、') AS document_nos,
                               string_agg(DISTINCT document.id::text,',') AS document_ids
                        FROM production_fqc_inspection_sheet_items sheet_item
                        JOIN production_fqc_release_commands release ON release.inspection_id=sheet_item.inspection_id
                        JOIN stock_document_items released_item ON released_item.id=release.stock_document_item_id
                        JOIN stock_documents document ON document.id=released_item.doc_id AND NOT document.is_deleted
                        WHERE sheet_item.registration_id=item.registration_id
                          AND release.source_report_item_id=item.source_report_item_id
                    ) lineage ON TRUE
                    WHERE item.registration_id=:id ORDER BY item.id
                    """;
            case "FINISHED_REGISTER" -> """
                    SELECT source.id,source.output_lot_id AS "lotId",goods.code AS "goodsCode",goods.name AS "goodsName",
                           color.name AS "colorName",source.qty AS quantity
                    FROM production_daily_report_items source
                    JOIN v_production_report_items_pending_registration pending ON pending.report_item_id=source.id
                    LEFT JOIN goods ON goods.id=source.goods_id LEFT JOIN colors color ON color.id=source.color_id
                    WHERE source.report_id=:id ORDER BY source.id
                    """;
            case "EXPECTATION" -> """
                    SELECT item.id,goods.code AS "goodsCode",goods.name AS "goodsName",color.name AS "colorName",
                           unit.name AS "unitName",item.ordered_qty AS "orderedQty",item.accepted_qty AS "acceptedQty",
                           (%s) AS "remainingQty",(%s) AS "giftRemainingQty"
                    FROM inbound_expectation_items item LEFT JOIN goods ON goods.id=item.goods_id
                    LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=item.unit_id
                    JOIN inbound_expectations expectation ON expectation.id=item.expectation_id
                    WHERE item.expectation_id=:id AND (expectation.order_type<>'SUBCONTRACT' OR (%s))
                    ORDER BY item.line_no,item.id
                    """.formatted(com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService.taskCenterReceivableQuantity(),
                        com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService.taskCenterReceivableGiftQuantity(),
                        com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService.taskCenterItemVisiblePredicate());
            case "ARRIVAL_EXCEPTION" -> """
                    SELECT exception.id,exception.receipt_id AS "receiptId",exception.receipt_item_id AS "receiptItemId",
                           exception.order_item_id AS "orderItemId",exception.receipt_bill_no_snapshot AS "receiptBillNo",
                           exception.order_bill_no_snapshot AS "orderBillNo",goods.code AS "goodsCode",goods.name AS "goodsName",
                           color.name AS "colorName",unit.name AS "unitName",exception.declared_qty AS quantity,
                           exception.approved_remaining_qty AS "approvedRemainingQty",exception.accepted_qty AS "acceptedQty",
                           exception.unaccepted_qty AS "unacceptedQty",exception.status,exception.version,
                           exception.decision,exception.finance_reason AS "decisionReason"
                    FROM procurement_arrival_exceptions exception JOIN goods ON goods.id=exception.goods_id
                    LEFT JOIN colors color ON color.id=exception.color_id LEFT JOIN units unit ON unit.id=exception.unit_id
                    WHERE exception.id=:id ORDER BY exception.id
                    """;
            default -> null;
        };
        int safePage=Math.max(1,linePage),safeSize=Math.max(1,Math.min(100,lineSize));
        long total;
        List<Map<String,Object>> items;
        if(sql==null) { total=1;items=safePage==1?List.of(row.actionData()):List.of(); }
        else {
            Long count=jdbc.queryForObject("SELECT COUNT(*) FROM ("+sql+") detail_rows",parameters,Long.class);
            total=count==null?0:count;
            parameters.addValue("lineLimit",safeSize).addValue("lineOffset",((long)safePage-1)*safeSize);
            items=jdbc.queryForList(sql+" LIMIT :lineLimit OFFSET :lineOffset",parameters);
        }
        return Map.of("row",row,"items",items,"page",safePage,"size",safeSize,"total",total,
                "totalPages",(int)Math.min(Integer.MAX_VALUE,total==0?0:(total+safeSize-1)/safeSize));
    }

    private record Identity(UUID id,String record) {}

    private Row row(ResultSet rs,Rights rights) throws SQLException {
        UUID id=rs.getObject("id",UUID.class);
        String source=rs.getString("source_type");
        String record=rs.getString("record_type");
        String status=rs.getString("workflow_status");
        Presentation presentation=presentation(status);
        Map<String,Object> data;
        try { data=objectMapper.readerFor(new TypeReference<Map<String,Object>>() {})
                .with(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
                .readValue(rs.getString("action_data")); }
        catch (java.io.IOException exception) { throw new SQLException("入库物理身份解析失败",exception); }
        String proposed=rs.getString("action");
        boolean canHandle=switch(proposed) {
            case "ARRIVAL_REGISTER","ARRIVAL_CONTINUE" -> rights.inbound() && rights.has("warehouse_inbound:stock_in");
            case "ARRIVAL_EXCEPTION" -> status.endsWith("_EXCEPTION_RECEIPT_ADJUSTED")
                    && positive(data,"acceptedQty") && number(data,"expectedVersion")>0
                    && rights.inbound() && rights.has("warehouse_inbound:stock_in");
            case "QUALITY_RESULT" -> rights.quality() && (
                    number(data,"pendingSliceCount")>0
                            && rights.has("warehouse_iqc_stock_in:view") && rights.has("warehouse_iqc_stock_in:confirm")
                    || number(data,"pendingReturnCount")>0
                            && rights.has("procurement_iqc_rejection:record_return")
                    || number(data,"openItemCount")>number(data,"preStockedLineCount")
                            && rights.has("warehouse_iqc_stock_in:view") && rights.has("warehouse_iqc_stock_in:before_inspection"));
            case "FINISHED_REGISTER","FINISHED_COUNT","RETURN_RECEIVE" -> rights.productionPool()
                    && rights.has("stock_doc:approve");
            case "FINISHED_ARRIVAL_DETAIL" -> rights.productionPool() && rights.has("stock_doc:approve")
                    && Boolean.TRUE.equals(data.get("reversible"));
            case "STOCK_EDIT" -> (rights.has("stock_doc:edit") || rights.has("stock_doc:approve") || rights.has("stock_doc:delete"))
                    && writable(rs.getObject("maker_id",UUID.class),rights.owner())
                    && !rs.getBoolean("production_linked");
            case "STOCK_DETAIL" -> status.endsWith("_STOCKED") && rights.has("stock_doc:reverse")
                    && (rs.getBoolean("production_linked")?rights.productionPool():writable(rs.getObject("maker_id",UUID.class),rights.owner()))
                    && (!Boolean.TRUE.equals(data.get("authorizedBalanceAdjustment")) || rights.has("stock:balance:adjust"));
            default -> false;
        };
        canHandle=canHandle && rights.actor().getImpersonatedBy()==null;
        data.put("canRegisterBeforeInspection",canHandle && switch(proposed) {
            case "ARRIVAL_REGISTER" -> rights.explicitAuthority("warehouse_inbound:view")
                    && rights.explicitAuthority("warehouse_inbound:stock_in")
                    && rights.explicitAuthority(ProcurementIqcStockInPermissions.BEFORE_INSPECTION);
            case "FINISHED_REGISTER" -> rights.explicitAuthority("stock_doc:view")
                    && rights.explicitAuthority("stock_doc:approve")
                    && rights.explicitAuthority(ProductionFinishedArrivalRegistrationService.BEFORE_INSPECTION_AUTHORITY);
            default -> false;
        });
        String rowKey=source+":"+record+":"+id;
        String action=canHandle?proposed:"HISTORY_DETAIL";
        if(action.equals("STOCK_EDIT") && !rights.has("stock_doc:edit")) action="STOCK_DETAIL";
        if(action.equals("HISTORY_DETAIL")) data.put("historyEndpoint","/warehouse/task-center/inbound/"+rowKey+"/detail");
        data.put("status",status);
        return new Row(rowKey,id,source,record,rs.getString("bill_no"),rs.getString("source_doc_no"),
                rs.getObject("business_date",java.time.LocalDate.class),rs.getString("party_name"),
                rs.getString("warehouse_name"),rs.getString("responsible_name"),(Integer)rs.getObject("line_count"),
                status,presentation.label(),presentation.tone(),action,rs.getObject("target_id",UUID.class),canHandle,data);
    }

    private static boolean writable(UUID maker,OwnerScope owner) {
        return maker!=null && (owner.seeAll() || owner.writableOwners().contains(maker));
    }

    private static long number(Map<String,Object> data,String key) {
        return data.get(key) instanceof Number value?value.longValue():0;
    }

    private static boolean positive(Map<String,Object> data,String key) {
        Object value=data.get(key);
        return value!=null && new java.math.BigDecimal(value.toString()).signum()>0;
    }

    private record Rights(AuthUser actor,boolean warehouseParticipant,OwnerScope owner) {
        // The original pre-inspection commands require this exact granted
        // authority even when the principal carries the super-admin marker.
        boolean explicitAuthority(String code) { return actor.getAuthorities().stream().anyMatch(a -> code.equals(a.getAuthority())); }
        boolean has(String code) { return actor.isSuperAdmin() || actor.getAuthorities().stream().anyMatch(a -> code.equals(a.getAuthority())); }
        boolean inbound() { return has("warehouse_inbound:view"); }
        boolean purchaseHistory() { return has("warehouse_purchase_receipt_history:view"); }
        boolean subcontractHistory() { return has("warehouse_subcontract_receipt_history:view"); }
        boolean quality() { return has("warehouse_iqc_stock_in:view") || has("warehouse_iqc_return:view"); }
        boolean stock() { return has("stock_doc:view"); }
        boolean productionPool() { return stock() && warehouseParticipant; }
        boolean history(String source) { return source.equals("PURCHASE")?purchaseHistory():source.equals("SUBCONTRACT")&&subcontractHistory(); }
        boolean anyView() { return inbound() || purchaseHistory() || subcontractHistory() || quality() || stock(); }
        boolean sourceAllowed(String source) { return switch(source) {
            case "ALL" -> anyView();
            case "PURCHASE" -> inbound() || purchaseHistory() || quality();
            case "SUBCONTRACT" -> inbound() || subcontractHistory() || quality();
            default -> stock();
        }; }
    }

    private record Presentation(String label,String tone) {}
    private static Presentation presentation(String status) {
        Presentation value=STATUSES.get(status);
        if (value==null) throw new ApiException(ErrorCode.CONFLICT,"存在未识别的入库阶段，请刷新后重试");
        return value;
    }
    private static Map<String,Presentation> statuses() {
        Map<String,Presentation> result=new LinkedHashMap<>();
        for(String source:List.of("PURCHASE","SUBCONTRACT")) {
            String prefix=source.equals("PURCHASE")?"采购":"委外";
            add(result,source,prefix,"READY_REGISTER","待登记到货","success");
            add(result,source,prefix,"BLOCKED","到货资料待补全","danger");
            add(result,source,prefix,"CONTINUE_INSPECTION","已登记待送检","info");
            add(result,source,prefix,"EXCESS_PENDING_FINANCE","超量待财务处理","orange");
            add(result,source,prefix,"WAITING_INSPECTION","等待检查结果","warning");
            add(result,source,prefix,"PRE_STOCKED_WAITING_INSPECTION","已上架待检","warning");
            add(result,source,prefix,"PASSED_WAITING_STOCK_IN","合格待入库","success");
            add(result,source,prefix,"PARTIAL_PASSED","部分合格待办理","orange");
            add(result,source,prefix,"RETURN_REQUIRED","不合格待退回","danger");
            add(result,source,prefix,"STOCKED","已入库","neutral");
            add(result,source,prefix,"STOCKED_WITH_RETURN","已入库并退回不合格品","neutral");
            add(result,source,prefix,"RETURNED","已退回","neutral");
            add(result,source,prefix,"RECEIPT_DRAFT","收货草稿","neutral");
            add(result,source,prefix,"RECEIPT_REVERSED","收货已撤回","danger");
            add(result,source,prefix,"RECEIPT_CLOSED","收货已办结","neutral");
            add(result,source,prefix,"HISTORICAL_APPROVED","历史已审核","neutral");
            add(result,source,prefix,"EXCEPTION_PENDING_FINANCE","超量待财务审批","orange");
            add(result,source,prefix,"EXCEPTION_RECEIPT_ADJUSTED","超量批准待重新送检","success");
            add(result,source,prefix,"EXCEPTION_RETURN_REQUIRED","超量余料待退回","danger");
            add(result,source,prefix,"EXCEPTION_RECEIPT_POSTED","异常已批准送检","warning");
            add(result,source,prefix,"EXCEPTION_CLOSED","到货异常已办结","neutral");
            add(result,source,prefix,"EXCEPTION_CANCELED","到货异常已取消","neutral");
        }
        add(result,"FINISHED","成品","READY_REGISTER","待登记入库","success");
        add(result,"FINISHED","成品","READY_COUNT","品质通过待最终点收","success");
        add(result,"FINISHED","成品","RESIDUAL_COUNT","短收余量待点收","violet");
        add(result,"FINISHED","成品","WAITING_FQC","已登记待检","warning");
        add(result,"FINISHED","成品","PRE_STOCKED_FQC","已上架待检","warning");
        add(result,"FINISHED","成品","FQC_PARTIAL","部分已检查","orange");
        add(result,"FINISHED","成品","FQC_REJECTED","检查含不合格","danger");
        add(result,"FINISHED","成品","REGISTRATION_REVERSED","登记已撤回","neutral");
        add(result,"FINISHED","成品","SOURCE_REVERSED","来源报工已撤回","neutral");
        add(result,"FINISHED","成品","REGISTRATION_CLOSED","登记已办结","neutral");
        for(String source:List.of("FINISHED","OTHER","RETURN")) {
            String prefix=switch(source) {case "FINISHED"->"成品";case "OTHER"->"其它入库";default->"生产退料";};
            add(result,source,prefix,"DRAFT","草稿","neutral");
            add(result,source,prefix,"STOCKED",source.equals("RETURN")?"已收料":"已入库","neutral");
            add(result,source,prefix,"REVERSED","已撤回","danger");
            add(result,source,prefix,"CLOSED","已办结","neutral");
        }
        add(result,"RETURN","生产退料","PENDING_RECEIVE","待仓库收料","success");
        return Map.copyOf(result);
    }
    private static void add(Map<String,Presentation> values,String source,String prefix,String status,String label,String tone) {
        values.put(source+"_"+status,new Presentation(prefix+label,tone));
    }
    private static String normalize(String value,String fallback) { return text(value).isEmpty()?fallback:text(value).toUpperCase(Locale.ROOT); }
    private static String text(String value) { return value==null?"":value.strip(); }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
}
