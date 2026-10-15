package com.uten.imp.features.stock.trace;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.stock.allocation.ProductionMaterialTaskAccessPolicy;
import com.uten.imp.features.stock.ledger.StockLedgerSource;
import com.uten.imp.application.port.ProductionDocumentReadScopePort;
import com.uten.imp.application.port.PurchaseDocumentReadScopePort;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.*;

/** Physical material facts, never a traversal of average-cost value edges or a guessed batch match. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
public class GoodsProductionTraceQueryService {
    private final NamedParameterJdbcTemplate db;
    private final ProductionMaterialTaskAccessPolicy materialAccess;
    private final StockDocAccessPolicy stockAccess;
    private final ProductionStockTaskAccessPolicy warehouseAccess;
    private final ProductionDocumentReadScopePort productionDocuments;
    private final PurchaseDocumentReadScopePort purchaseDocuments;
    private final SecurityContextCurrentUser currentUser;

    /** Constructed only by the scoped subject resolver in this package, never from request SQL. */
    record Selection(String predicate,Map<String,Object> parameters,String postingPredicate,String documentPredicate,String periodicPredicate,
                     String receiptPredicate,String subcontractReceiptPredicate,String reportPredicate,boolean narrowQuantities,UUID reportId,UUID lotId,
                     LocalDate dateFrom,LocalDate dateTo) {}

    private static final String TRACE_SQL="""
            WITH trace AS (
                SELECT demand.id,'ORDER'::text AS kind,demand.id AS demand_id,NULL::uuid AS allocation_id,
                       demand.execution_segment_id AS segment_id,demand.goods_id AS material_goods_id,
                       demand.color_id AS material_color_id,demand.unit_id AS material_unit_id,NULL::numeric AS allocated_qty
                FROM production_material_demands demand
                WHERE EXISTS(SELECT 1 FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id)
                UNION ALL
                SELECT allocation.id,'PERIODIC',NULL::uuid,allocation.id,allocation.cost_scope_segment_id,
                       line.goods_id,line.color_id,line.unit_id,allocation.allocated_qty
                FROM workshop_material_close_allocations allocation
                JOIN workshop_material_close_materials material ON material.id=allocation.close_material_id
                JOIN workshop_material_period_closes close ON close.id=material.close_id AND close.status='ACTIVE'
                JOIN workshop_material_period_lines line ON line.id=material.period_line_id
                WHERE allocation.reversed_at IS NULL
            ), visible AS (
                SELECT trace.*,segment.plan_id,plan.bill_no AS plan_no,segment.segment_code,
                       department.name AS workshop_name,segment.product_goods_id,segment.product_color_id,segment.product_unit_id
                FROM trace JOIN production_execution_segments segment ON segment.id=trace.segment_id AND NOT segment.is_deleted
                JOIN production_plans plan ON plan.id=segment.plan_id AND NOT plan.is_deleted
                LEFT JOIN departments department ON department.id=segment.workshop_department_id
                WHERE %s AND %s
            )
            """;

    public PageResponse<TraceRow> query(UUID goodsId,String direction,int page,int size) {
        if(!has("stock:view"))throw new ApiException(ErrorCode.FORBIDDEN,"没有库存查看权限");
        if(!"usage".equals(direction)&&!"materials".equals(direction))throw new ApiException(ErrorCode.VALIDATION_FAILED,"追溯方向不正确");
        materialAccess.queryReadScope("plan","segment");
        if(db.queryForObject("SELECT count(*) FROM goods WHERE id=:id AND NOT is_deleted",Map.of("id",goodsId),Long.class)==0)
            throw new ApiException(ErrorCode.NOT_FOUND,"货品不存在");
        var physical=new GoodsProductionTraceReadScope(stockAccess,warehouseAccess.readWarehouseScope(),has("stock_doc:view"),warehouseAccess.canAccessWarehouseTasks());
        String posting=physical.posting(),document=physical.document("document"),periodic=physical.periodic(),receipt=physical.receipt(),report=physical.warehouse("report.warehouse_id");
        physical.parameters.put("goods",goodsId);
        var selected=new Selection("usage".equals(direction)?"trace.material_goods_id=:goods":"segment.product_goods_id=:goods",
                Map.copyOf(physical.parameters),posting,document,periodic,receipt,"FALSE",report,false,null,null,null,null);
        return querySelected(selected,page,size);
    }

    PageResponse<TraceRow> querySelected(Selection selection,int page,int size) {
        if(!has("stock:view"))throw new ApiException(ErrorCode.FORBIDDEN,"没有库存查看权限");
        var scope=materialAccess.queryReadScope("plan","segment");
        int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));
        var params=new MapSqlParameterSource(scope.parameters()).addValues(selection.parameters())
                .addValue("limit",s).addValue("offset",(long)(p-1)*s);
        String physical="((trace.demand_id IS NOT NULL AND EXISTS(SELECT 1 FROM production_material_stock_postings posting "
                +"WHERE posting.demand_id=trace.demand_id AND ("+selection.postingPredicate()+"))) OR "
                +"(trace.allocation_id IS NOT NULL AND ("+selection.periodicPredicate()+")))";
        return load(TRACE_SQL.formatted("("+selection.predicate()+") AND "+physical,scope.predicate()),params,p,s,selection);
    }

    private PageResponse<TraceRow> load(String sql,MapSqlParameterSource params,int p,int s,Selection selection) {
        long total=Objects.requireNonNull(db.queryForObject(sql+"SELECT count(*) FROM visible",params,Long.class));
        List<Map<String,Object>> rows=db.queryForList(sql+"SELECT * FROM visible ORDER BY plan_no DESC,segment_code,kind,id LIMIT :limit OFFSET :offset",params);
        Set<UUID> goods=new LinkedHashSet<>(),colors=new LinkedHashSet<>(),units=new LinkedHashSet<>();
        for(var row:rows) {
            goods.add(id(row,"product_goods_id"));goods.add(id(row,"material_goods_id"));
            colors.add(id(row,"product_color_id"));colors.add(id(row,"material_color_id"));
            units.add(id(row,"product_unit_id"));units.add(id(row,"material_unit_id"));
        }
        Map<UUID,Map<String,Object>> identities=identities("goods",goods);
        Map<UUID,Map<String,Object>> colorNames=identities("colors",colors),unitNames=identities("units",units);
        Set<UUID> demands=new LinkedHashSet<>();
        for(var row:rows)if(id(row,"demand_id")!=null)demands.add(id(row,"demand_id"));
        var stockFacts=stockFacts(demands,selection);
        var settlementFacts=scopedSettlementFacts(demands,selection);
        var documents=documents(demands,selection);
        var reports=reports(rows,selection);
        var receipts=receipts(demands,selection);
        List<TraceRow> result=new ArrayList<>();
        for(var row:rows) {
            UUID demand=id(row,"demand_id"),segment=id(row,"segment_id");
            boolean order=demand!=null;
            BigDecimal issued=null,returned=null,consumed=null,loss=null;
            if(order&&!selection.narrowQuantities()) {
                var stock=stockFacts.getOrDefault(demand,Map.of());
                issued=zero(number(stock,"issued"));returned=zero(number(stock,"returned"));
                var settlement=settlementFacts.getOrDefault(demand,Map.of());
                consumed=number(settlement,"consumed");loss=number(settlement,"loss");
            }
            result.add(new TraceRow(row.get("kind")+":"+row.get("id"),(String)row.get("kind"),
                    selection.narrowQuantities()?"仅确认单据/批次关联；未逐批分摊用量":order?"实际领退料与核销":"期间盘点耗用分摊",id(row,"plan_id"),(String)row.get("plan_no"),segment,
                    (String)row.get("segment_code"),(String)row.get("workshop_name"),
                    identity(row,"product",identities,colorNames,unitNames),identity(row,"material",identities,colorNames,unitNames),
                    issued,returned,consumed,loss,selection.narrowQuantities()?null:number(row,"allocated_qty"),order?documents.getOrDefault(demand,List.of()):List.of(),
                    reports.getOrDefault(id(row,"id"),List.of()),order?receipts.getOrDefault(demand,List.of()):List.of()));
        }
        return new PageResponse<>(List.copyOf(result),p,s,total,(int)((total+s-1)/s));
    }

    private Map<UUID,Map<String,Object>> stockFacts(Set<UUID> demands,Selection selection) {
        if(demands.isEmpty())return Map.of();
        return keyed(db.queryForList("""
                SELECT demand_id,COALESCE(sum(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END),0) AS issued,
                       COALESCE(sum(CASE posting_type WHEN 'GOOD_RETURN' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base ELSE 0 END),0) AS returned
                FROM production_material_stock_postings posting WHERE demand_id IN (:demands) AND
                """+selection.postingPredicate()+" GROUP BY demand_id",
                selectionParams(demands,selection)),"demand_id");
    }

    private Map<UUID,Map<String,Object>> scopedSettlementFacts(Set<UUID> demands,Selection selection) {
        if(demands.isEmpty()||selection.narrowQuantities())return Map.of();
        var params=selectionParams(demands,selection);
        String recordedZero="FALSE";
        if(has("production_daily_report:view")) {
            var reportScope=productionDocuments.nativeReadScope("report.maker_id","zeroReportOwners",
                    "production_daily_report:approve","production_daily_report:reverse");
            if(reportScope.parameterName()!=null)params.addValue(reportScope.parameterName(),reportScope.owners());
            recordedZero="EXISTS(SELECT 1 FROM production_daily_report_material_usages usage "+
                    "JOIN production_daily_reports report ON report.id=usage.report_id "+
                    "WHERE usage.demand_id=demand.id AND usage.qty_base=0 AND report.status=1 AND NOT report.is_deleted AND NOT report.is_canceled AND "+
                    reportScope.predicate()+" AND ("+selection.reportPredicate()+"))"+
                    " AND NOT EXISTS(SELECT 1 FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id AND NOT ("+selection.postingPredicate()+"))"+
                    " AND NOT EXISTS(SELECT 1 FROM production_material_settlement_postings unresolved WHERE unresolved.demand_id=demand.id AND unresolved.settlement_type='CONSUMED' AND unresolved.issue_posting_id IS NULL)";
        }
        // Historical NULL issue_posting_id has no defensible warehouse/document attribution.
        return keyed(db.queryForList("""
                WITH settled AS (
                SELECT settled.demand_id,
                  sum(CASE event.event_type WHEN 'POST' THEN settled.qty_base ELSE -settled.qty_base END)
                    FILTER(WHERE settled.settlement_type='CONSUMED') AS consumed,
                  sum(CASE event.event_type WHEN 'POST' THEN settled.qty_base ELSE -settled.qty_base END)
                    FILTER(WHERE settled.settlement_type='APPROVED_LOSS') AS loss
                FROM production_material_settlement_postings settled
                JOIN production_material_settlement_events event ON event.id=settled.event_id
                JOIN production_material_stock_postings posting ON posting.id=settled.issue_posting_id
                WHERE settled.demand_id IN (:demands) AND
                """+selection.postingPredicate()+" GROUP BY settled.demand_id) SELECT demand.id AS demand_id,"+
                "COALESCE(settled.consumed,CASE WHEN "+recordedZero+" THEN 0::numeric END) AS consumed,settled.loss "+
                "FROM production_material_demands demand LEFT JOIN settled ON settled.demand_id=demand.id WHERE demand.id IN (:demands)",params),"demand_id");
    }

    private MapSqlParameterSource selectionParams(Set<UUID> demands,Selection selection) {
        return new MapSqlParameterSource(selection.parameters()).addValue("demands",demands);
    }

    private Map<UUID,List<DocumentRef>> documents(Set<UUID> demands,Selection selection) {
        if(demands.isEmpty()||!has("stock_doc:view"))return Map.of();
        var params=selectionParams(demands,selection);
        String predicate="("+selection.postingPredicate()+") AND ("+selection.documentPredicate()+")";
        var rows=db.queryForList("""
                SELECT DISTINCT posting.demand_id,document.id,document.bill_no,document.doc_type,document.bill_date
                FROM production_material_stock_postings posting
                JOIN production_material_stock_events event ON event.id=posting.event_id
                JOIN stock_documents document ON document.id=event.stock_document_id
                WHERE posting.demand_id IN (:demands) AND
                """+predicate+" ORDER BY document.bill_date,document.id",params);
        Map<UUID,List<DocumentRef>> result=new HashMap<>();
        for(var row:rows)result.computeIfAbsent(id(row,"demand_id"),ignored->new ArrayList<>()).add(
                new DocumentRef(id(row,"id"),(String)row.get("bill_no"),(String)row.get("doc_type"),date(row.get("bill_date"))));
        return result;
    }

    private Map<UUID,List<ProductionReport>> reports(List<Map<String,Object>> targets,Selection selection) {
        if(targets.isEmpty()||!has("production_daily_report:view"))return Map.of();
        List<UUID> demands=new ArrayList<>(),allocations=new ArrayList<>();
        for(var target:targets) {
            if(id(target,"demand_id")!=null)demands.add(id(target,"demand_id"));
            if(id(target,"allocation_id")!=null)allocations.add(id(target,"allocation_id"));
        }
        // An empty bound collection has no SQL meaning; the sentinel is never a real UUID.
        if(demands.isEmpty())demands.add(new UUID(0,0));
        if(allocations.isEmpty())allocations.add(new UUID(0,0));
        var reportScope=productionDocuments.nativeReadScope("report.maker_id","reportOwners",
                "production_daily_report:approve","production_daily_report:reverse");
        var params=new MapSqlParameterSource("demands",demands).addValue("allocations",allocations);
        if(selection!=null)params.addValues(selection.parameters());
        if(reportScope.parameterName()!=null)params.addValue(reportScope.parameterName(),reportScope.owners());
        List<Map<String,Object>> rows=db.queryForList("""
                WITH targets AS (
                    SELECT demand.id,demand.execution_segment_id,NULL::uuid AS allocation_id
                    FROM production_material_demands demand WHERE demand.id IN (:demands)
                    UNION ALL
                    SELECT allocation.id,allocation.cost_scope_segment_id,allocation.id
                    FROM workshop_material_close_allocations allocation WHERE allocation.id IN (:allocations))
                SELECT target.id AS trace_id,report.id,report.bill_no,report.bill_date,item.execution_segment_id,
                       sum(item.qty*COALESCE(item.unit_rate,1))/NULLIF(segment.product_unit_rate,0) AS product_qty,unit.name AS unit_name
                FROM targets target
                JOIN production_daily_report_items item ON (
                    (target.allocation_id IS NULL AND EXISTS(
                        SELECT 1 FROM fn_production_material_usage_source_segments(item.execution_segment_id) source
                        WHERE source.segment_id=target.execution_segment_id))
                    OR (target.allocation_id IS NOT NULL AND EXISTS(
                        SELECT 1 FROM workshop_material_close_theory_lines theory
                        JOIN workshop_material_close_allocations allocation ON allocation.id=target.allocation_id
                        JOIN workshop_material_close_materials material ON material.id=allocation.close_material_id
                        WHERE allocation.id=target.allocation_id AND theory.report_item_id=item.id
                          AND (theory.close_material_id=material.id OR (material.cost_basis='SHARED' AND theory.close_id=material.close_id))
                          AND theory.cost_scope_segment_id=allocation.cost_scope_segment_id)))
                JOIN production_daily_reports report ON report.id=item.report_id
                JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
                LEFT JOIN units unit ON unit.id=segment.product_unit_id
                LEFT JOIN production_fqc_recovery_authorizations recovery ON recovery.id=item.fqc_recovery_authorization_id
                WHERE report.status=1 AND NOT report.is_deleted AND NOT report.is_canceled
                  AND NOT item.is_deleted AND COALESCE(recovery.disposition_code,'')<>'REWORK' AND
                """+reportScope.predicate()+reportFilter(selection)+"""
                   AND (target.allocation_id IS NOT NULL OR item.execution_segment_id=target.execution_segment_id OR EXISTS(
                       SELECT 1 FROM production_material_settlement_events event
                       JOIN production_material_settlement_postings posting ON posting.event_id=event.id
                       WHERE event.daily_report_id=report.id AND posting.demand_id=target.id))
                GROUP BY target.id,report.id,item.execution_segment_id,segment.product_unit_rate,unit.name
                ORDER BY report.bill_date,report.id,item.execution_segment_id
                """,params);
        Set<UUID> reportIds=new LinkedHashSet<>();for(var row:rows)reportIds.add(id(row,"id"));
        Map<UUID,List<Worker>> participants=new HashMap<>();
        if(!reportIds.isEmpty())for(var worker:db.queryForList("""
                SELECT worker.report_id,worker.employee_id,employee.full_name AS name FROM production_daily_report_workers worker
                JOIN employees employee ON employee.id=worker.employee_id WHERE worker.report_id IN (:reports)
                ORDER BY worker.report_id,worker.sort_order
                """,Map.of("reports",reportIds))) {
            participants.computeIfAbsent(id(worker,"report_id"),ignored->new ArrayList<>()).add(
                    new Worker(id(worker,"employee_id"),(String)worker.get("name")));
        }
        Map<UUID,List<ProductionReport>> result=new HashMap<>();
        Map<String,List<OutputBatch>> batches=outputBatches(reportIds,selection);
        for(var row:rows) {
            UUID report=id(row,"id");
            result.computeIfAbsent(id(row,"trace_id"),ignored->new ArrayList<>()).add(
                    new ProductionReport(report,(String)row.get("bill_no"),date(row.get("bill_date")),
                    id(row,"execution_segment_id"),number(row,"product_qty"),(String)row.get("unit_name"),participants.getOrDefault(report,List.of()),
                    batches.getOrDefault(report+":"+id(row,"execution_segment_id"),List.of())));
        }
        return result;
    }

    private Map<UUID,List<ReceiptSource>> receipts(Set<UUID> demands,Selection selection) {
        if(demands.isEmpty())return Map.of();
        Map<UUID,List<ReceiptSource>> result=new HashMap<>();
        if(has("purchase_receipt:view")) {
        var scope=purchaseDocuments.nativeReadScope("receipt.maker_id","receiptOwners");
        var params=selectionParams(demands,selection);
        if(scope.parameterName()!=null)params.addValue(scope.parameterName(),scope.owners());
        boolean suppliers=has("supplier:view");
        var rows=db.queryForList("""
                SELECT allocation.demand_id,receipt.id,receipt.bill_no,allocation.receipt_item_id,receipt.bill_date,receipt.supplier_id,
                       supplier.name AS supplier_name,allocation.allocated_qty AS qty
                FROM production_material_receipt_allocations allocation
                JOIN purchase_receipts receipt ON receipt.id=allocation.receipt_id
                LEFT JOIN suppliers supplier ON supplier.id=receipt.supplier_id
                WHERE allocation.demand_id IN (:demands) AND allocation.status='EFFECTIVE'
                  AND EXISTS(SELECT 1 FROM production_material_stock_postings posting
                      WHERE posting.demand_id=allocation.demand_id AND posting.reservation_id=allocation.reservation_id
                        AND posting.stock_document_item_id=allocation.draw_item_id AND posting.posting_type='ISSUE') AND
                """+scope.predicate()+(selection==null?"":" AND ("+selection.receiptPredicate()+")")+" ORDER BY receipt.bill_date,receipt.id,allocation.id",params);
        for(var row:rows)result.computeIfAbsent(id(row,"demand_id"),ignored->new ArrayList<>()).add(
                new ReceiptSource(id(row,"id"),(String)row.get("bill_no"),id(row,"receipt_item_id"),date(row.get("bill_date")),
                        suppliers?id(row,"supplier_id"):null,suppliers?(String)row.get("supplier_name"):null,
                        number(row,"qty"),"采购入库预留分配来源（非逐批实耗）",StockLedgerSource.PURCHASE_RECEIPT.code(),null));
        }
        if(selection!=null&&!"FALSE".equals(selection.subcontractReceiptPredicate())) {
            boolean suppliers=has("supplier:view");
            var rows=db.queryForList("""
                    SELECT allocation.demand_id,receipt.id,receipt.bill_no,allocation.receipt_item_id,receipt.bill_date,receipt.supplier_id,
                           supplier.name AS supplier_name,allocation.allocated_qty AS qty
                    FROM production_material_subcontract_receipt_allocations allocation
                    JOIN subcontract_receipts receipt ON receipt.id=allocation.receipt_id
                    LEFT JOIN suppliers supplier ON supplier.id=receipt.supplier_id
                    WHERE allocation.demand_id IN (:demands) AND allocation.status='EFFECTIVE' AND
                    """+selection.subcontractReceiptPredicate()+" ORDER BY receipt.bill_date,receipt.id,allocation.id",selectionParams(demands,selection));
            for(var row:rows)result.computeIfAbsent(id(row,"demand_id"),ignored->new ArrayList<>()).add(
                    new ReceiptSource(id(row,"id"),(String)row.get("bill_no"),id(row,"receipt_item_id"),date(row.get("bill_date")),
                            suppliers?id(row,"supplier_id"):null,suppliers?(String)row.get("supplier_name"):null,
                            number(row,"qty"),"委外回厂入库预留分配来源（非逐批实耗）",StockLedgerSource.SUBCONTRACT_RECEIPT.code(),null));
        }
        return result;
    }

    private String reportFilter(Selection selection) {
        if(selection==null)return "";
        return " AND ("+selection.reportPredicate()+")"+(selection.reportId()==null?"":" AND report.id=:selectedReport")
                +(selection.lotId()==null?"":" AND item.output_lot_id=:selectedLot")
                +(selection.dateFrom()==null?"":" AND report.bill_date>=:traceDateFrom")
                +(selection.dateTo()==null?"":" AND report.bill_date<=:traceDateTo");
    }

    private Map<String,List<OutputBatch>> outputBatches(Set<UUID> reportIds,Selection selection) {
        if(reportIds.isEmpty())return Map.of();
        var params=new MapSqlParameterSource("batchReports",reportIds);
        if(selection!=null)params.addValues(selection.parameters());
        var rows=db.queryForList("""
                SELECT item.report_id,item.execution_segment_id,item.output_lot_id,item.id,item.qty,item.line_no,report.bill_no,unit.name AS unit_name
                FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
                LEFT JOIN units unit ON unit.id=item.unit_id
                LEFT JOIN production_fqc_recovery_authorizations recovery ON recovery.id=item.fqc_recovery_authorization_id
                WHERE item.report_id IN (:batchReports) AND NOT item.is_deleted AND item.output_lot_id IS NOT NULL
                  AND COALESCE(recovery.disposition_code,'')<>'REWORK'
                """+reportFilter(selection)+" ORDER BY item.report_id,item.execution_segment_id,item.line_no,item.id",params);
        Map<String,List<OutputBatch>> result=new HashMap<>();
        for(var row:rows)result.computeIfAbsent(id(row,"report_id")+":"+id(row,"execution_segment_id"),ignored->new ArrayList<>())
                .add(new OutputBatch(id(row,"output_lot_id"),null,id(row,"id"),number(row,"qty"),(String)row.get("unit_name"),
                        (Integer)row.get("line_no"),row.get("bill_no")+(row.get("line_no")==null?" · 产出批次未编号":" · 第"+row.get("line_no")+"行产出批次")));
        return result;
    }

    private Map<UUID,Map<String,Object>> identities(String table,Set<UUID> ids) {
        ids.remove(null);if(ids.isEmpty())return Map.of();
        Map<UUID,Map<String,Object>> result=new HashMap<>();
        for(var row:db.queryForList("SELECT id,name"+("goods".equals(table)?",code":"")+" FROM "+table+" WHERE id IN (:ids)",Map.of("ids",ids)))result.put(id(row,"id"),row);
        return result;
    }
    private GoodsIdentity identity(Map<String,Object> row,String prefix,Map<UUID,Map<String,Object>> goods,
            Map<UUID,Map<String,Object>> colors,Map<UUID,Map<String,Object>> units) {
        UUID gid=id(row,prefix+"_goods_id"),cid=id(row,prefix+"_color_id"),uid=id(row,prefix+"_unit_id");
        Map<String,Object> good=goods.getOrDefault(gid,Map.of()),color=cid==null?Map.of():colors.getOrDefault(cid,Map.of()),
                unit=uid==null?Map.of():units.getOrDefault(uid,Map.of());
        return new GoodsIdentity(gid,(String)good.get("code"),(String)good.get("name"),cid,(String)color.get("name"),uid,(String)unit.get("name"));
    }
    private boolean has(String permission) {return currentUser.get().map(user->user.isSuperAdmin()||user.getAuthorities().stream()
            .anyMatch(authority->permission.equals(authority.getAuthority()))).orElse(false);}
    private static UUID id(Map<String,Object> row,String key) {return (UUID)row.get(key);}
    private static BigDecimal number(Map<String,Object> row,String key) {return (BigDecimal)row.get(key);}
    private static BigDecimal zero(BigDecimal value) {return value==null?BigDecimal.ZERO:value;}
    private static Map<UUID,Map<String,Object>> keyed(List<Map<String,Object>> rows,String key) {
        Map<UUID,Map<String,Object>> result=new HashMap<>();for(var row:rows)result.put(id(row,key),row);return result;
    }
    private static LocalDate date(Object value) {return value instanceof java.sql.Date date?date.toLocalDate():(LocalDate)value;}
}
