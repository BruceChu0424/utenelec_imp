package com.uten.imp.features.stock.trace;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.stock.allocation.ProductionMaterialTaskAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** One typed resolver over the canonical physical trace engine. No current BOM or value-pool inference. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
public class MaterialTraceabilityQueryService implements MaterialTraceabilityReadPort {
    private static final int SOURCE_LIMIT=100;
    private final NamedParameterJdbcTemplate db;
    private final GoodsProductionTraceQueryService canonical;
    private final ProductionMaterialTaskAccessPolicy materialAccess;
    private final StockDocAccessPolicy stockAccess;
    private final ProductionDocumentReadScopePort productionDocuments;
    private final PurchaseDocumentReadScopePort purchaseDocuments;
    private final SubcontractDocumentReadAccessPort subcontractDocuments;
    private final WarehouseTaskScopePort warehouseScopes;
    private final SecurityContextCurrentUser currentUser;

    @Override
    public PageResponse<Subject> subjects(String kind,String keyword,boolean exact,int page,int size) {
        require("production_where_used:view");
        String category=kind==null?"goods":kind.trim().toLowerCase(Locale.ROOT);
        if(!Set.of("goods","document","batch").contains(category))throw invalid("查询类型不正确");
        if(!"goods".equals(category))require("stock:view");
        int p=Math.max(1,page),s=Math.max(1,Math.min(50,size));
        String term=keyword==null?"":keyword.trim();
        if(term.length()>160)throw invalid("搜索内容过长");
        if(term.isEmpty())return new PageResponse<>(List.of(),p,s,0,0);
        Context context=context();
        List<String> branches=new ArrayList<>();
        if("goods".equals(category))branches.add(goodsSubjects());
        if("document".equals(category))for(SubjectType type:SubjectType.values()) {
            if(type!=SubjectType.GOODS&&type!=SubjectType.PRODUCTION_OUTPUT_LOT&&permitted(type))branches.add(subjectSql(type,context));
        }
        if("batch".equals(category)&&permitted(SubjectType.PRODUCTION_OUTPUT_LOT))branches.add(subjectSql(SubjectType.PRODUCTION_OUTPUT_LOT,context));
        if(branches.isEmpty())return new PageResponse<>(List.of(),p,s,0,0);
        var params=new MapSqlParameterSource(context.params).addValue("term",term)
                .addValue("match","%"+escapeLike(term)+"%").addValue("limit",s).addValue("offset",(long)(p-1)*s);
        String cte="WITH subjects AS ("+String.join(" UNION ALL ",branches)+"), matched AS (SELECT * FROM subjects WHERE "+
                (exact?"(lower(code)=lower(:term) OR (type='PRODUCTION_OUTPUT_LOT' AND lower(split_part(label,' · ',1))=lower(:term)) OR id::text=:term)":"(code ILIKE :match ESCAPE '\\' OR label ILIKE :match ESCAPE '\\' OR id::text=:term)")+
                ") ";
        long total=Objects.requireNonNull(db.queryForObject(cte+"SELECT count(*) FROM matched",params,Long.class));
        List<Subject> items=db.queryForList(cte+"SELECT * FROM matched ORDER BY CASE WHEN lower(code)=lower(:term) THEN 0 ELSE 1 END,document_date DESC NULLS LAST,type,code,id LIMIT :limit OFFSET :offset",params)
                .stream().map(this::subject).toList();
        return new PageResponse<>(items,p,s,total,(int)((total+s-1)/s));
    }

    @Override
    public Result trace(String subjectType,UUID subjectId,String direction,LocalDate dateFrom,LocalDate dateTo,int page,int size) {
        require("production_where_used:view");require("stock:view");
        if(subjectId==null)throw invalid("请选择追溯对象");
        SubjectType type=parseType(subjectType);
        if(!Set.of("usage","materials").contains(direction))throw invalid("追溯方向不正确");
        if(dateFrom!=null&&dateTo!=null&&dateFrom.isAfter(dateTo))throw invalid("开始日期不能晚于结束日期");
        if(!permitted(type))throw new ApiException(ErrorCode.FORBIDDEN,"没有该类追溯单据的查看权限");
        // Check the canonical plan/workshop capability even when a source has no downstream rows.
        materialAccess.queryReadScope("plan","segment");
        Context context=context();
        String subjectQuery=subjectSql(type,context);
        var params=new MapSqlParameterSource(context.params).addValue("subjectId",subjectId);
        List<Map<String,Object>> resolved=db.queryForList("SELECT * FROM ("+subjectQuery+") subject WHERE id=:subjectId",params);
        if(resolved.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"追溯对象不存在或不在可读范围内");
        Subject selected=subject(resolved.getFirst());
        context.params.put("subjectId",subjectId);
        if(dateFrom!=null)context.params.put("traceDateFrom",dateFrom);
        if(dateTo!=null)context.params.put("traceDateTo",dateTo);
        String predicate=selection(type,direction,context);
        if(dateFrom!=null||dateTo!=null)predicate="("+predicate+") AND "+reportDateExists(dateFrom,dateTo,context);
        boolean narrow=type!=SubjectType.GOODS&&type!=SubjectType.PRODUCTION_PLAN||dateFrom!=null||dateTo!=null;
        UUID report=type==SubjectType.PRODUCTION_REPORT?subjectId:null;
        UUID lot=type==SubjectType.PRODUCTION_OUTPUT_LOT&&"materials".equals(direction)?subjectId:null;
        if(report!=null)context.params.put("selectedReport",report);
        if(lot!=null)context.params.put("selectedLot",lot);
        String posting=postingAccess(context),document=stockDocumentScope("document",context),periodic=periodicAccess(context),receipt=receiptAccess(context);
        if(type==SubjectType.PURCHASE_ORDER)receipt+=" AND EXISTS(SELECT 1 FROM purchase_receipt_items selected_item JOIN purchase_order_items selected_ordered ON selected_ordered.id=selected_item.order_item_id WHERE selected_item.id=allocation.receipt_item_id AND selected_ordered.order_id=:subjectId)";
        String subReceipt=has("subcontract_receipt:view")?subcontractScope("receipt","traceSubReceiptOwners",context)+" AND "+receiptAccess(context):"FALSE";
        if(type==SubjectType.SUBCONTRACT_ORDER)subReceipt+=" AND EXISTS(SELECT 1 FROM subcontract_receipt_items selected_item JOIN subcontract_order_items selected_ordered ON selected_ordered.id=selected_item.order_item_id WHERE selected_item.id=allocation.receipt_item_id AND selected_ordered.order_id=:subjectId)";
        String reportRead=warehouse("report.warehouse_id",context);
        var selection=new GoodsProductionTraceQueryService.Selection(predicate,Map.copyOf(context.params),
                posting,document,periodic,receipt,subReceipt,reportRead,narrow,report,lot,dateFrom,dateTo);
        PageResponse<GoodsProductionTraceContracts.TraceRow> rows=canonical.querySelected(selection,page,size);
        List<Source> sources=sourceFacts(type,direction,context,dateFrom,dateTo);
        boolean truncated=sources.size()>SOURCE_LIMIT;
        if(truncated)sources=sources.subList(0,SOURCE_LIMIT);
        List<String> notes=new ArrayList<>(List.of(
                "仅展示当前账号有权读取的单据、仓库及生产任务；数量按各自单位展示，不跨单位相加。",
                "采购来源为入库预留与已领料的明确关联，不代表原料逐批实际消耗；普通跨仓历史缺少原批次关联时不推算。",
                "生产日报参与人为整张日报参与人；批次产量来自产出明细，不代表该批已分摊物料实耗。"));
        if(narrow)notes.add("当前单据、日期或批次仅用于确认关联；整任务累计领料及核销量未作为该对象用量，未逐批分摊的数量显示为空。");
        if(type==SubjectType.SUBCONTRACT_ORDER)notes.add("委外发料及回厂收货列在来源中；回厂到厂内仅展示明确入库预留关联，冻结 BOM 核销为估算口径，不代表逐批实测耗用。");
        if(type==SubjectType.PRODUCTION_OUTPUT_LOT)notes.add("本入口批次为生产实物交接批次；未编业务批号时显示批次未编号，不能当作供应商原料批号。");
        if(truncated)notes.add("来源较多，仅显示最近 100 条可读事实；可使用具体订单或批次缩小范围。");
        return new Result(rows.getItems(),rows.getPage(),rows.getSize(),rows.getTotal(),rows.getTotalPages(),selected,List.copyOf(sources),truncated,List.copyOf(notes));
    }

    private Context context() {
        var physical=new GoodsProductionTraceReadScope(stockAccess,warehouseScopes.current(null),has("stock_doc:view"),warehouseScopes.access().warehouseParticipant());
        return new Context(physical.warehouses,physical.parameters,physical);
    }
    private record Context(WarehouseTaskScopePort.WarehouseTaskScope warehouses,Map<String,Object> params,GoodsProductionTraceReadScope physical) {}

    private String goodsSubjects() {
        return "SELECT 'GOODS'::text AS type,g.id,g.code,g.name AS label,NULL::date AS document_date,"+
                "CASE WHEN g.is_deleted THEN 'DELETED' ELSE 'ACTIVE' END AS status,g.id AS goods_id,g.code AS goods_code,g.name AS goods_name,'GOODS_IDENTITY'::text AS basis FROM goods g";
    }
    private String subjectSql(SubjectType type,Context c) {
        return switch(type) {
            case GOODS->goodsSubjects();
            case PURCHASE_ORDER->documentSubject(type,"purchase_orders","document",purchaseScope("document","subjectPurchaseOwners",c),orderWarehouse("purchase",c));
            case SUBCONTRACT_ORDER->documentSubject(type,"subcontract_orders","document",subcontractScope("document","subjectSubcontractOwners",c),orderWarehouse("subcontract",c));
            case PRODUCTION_PLAN->documentSubject(type,"production_plans","document",planScope("document","subjectPlanOwners",c),planWarehouse("document.id",c));
            case PRODUCTION_REPORT->documentSubject(type,"production_daily_reports","document",reportScope("document","subjectReportOwners",c),warehouse("document.warehouse_id",c));
            case STOCK_DOC->documentSubject(type,"stock_documents","document",stockDocumentScope("document",c),stockDocumentWarehouse("document",c));
            case PRODUCTION_OUTPUT_LOT->"SELECT 'PRODUCTION_OUTPUT_LOT'::text AS type,item.output_lot_id AS id,NULL::text AS code, "+
                    "report.bill_no||' · 第'||COALESCE(string_agg(DISTINCT item.line_no::text,'、'),'未编号')||'行产出批次' AS label,report.bill_date AS document_date,"+reportStatus("report")+" AS status,"+
                    "item.goods_id,g.code AS goods_code,g.name AS goods_name,'PRODUCTION_OUTPUT'::text AS basis "+
                    "FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id "+
                    "LEFT JOIN goods g ON g.id=item.goods_id WHERE item.output_lot_id IS NOT NULL AND NOT item.is_deleted AND NOT report.is_deleted AND "+
                    reportScope("report","subjectLotOwners",c)+" AND "+warehouse("report.warehouse_id",c)+
                    " GROUP BY item.output_lot_id,report.id,item.goods_id,g.code,g.name";
        };
    }
    private String documentSubject(SubjectType type,String table,String alias,String scope,String warehouse) {
        return "SELECT '"+type.name()+"'::text AS type,"+alias+".id,"+alias+".bill_no AS code,"+alias+".bill_no AS label,"+
                alias+".bill_date AS document_date,"+(type==SubjectType.PRODUCTION_REPORT?reportStatus(alias):status(alias))+" AS status,NULL::uuid AS goods_id,NULL::text AS goods_code,NULL::text AS goods_name,"+
                "'DOCUMENT_IDENTITY'::text AS basis FROM "+table+" "+alias+" WHERE NOT "+alias+".is_deleted AND ("+scope+") AND ("+warehouse+")";
    }
    private String orderWarehouse(String module,Context c) {
        String direct=warehouse("document.warehouse_id",c);
        String receipts="FALSE",issues="FALSE";
        if(has(module+"_receipt:view")) {
            String scope="purchase".equals(module)?purchaseScope("receipt","orderReceiptOwners",c):subcontractScope("receipt","orderSubReceiptOwners",c);
            receipts="EXISTS(SELECT 1 FROM "+module+"_receipt_items item JOIN "+module+"_receipts receipt ON receipt.id=item.receipt_id "+
                "JOIN "+module+"_order_items ordered ON ordered.id=item.order_item_id WHERE ordered.order_id=document.id AND NOT receipt.is_deleted AND "+
                scope+" AND "+warehouse("receipt.warehouse_id",c)+")";
        }
        if("subcontract".equals(module)&&has("subcontract_material_issue:view"))
            issues="EXISTS(SELECT 1 FROM subcontract_material_issue_items issued JOIN subcontract_material_issues issue ON issue.id=issued.issue_id "+
                    "JOIN subcontract_order_items ordered ON ordered.id=issued.order_item_id WHERE ordered.order_id=document.id AND NOT issued.is_deleted AND NOT issue.is_deleted AND "+
                    subcontractIssueScope("issue","orderIssueOwners",c)+" AND "+warehouse("issue.warehouse_id",c)+")";
        return "("+direct+" OR "+receipts+" OR "+issues+")";
    }
    private String planWarehouse(String planId,Context c) {
        if(!c.warehouses.active())return "TRUE";
        // Drafts have only plan/items. Retained package/demand facts, including pre-segment demands,
        // prove a known warehouse; deleting a mapping must never turn an outside warehouse into 'unassigned'.
        String demands="SELECT 1 FROM production_material_demands wd WHERE wd.plan_id="+planId+" AND wd.warehouse_id IS NOT NULL";
        String packages="SELECT 1 FROM production_planning_packages wp WHERE wp.plan_id="+planId+" AND wp.warehouse_id IS NOT NULL";
        return "(EXISTS("+demands+" AND "+warehouse("wd.warehouse_id",c)+") OR EXISTS("+
                packages+" AND "+warehouse("wp.warehouse_id",c)+") OR ("+warehouse("NULL::uuid",c)+
                " AND NOT EXISTS("+demands+") AND NOT EXISTS("+packages+")))";
    }
    private String stockDocumentWarehouse(String alias,Context c) {
        return "("+warehouse(alias+".warehouse_id",c)+" OR EXISTS(SELECT 1 FROM stock_document_items wi WHERE wi.doc_id="+alias+".id AND NOT wi.is_deleted AND "+
                warehouse("COALESCE(wi.warehouse_id,"+alias+".warehouse_id)",c)+"))";
    }
    private String stockDocumentScope(String alias,Context c) {
        return c.physical.document(alias);
    }
    private String postingAccess(Context c) {
        return c.physical.posting();
    }
    private String periodicAccess(Context c) {
        return c.physical.periodic();
    }
    private String receiptAccess(Context c) {
        return c.physical.receipt();
    }

    private String selection(SubjectType type,String direction,Context c) {
        return switch(type) {
            case GOODS->"usage".equals(direction)?"trace.material_goods_id=:subjectId":"segment.product_goods_id=:subjectId";
            case PRODUCTION_PLAN->"plan.id=:subjectId";
            case STOCK_DOC->"(EXISTS(SELECT 1 FROM production_material_stock_postings posting JOIN production_material_stock_events event ON event.id=posting.event_id "+
                    "WHERE posting.demand_id=trace.demand_id AND event.stock_document_id=:subjectId AND "+postingAccess(c)+") OR "+
                    reportRelation("EXISTS(SELECT 1 FROM stock_document_items source_item WHERE source_item.doc_id=:subjectId AND NOT source_item.is_deleted AND source_item.source_daily_report_item_id=item.id)",c)+")";
            case PURCHASE_ORDER->has("purchase_receipt:view")?"EXISTS(SELECT 1 FROM production_material_receipt_allocations allocation "+
                    "JOIN purchase_receipts receipt ON receipt.id=allocation.receipt_id JOIN purchase_receipt_items ri ON ri.id=allocation.receipt_item_id "+
                    "JOIN purchase_order_items ordered ON ordered.id=ri.order_item_id WHERE ordered.order_id=:subjectId "+
                    "AND allocation.demand_id=trace.demand_id AND allocation.status='EFFECTIVE' AND "+purchaseScope("receipt","selectedReceiptOwners",c)+
                    " AND "+receiptAccess(c)+")":"FALSE";
            case SUBCONTRACT_ORDER->has("subcontract_receipt:view")?"EXISTS(SELECT 1 FROM production_material_subcontract_receipt_allocations allocation "+
                    "JOIN subcontract_receipts receipt ON receipt.id=allocation.receipt_id JOIN subcontract_receipt_items ri ON ri.id=allocation.receipt_item_id "+
                    "JOIN subcontract_order_items ordered ON ordered.id=ri.order_item_id WHERE ordered.order_id=:subjectId "+
                    "AND allocation.demand_id=trace.demand_id AND allocation.status='EFFECTIVE' AND "+subcontractScope("receipt","selectedSubReceiptOwners",c)+
                    " AND "+receiptAccess(c)+")":"FALSE";
            case PRODUCTION_REPORT->reportRelation("item.report_id=:subjectId",c);
            case PRODUCTION_OUTPUT_LOT->"materials".equals(direction)?reportRelation("item.output_lot_id=:subjectId",c):
                    "EXISTS(SELECT 1 FROM production_workshop_direct_source_events source "+
                    "JOIN production_workshop_direct_source_allocations allocation ON allocation.id=source.source_allocation_id "+
                    "JOIN production_workshop_direct_transfer_items transfer ON transfer.id=allocation.transfer_item_id "+
                    "JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id "+
                    "JOIN production_material_stock_postings posting ON posting.id=source.stock_posting_id "+
                    "WHERE item.output_lot_id=:subjectId AND posting.demand_id=trace.demand_id AND "+postingAccess(c)+")";
        };
    }
    private String reportRelation(String condition,Context c) {
        if(!has("production_daily_report:view"))return "FALSE";
        return "EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports linked_report ON linked_report.id=item.report_id "+
                "WHERE "+condition+" AND NOT item.is_deleted AND NOT linked_report.is_deleted AND linked_report.status=1 AND NOT linked_report.is_canceled AND "+
                reportScope("linked_report","linkedReportOwners",c)+" AND "+warehouse("linked_report.warehouse_id",c)+" AND ("+
                "(trace.demand_id IS NOT NULL AND EXISTS(SELECT 1 FROM fn_production_material_usage_source_segments(item.execution_segment_id) source WHERE source.segment_id=trace.segment_id) "+
                "AND (item.execution_segment_id=trace.segment_id OR EXISTS("+
                "SELECT 1 FROM production_material_settlement_events event JOIN production_material_settlement_postings settled ON settled.event_id=event.id "+
                "WHERE event.daily_report_id=item.report_id AND settled.demand_id=trace.demand_id))) OR "+
                "(trace.allocation_id IS NOT NULL AND EXISTS(SELECT 1 FROM workshop_material_close_theory_lines theory "+
                "JOIN workshop_material_close_allocations allocation ON allocation.id=trace.allocation_id "+
                "JOIN workshop_material_close_materials allocated_material ON allocated_material.id=allocation.close_material_id "+
                "WHERE theory.report_item_id=item.id AND theory.cost_scope_segment_id=allocation.cost_scope_segment_id "+
                "AND (theory.close_material_id=allocated_material.id OR (allocated_material.cost_basis='SHARED' AND theory.close_id=allocated_material.close_id))))))";
    }
    private String reportDateExists(LocalDate from,LocalDate to,Context c) {
        return reportRelation((from==null?"TRUE":"linked_report.bill_date>=:traceDateFrom")+(to==null?"":" AND linked_report.bill_date<=:traceDateTo"),c);
    }

    private List<Source> sourceFacts(SubjectType type,String direction,Context c,LocalDate from,LocalDate to) {
        List<String> branches=new ArrayList<>();
        boolean goods=type==SubjectType.GOODS;
        if((goods||type==SubjectType.PURCHASE_ORDER)&&has("purchase_order:view"))
            branches.add(sourceSql("PURCHASE_ORDER","purchase_orders","purchase_order_items","order_id","document", "ORDERED_QUANTITY","订货数量，尚不代表收货或实耗",
                    purchaseScope("document","sourcePurchaseOrderOwners",c)+" AND "+warehouse("document.warehouse_id",c),goods?"item.goods_id=:subjectId":"document.id=:subjectId","item.qty",false));
        if((goods||type==SubjectType.PURCHASE_ORDER)&&has("purchase_receipt:view"))
            branches.add(sourceSql("PURCHASE_RECEIPT","purchase_receipts","purchase_receipt_items","receipt_id","document","RECEIPT_QUANTITY","收货单数量；以单据状态区分草稿、已审及红冲",
                    purchaseScope("document","sourcePurchaseReceiptOwners",c)+" AND "+warehouse("document.warehouse_id",c),goods?"item.goods_id=:subjectId":"EXISTS(SELECT 1 FROM purchase_order_items ordered WHERE ordered.id=item.order_item_id AND ordered.order_id=:subjectId)","item.qty",true));
        if((goods||type==SubjectType.SUBCONTRACT_ORDER)&&has("subcontract_order:view"))
            branches.add(sourceSql("SUBCONTRACT_ORDER","subcontract_orders","subcontract_order_items","order_id","document","ORDERED_QUANTITY","委外订货数量，不是实际原料耗用",
                    subcontractScope("document","sourceSubOrderOwners",c)+" AND "+warehouse("document.warehouse_id",c),goods?"item.goods_id=:subjectId":"document.id=:subjectId","item.qty",false));
        if((goods||type==SubjectType.SUBCONTRACT_ORDER)&&has("subcontract_receipt:view"))
            branches.add(sourceSql("SUBCONTRACT_RECEIPT","subcontract_receipts","subcontract_receipt_items","receipt_id","document","RECEIPT_QUANTITY","回厂收货数量；以状态区分草稿、已审及红冲",
                    subcontractScope("document","sourceSubReceiptOwners",c)+" AND "+warehouse("document.warehouse_id",c),goods?"item.goods_id=:subjectId":"EXISTS(SELECT 1 FROM subcontract_order_items ordered WHERE ordered.id=item.order_item_id AND ordered.order_id=:subjectId)","item.qty",true));
        if((goods||type==SubjectType.SUBCONTRACT_ORDER)&&has("subcontract_material_issue:view")) {
            String filter=goods?("materials".equals(direction)?has("subcontract_order:view")?"related.related_goods_id=:subjectId":"FALSE":"item.goods_id=:subjectId"):
                    "EXISTS(SELECT 1 FROM subcontract_order_items ordered WHERE ordered.id=item.order_item_id AND ordered.order_id=:subjectId)";
            String access=subcontractIssueScope("document","sourceSubIssueOwners",c)+" AND "+warehouse("document.warehouse_id",c);
            branches.add(sourceSql("SUBCONTRACT_MATERIAL_ISSUE","subcontract_material_issues","subcontract_material_issue_items","issue_id","document","ACTUAL_MATERIAL_ISSUE","发料单数量，只有已审状态表示已发；不同材料不可合计",access,filter,"item.qty",true,c));
            branches.add(sourceSql("SUBCONTRACT_MATERIAL_CONSUMPTION","subcontract_material_issues","subcontract_material_issue_items","issue_id","document","FROZEN_BOM_ESTIMATE","原发料单累计冻结 BOM 核销；日期为发料单日期，非逐批实测耗用日期",access,filter+" AND item.frozen_unit_qty IS NOT NULL","item.consumed_qty",true,c));
        }
        if((goods||type==SubjectType.STOCK_DOC)&&has("stock_doc:view"))
            branches.add(sourceSql("STOCK_DOC","stock_documents","stock_document_items","doc_id","document","STOCK_DOCUMENT_QUANTITY","出入库单据数量；领料分轮出库以过账记录为准",
                    stockDocumentScope("document",c)+" AND "+warehouse("COALESCE(item.warehouse_id,document.warehouse_id)",c),goods?"item.goods_id=:subjectId":"document.id=:subjectId","item.qty",false));
        if((goods||type==SubjectType.PRODUCTION_PLAN||type==SubjectType.PRODUCTION_REPORT||type==SubjectType.PRODUCTION_OUTPUT_LOT)&&has("production_daily_report:view")) {
            String filter=switch(type) {
                case GOODS->"item.goods_id=:subjectId";
                case PRODUCTION_PLAN->"EXISTS(SELECT 1 FROM production_execution_segments segment WHERE segment.id=item.execution_segment_id AND segment.plan_id=:subjectId)";
                case PRODUCTION_REPORT->"document.id=:subjectId";
                case PRODUCTION_OUTPUT_LOT->"item.output_lot_id=:subjectId";
                default->"FALSE";
            };
            branches.add(sourceSql("PRODUCTION_REPORT","production_daily_reports","production_daily_report_items","report_id","document","PRODUCTION_OUTPUT","日报产出明细数量，不代表分摊原料耗用",
                    reportScope("document","sourceOutputOwners",c)+" AND "+warehouse("document.warehouse_id",c),filter,"item.qty",false));
        }
        if(type==SubjectType.PRODUCTION_PLAN&&has("production_plan:view"))
            branches.add(sourceSql("PRODUCTION_PLAN","production_plans","production_plan_items","plan_id","document","ORDERED_QUANTITY","计划排产数量，不是实际产出",
                    planScope("document","sourcePlanOwners",c)+" AND "+planWarehouse("document.id",c),"document.id=:subjectId","item.qty",false));
        if(branches.isEmpty())return List.of();
        String dateFilter=(from==null?"":" AND source_date>=:traceDateFrom")+(to==null?"":" AND source_date<=:traceDateTo");
        var params=new MapSqlParameterSource(c.params).addValue("sourceLimit",SOURCE_LIMIT+1);
        return db.queryForList("SELECT * FROM ("+String.join(" UNION ALL ",branches)+") sources WHERE TRUE"+dateFilter+
                " ORDER BY source_date DESC,type,code,id LIMIT :sourceLimit",params).stream().map(this::source).toList();
    }
    private String sourceSql(String type,String headers,String lines,String foreignKey,String alias,String basis,String note,String scope,String filter,String qty,boolean supplier) {
        return sourceSql(type,headers,lines,foreignKey,alias,basis,note,scope,filter,qty,supplier,null);
    }
    private String sourceSql(String type,String headers,String lines,String foreignKey,String alias,String basis,String note,String scope,String filter,String qty,boolean supplier,Context context) {
        // No monetary columns, staff names or arbitrary upstream header fields cross this projection.
        String supplierName=supplier&&has("supplier:view")?"(SELECT name FROM suppliers WHERE id="+alias+".supplier_id)":"NULL::text";
        String relatedJoin="",relatedFields="NULL::uuid AS related_goods_id,NULL::text AS related_goods_code,NULL::text AS related_goods_name,NULL::uuid AS related_color_id,NULL::text AS related_color_name,NULL::uuid AS related_unit_id,NULL::text AS related_unit_name,NULL::uuid AS related_order_id,NULL::text AS related_order_code";
        String noteSql="'"+note+"'::text";
        if(context!=null) {
            noteSql+="||'；关联委外产品仅在原始归属完整且订货单可读时提供'";
            if(has("subcontract_order:view")) {
                relatedJoin=" LEFT JOIN LATERAL (SELECT ordered.goods_id AS related_goods_id,"+
                        "COALESCE(CASE WHEN item.parent_goods_id=ordered.goods_id THEN NULLIF(item.parent_goods_code_snapshot,'') END,NULLIF(ordered.goods_code_snapshot,''),parent.code) AS related_goods_code,"+
                        "COALESCE(CASE WHEN item.parent_goods_id=ordered.goods_id THEN NULLIF(item.parent_goods_name_snapshot,'') END,NULLIF(ordered.goods_name_snapshot,''),parent.name) AS related_goods_name,"+
                        "ordered.color_id AS related_color_id,parent_color.name AS related_color_name,ordered.unit_id AS related_unit_id,parent_unit.name AS related_unit_name,"+
                        "related_order.id AS related_order_id,related_order.bill_no AS related_order_code "+
                        "FROM subcontract_order_items ordered JOIN subcontract_orders related_order ON related_order.id=ordered.order_id "+
                        "LEFT JOIN goods parent ON parent.id=ordered.goods_id LEFT JOIN colors parent_color ON parent_color.id=ordered.color_id LEFT JOIN units parent_unit ON parent_unit.id=ordered.unit_id "+
                        "WHERE ordered.id=item.order_item_id AND NOT ordered.is_deleted AND NOT related_order.is_deleted "+
                        "AND (item.parent_goods_id IS NULL OR item.parent_goods_id=ordered.goods_id) "+
                        "AND (item.parent_color_id IS NULL OR item.parent_color_id IS NOT DISTINCT FROM ordered.color_id) AND "+
                        subcontractScope("related_order","sourceRelatedOrderOwners",context)+" AND "+warehouse("COALESCE(related_order.warehouse_id,"+alias+".warehouse_id)",context)+") related ON TRUE ";
                relatedFields="related.*";
            }
        }
        return "SELECT '"+type+"'::text AS type,"+alias+".id,item.id AS item_id,"+alias+".bill_no AS code,"+alias+".bill_date AS source_date,"+
                "item.goods_id,g.code AS goods_code,g.name AS goods_name,item.color_id,color.name AS color_name,item.unit_id,unit.name AS unit_name,"+
                qty+" AS qty,"+("production_daily_reports".equals(headers)?reportStatus(alias):status(alias))+" AS status,'"+basis+"'::text AS basis,"+noteSql+" AS note, "+
                "warehouse.name AS warehouse_name,"+supplierName+" AS supplier_name,"+relatedFields+","+
                ("stock_documents".equals(headers)?alias+".doc_type":"NULL::text")+" AS doc_type FROM "+headers+" "+alias+" JOIN "+lines+" item ON item."+foreignKey+"="+alias+".id "+
                "LEFT JOIN goods g ON g.id=item.goods_id LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=item.unit_id "+
                "LEFT JOIN warehouses warehouse ON warehouse.id="+("stock_document_items".equals(lines)?"COALESCE(item.warehouse_id,"+alias+".warehouse_id)":Set.of("production_plans").contains(headers)?"NULL::uuid":alias+".warehouse_id")+
                relatedJoin+" WHERE NOT "+alias+".is_deleted"+(Set.of("stock_document_items","production_daily_report_items","subcontract_order_items","subcontract_material_issue_items").contains(lines)?" AND NOT item.is_deleted":"")+
                " AND ("+scope+") AND ("+filter+")";
    }

    private String warehouse(String column,Context c) {
        return c.physical.warehouse(column);
    }
    private String purchaseScope(String alias,String name,Context c) {return bind(purchaseDocuments.nativeReadScope(alias+".maker_id",name),c);}
    private String subcontractScope(String alias,String name,Context c) {return bind(subcontractDocuments.nativeReadScope(alias+".maker_id",name),c);}
    private String subcontractIssueScope(String alias,String name,Context c) {return bind(subcontractDocuments.materialIssueReadScope(alias,name),c);}
    private String reportScope(String alias,String name,Context c) {return bind(productionDocuments.nativeReadScope(alias+".maker_id",name,"production_daily_report:approve","production_daily_report:reverse"),c);}
    private String planScope(String alias,String name,Context c) {return bind(productionDocuments.nativeReadScope(alias+".maker_id",name,"production_plan:approve"),c);}
    private String bind(NativeReadScope scope,Context c) {if(scope.parameterName()!=null){ c.params.put(scope.parameterName(),scope.owners()); }return scope.predicate();}
    private Subject subject(Map<String,Object> r) {
        boolean actual=canTrace();
        return new Subject((String)r.get("type"),id(r,"id"),(String)r.get("code"),(String)r.get("label"),date(r.get("document_date")),
                (String)r.get("status"),id(r,"goods_id"),(String)r.get("goods_code"),(String)r.get("goods_name"),(String)r.get("basis"),actual,
                actual?null:"实际追溯需要库存查看及生产任务读取权限；仍可查看用料关系");
    }
    private Source source(Map<String,Object> r) {
        Goods good=new Goods(id(r,"goods_id"),(String)r.get("goods_code"),(String)r.get("goods_name"),id(r,"color_id"),(String)r.get("color_name"),id(r,"unit_id"),(String)r.get("unit_name"));
        Goods related=id(r,"related_goods_id")==null?null:new Goods(id(r,"related_goods_id"),(String)r.get("related_goods_code"),(String)r.get("related_goods_name"),id(r,"related_color_id"),(String)r.get("related_color_name"),id(r,"related_unit_id"),(String)r.get("related_unit_name"));
        return new Source((String)r.get("type"),id(r,"id"),(String)r.get("code"),date(r.get("source_date")),good,(BigDecimal)r.get("qty"),
                (String)r.get("unit_name"),(String)r.get("status"),(String)r.get("basis"),(String)r.get("note"),(String)r.get("warehouse_name"),(String)r.get("supplier_name"),id(r,"item_id"),
                related,id(r,"related_order_id"),(String)r.get("related_order_code"),(String)r.get("doc_type"));
    }
    private boolean permitted(SubjectType type) {
        return switch(type) {
            case GOODS->true;
            case PURCHASE_ORDER->has("purchase_order:view");case SUBCONTRACT_ORDER->has("subcontract_order:view");
            case PRODUCTION_PLAN->has("production_plan:view");
            case PRODUCTION_REPORT,PRODUCTION_OUTPUT_LOT->has("production_daily_report:view");case STOCK_DOC->has("stock_doc:view");
        };
    }
    private boolean canTrace() {
        if(!has("stock:view"))return false;
        try {materialAccess.queryReadScope("plan","segment");return true;}
        catch(ApiException ex) {return false;}
    }
    private SubjectType parseType(String type) {
        try{return SubjectType.valueOf(type==null?"":type.trim().toUpperCase(Locale.ROOT));}
        catch(IllegalArgumentException ex){throw invalid("不支持的追溯对象类型");}
    }
    private boolean has(String permission) {return currentUser.get().map(user->!user.isVisitor()&&(user.isSuperAdmin()||user.getAuthorities().stream().anyMatch(a->permission.equals(a.getAuthority())))).orElse(false);}
    private void require(String permission) {if(!has(permission))throw new ApiException(ErrorCode.FORBIDDEN,"没有追溯所需的查看权限");}
    private static UUID id(Map<String,Object> row,String key) {return (UUID)row.get(key);}
    private static LocalDate date(Object value) {return value instanceof java.sql.Date date?date.toLocalDate():(LocalDate)value;}
    private static ApiException invalid(String message) {return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static String escapeLike(String text) {return text.replace("\\","\\\\").replace("%","\\%").replace("_","\\_");}
    private static String status(String alias) {return "CASE "+alias+".status WHEN 1 THEN 'APPROVED' WHEN -1 THEN 'REVERSED' WHEN 0 THEN 'DRAFT' ELSE 'UNKNOWN' END";}
    private static String reportStatus(String alias) {return "CASE WHEN "+alias+".is_canceled THEN 'CANCELED' ELSE "+status(alias)+" END";}
}
