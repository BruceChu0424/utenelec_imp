package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.math.*;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsSubcontractSupplierContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceSourceReader.decimalText;

@Service
@RequiredArgsConstructor
@Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
public class GoodsSubcontractSupplierService {
    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    private final MasterReferenceValidationPort references;
    private final GoodsPriceAccess access;
    private static final int MAX_LINES=500;
    private static final String SUMMARY="确认损耗率＝已足额发料、结清且依据完整的订单行有效确认损耗量÷这些行的原订货量。按订货日期筛选，读取当前有效履约；不是期间内结案统计。不同颜色、单位换算和冻结用料方案分别统计。未回厂、待检和未入仓不算损耗；材料退料或报损不直接折成成品损耗。";

    // Scope and limit precede all child facts. Each lateral returns one row, preventing
    // receipt x return x loss multiplication. Existing fulfillment functions own loss/kit arithmetic.
    static final String FACTS_SQL="""
        WITH eligible AS MATERIALIZED (
            SELECT o.id order_id,o.bill_no,o.bill_date,o.supplier_id,o.maker_id,o.updated_at order_updated_at,
                   i.id order_item_id,i.goods_id,i.goods_code_snapshot,i.goods_name_snapshot,i.color_id,i.unit_id,i.unit_rate,
                   i.qty,i.allowed_loss_pct,i.updated_at item_updated_at
            FROM subcontract_orders o JOIN subcontract_order_items i ON i.order_id=o.id
            WHERE o.status=1 AND NOT o.is_deleted AND NOT i.is_deleted AND i.goods_id=:goods
              AND o.bill_date BETWEEN :from AND :to
              AND (CAST(:supplier AS uuid) IS NULL OR o.supplier_id=CAST(:supplier AS uuid)) %s
            ORDER BY o.bill_date DESC,o.id,i.id LIMIT 501
        )
        SELECT e.*,supplier.name supplier_name,unit.name unit_name,color.name color_name,
               fn_subcontract_settled_loss_qty(e.order_item_id) confirmed_loss_qty,
               accepted.legacy_loss_qty,accepted.legacy_count,accepted.mismatch_count,
               material.material_basis,material.material_count,material.material_bad_count,material.all_sent,material.issued_sets,
               receipt.received_qty,receipt.stocked_base,receipt.passed_base,receipt.pending_base,
               receipt.receipt_count,receipt.bad_count receipt_bad_count,
               returned.returned_qty,returned.returned_base,returned.bad_count return_bad_count,
               supplier_own.own_qty,
               approval.id approval_case_id,approval.status approval_status,approval.submission_snapshot approval_snapshot,approval.decided_at approval_decided_at
        FROM eligible e
        LEFT JOIN suppliers supplier ON supplier.id=e.supplier_id
        LEFT JOIN units unit ON unit.id=e.unit_id LEFT JOIN colors color ON color.id=e.color_id
        LEFT JOIN LATERAL (
            SELECT a.id,a.status,a.submission_snapshot,a.decided_at FROM procurement_order_approval_cases a
            WHERE a.order_type='SUBCONTRACT' AND a.order_id=e.order_id AND a.request_type='ORDER' ORDER BY a.attempt DESC LIMIT 1
        ) approval ON true
        LEFT JOIN LATERAL (
            SELECT COALESCE(SUM(c.loss_qty) FILTER(WHERE c.qty_change_log_id IS NOT NULL),0) legacy_loss_qty,
                   COUNT(*) FILTER(WHERE c.qty_change_log_id IS NOT NULL) legacy_count,
                   COUNT(*) FILTER(WHERE c.supplier_id IS DISTINCT FROM e.supplier_id OR c.goods_id IS DISTINCT FROM e.goods_id
                     OR c.color_id IS DISTINCT FROM e.color_id OR c.unit_id IS DISTINCT FROM e.unit_id OR c.ordered_qty IS DISTINCT FROM e.qty
                     OR c.goods_code_snapshot IS DISTINCT FROM e.goods_code_snapshot OR c.goods_name_snapshot IS DISTINCT FROM e.goods_name_snapshot) mismatch_count
            FROM subcontract_short_delivery_cases c
            WHERE c.order_item_id=e.order_item_id AND c.status='ACCEPTED_LOSS' AND c.decision='ACCEPT_LOSS'
              AND c.closed_at IS NOT NULL AND c.loss_qty>0
              AND (c.waste_id IS NULL OR EXISTS(SELECT 1 FROM subcontract_wastes w WHERE w.id=c.waste_id AND w.status=1 AND NOT w.is_deleted))
        ) accepted ON true
        LEFT JOIN LATERAL (
            SELECT COUNT(DISTINCT (m.goods_id,m.color_id,m.unit_id,m.unit_rate,m.bom_unit_qty)) material_count,
                   COUNT(*) FILTER(WHERE m.unit_id IS NULL OR m.unit_rate IS NULL OR m.unit_rate<=0 OR m.bom_unit_qty IS NULL OR m.bom_unit_qty<=0
                         OR m.issued_qty IS NULL OR m.issued_qty<0 OR m.planned_qty IS NULL OR m.planned_qty<=0
                         OR plan.status='CANCELED' OR plan.is_deleted OR m.parent_goods_id IS DISTINCT FROM e.goods_id
                         OR m.parent_color_id IS DISTINCT FROM e.color_id) material_bad_count,
                   BOOL_AND(m.issued_qty>=m.planned_qty) all_sent,
                   MIN(fn_subcontract_draw_sets(m.issued_qty,m.bom_unit_qty)) issued_sets,
                   jsonb_agg(DISTINCT jsonb_build_object('goods',m.goods_id,'color',m.color_id,'unit',m.unit_id,
                       'rate',trim_scale(m.unit_rate)::text,'perOrderUnit',trim_scale(m.bom_unit_qty)::text)
                       ORDER BY jsonb_build_object('goods',m.goods_id,'color',m.color_id,'unit',m.unit_id,
                           'rate',trim_scale(m.unit_rate)::text,'perOrderUnit',trim_scale(m.bom_unit_qty)::text))::text material_basis
            FROM subcontract_material_plan_items m JOIN subcontract_material_plans plan ON plan.id=m.plan_id
            WHERE m.order_item_id=e.order_item_id AND NOT m.is_deleted
        ) material ON true
        LEFT JOIN LATERAL (
            SELECT COUNT(*) receipt_count,COALESCE(SUM(ri.qty),0) received_qty,
                   COALESCE(SUM(iqc.stocked),0) stocked_base,COALESCE(SUM(iqc.passed),0) passed_base,
                   COALESCE(SUM(iqc.received-iqc.passed-iqc.failed),0) pending_base,
                   COUNT(*) FILTER(WHERE iqc.n<>1 OR ri.qty IS NULL OR ri.qty<=0 OR iqc.passed IS NULL OR iqc.failed IS NULL OR iqc.stocked IS NULL
                       OR ri.goods_id IS DISTINCT FROM e.goods_id OR ri.color_id IS DISTINCT FROM e.color_id
                       OR ri.unit_id IS DISTINCT FROM e.unit_id OR ri.unit_rate IS DISTINCT FROM e.unit_rate
                       OR iqc.received IS DISTINCT FROM ROUND(ri.qty*ri.unit_rate,4)
                       OR iqc.stocked<0 OR iqc.stocked>iqc.passed OR iqc.passed<0 OR iqc.failed<0
                       OR iqc.passed+iqc.failed>iqc.received) bad_count
            FROM subcontract_receipt_items ri JOIN subcontract_receipts r ON r.id=ri.receipt_id
            LEFT JOIN LATERAL (
                SELECT COUNT(*) n,SUM(i.received_base_qty) received,SUM(i.passed_base_qty) passed,
                       SUM(i.failed_base_qty) failed,SUM(i.warehouse_stocked_base_qty) stocked
                FROM procurement_inspection_items i WHERE i.receipt_type='SUBCONTRACT' AND i.receipt_item_id=ri.id
                  AND i.status<>'REVERSED' AND i.quantity_tranche<>'GIFT'
            ) iqc ON true
            WHERE ri.order_item_id=e.order_item_id AND r.status=1 AND NOT r.is_deleted AND NOT ri.is_deleted
        ) receipt ON true
        LEFT JOIN LATERAL (
            SELECT COALESCE(SUM(ri.qty),0) returned_qty,COALESCE(SUM(ROUND(ri.qty*ri.unit_rate,4)),0) returned_base,
                   COUNT(*) FILTER(WHERE ri.qty IS NULL OR ri.qty<=0 OR ri.goods_id IS DISTINCT FROM e.goods_id OR ri.color_id IS DISTINCT FROM e.color_id
                       OR ri.unit_id IS DISTINCT FROM e.unit_id OR ri.unit_rate IS DISTINCT FROM e.unit_rate) bad_count
            FROM subcontract_return_items ri JOIN subcontract_returns r ON r.id=ri.return_id
            WHERE ri.order_item_id=e.order_item_id AND r.status=1 AND NOT r.is_deleted AND NOT ri.is_deleted
        ) returned ON true
        LEFT JOIN LATERAL (
            SELECT COALESCE(SUM(a.approved_excess_qty),0) own_qty FROM procurement_arrival_exceptions a
            WHERE a.order_type='SUBCONTRACT' AND a.order_item_id=e.order_item_id AND a.status IN('RECEIPT_ADJUSTED','RECEIPT_POSTED','CLOSED')
              AND a.decision IN('APPROVE_ALL','APPROVE_CUSTOM') AND a.approved_excess_qty>0
        ) supplier_own ON true
        ORDER BY e.bill_date DESC,e.order_id,e.order_item_id
        """;

    /** Cheap tab eligibility; no receipt, material, approval or loss facts are queried. */
    public Capability capability(UUID goodsId) {
        if(goodsId==null)throw invalid("请选择货品");
        access.require(GoodsPriceContracts.Kind.SUBCONTRACT);references.requireVisibleGoods(goodsId);
        var goods=db.queryForList("SELECT source_type FROM goods WHERE id=:id AND NOT is_deleted AND NOT auto_created",Map.of("id",goodsId));
        if(goods.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"货品不存在或无权查看");
        return new Capability(goodsId,"委外".equals(goods.getFirst().get("source_type")));
    }

    public Result read(UUID goodsId,Integer requestedDays,UUID supplierId) {
        if(goodsId==null)throw invalid("请选择货品");
        access.require(GoodsPriceContracts.Kind.SUBCONTRACT);references.requireVisibleGoods(goodsId);
        int days=requestedDays==null?180:requestedDays;
        if(days<1||days>730)throw invalid("统计期间应为1至730天");
        var goods=db.queryForList("SELECT source_type FROM goods WHERE id=:id AND NOT is_deleted AND NOT auto_created",Map.of("id",goodsId));
        if(goods.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"货品不存在或无权查看");
        if(!"委外".equals(goods.getFirst().get("source_type")))return result(goodsId,false,"NOT_APPLICABLE",true,days,List.of("NOT_SUBCONTRACT_GOODS"),List.of());
        var scope=access.sourceScope(GoodsPriceContracts.Kind.SUBCONTRACT);
        var params=new MapSqlParameterSource().addValue("goods",goodsId).addValue("supplier",supplierId)
                .addValue("from",BusinessTime.today().minusDays(days-1L)).addValue("to",BusinessTime.today());
        String owner=scope.seeAll()?"":scope.visibleOwners().isEmpty()?" AND 1=0":" AND o.maker_id IN (:owners)";
        if(!scope.seeAll()&&!scope.visibleOwners().isEmpty())params.addValue("owners",scope.visibleOwners());
        var rows=db.queryForList(FACTS_SQL.formatted(owner),params);
        if(rows.size()>MAX_LINES)return result(goodsId,true,"LIMIT_EXCEEDED",false,days,List.of("SOURCE_LIMIT_EXCEEDED"),List.of());
        Map<String,List<Fact>> cohorts=new LinkedHashMap<>();
        for(var row:rows){Fact fact=fact(row);cohorts.computeIfAbsent(fact.key(),ignored->new ArrayList<>()).add(fact);}
        List<Group> groups=cohorts.values().stream().map(this::group).sorted(Comparator.comparing(Group::supplierName,Comparator.nullsLast(String::compareTo))
                .thenComparing(Group::key)).toList();
        String state=groups.isEmpty()?"NO_DATA":groups.stream().anyMatch(g->g.settledLineCount()>0)?"READY":"INSUFFICIENT";
        return result(goodsId,true,state,true,days,List.of(),groups);
    }
    private record Fact(String key,String materialKey,Map<String,Object> source,Line line) {}
    private Fact fact(Map<String,Object> r) {
        List<String> excluded=new ArrayList<>(),pending=new ArrayList<>();
        BigDecimal ordered=number(r,"qty"),rate=number(r,"unit_rate"),loss=number(r,"confirmed_loss_qty"),legacy=number(r,"legacy_loss_qty");
        if(ordered==null||ordered.signum()<=0||rate==null||rate.signum()<=0||r.get("unit_id")==null||r.get("supplier_id")==null)excluded.add("ORDER_QUANTITY_BASIS_INCOMPLETE");
        if(!approvedBasis(r))excluded.add("APPROVED_QUANTITY_BASIS_UNPROVEN");
        if(r.get("approval_decided_at")!=null&&timestamp(r.get("approval_decided_at")).isAfter(Instant.now()))excluded.add("APPROVAL_NOT_EFFECTIVE");
        if(count(r,"legacy_count")>0)excluded.add("LEGACY_LOSS_REQUIRES_REVIEW");
        if(count(r,"mismatch_count")>0)excluded.add("LOSS_SNAPSHOT_MISMATCH");
        if(loss==null||loss.signum()<0||ordered!=null&&loss.compareTo(ordered)>0)excluded.add("LOSS_QUANTITY_INCONSISTENT");
        if(count(r,"material_count")==0||count(r,"material_bad_count")>0)excluded.add("MATERIAL_BASIS_INCOMPLETE");
        if(count(r,"receipt_bad_count")>0||count(r,"return_bad_count")>0)excluded.add("QUALITY_OR_UNIT_EVIDENCE_INCOMPLETE");
        if(number(r,"own_qty").signum()>0)excluded.add("SUPPLIER_OWN_MATERIAL_BASIS");
        BigDecimal netStock=number(r,"stocked_base").subtract(number(r,"returned_base"));
        if(netStock.signum()<0)excluded.add("RETURN_QUANTITY_INCONSISTENT");
        if(number(r,"pending_base").signum()>0||number(r,"passed_base").compareTo(number(r,"stocked_base"))>0)pending.add("QUALITY_OR_STOCK_PENDING");
        if(!Boolean.TRUE.equals(r.get("all_sent")))pending.add("MATERIAL_ISSUE_PENDING");
        if(count(r,"receipt_count")==0)pending.add("NO_QUALIFIED_RECEIPT");
        if(ordered!=null&&ordered.signum()>0&&rate!=null&&rate.signum()>0&&loss!=null) {
            int balance=netStock.add(MoneyPolicy.quantity(loss.multiply(rate))).compareTo(MoneyPolicy.quantity(ordered.multiply(rate)));
            if(balance<0)pending.add("DELIVERY_NOT_SETTLED");else if(balance>0)excluded.add("DELIVERY_BASIS_EXCEEDED");
        }
        String status=!excluded.isEmpty()?"EXCLUDED":!pending.isEmpty()?"PENDING":"SETTLED";
        List<String> reasons=new ArrayList<>(excluded);reasons.addAll(pending);
        boolean trustworthyQuantities=count(r,"receipt_bad_count")==0&&count(r,"return_bad_count")==0;
        String materialKey=r.get("material_basis")==null?"UNKNOWN":GoodsPriceSourceReader.hash(r.get("material_basis").toString());
        String key=GoodsPriceSourceReader.hash(Arrays.asList(r.get("supplier_id"),r.get("color_id"),r.get("unit_id"),decimalText(rate),materialKey).toString());
        BigDecimal issued=number(r,"issued_sets");
        Line line=new Line(id(r,"order_id"),id(r,"order_item_id"),text(r,"bill_no"),date(r,"bill_date"),GoodsPriceSourceReader.hash(new TreeMap<>(r).toString()),
                id(r,"approval_case_id"),status,"SETTLED".equals(status),decimalText(ordered),issued==null?null:decimalText(ordered==null?issued:issued.min(ordered)),
                trustworthyQuantities?decimalText(number(r,"received_qty")):null,trustworthyQuantities?decimalText(number(r,"returned_qty")):null,
                trustworthyQuantities&&rate!=null&&rate.signum()>0&&netStock.signum()>=0?decimalText(netStock.divide(rate,MathContext.DECIMAL128)):null,
                decimalText(loss),decimalText(legacy),decimalText(number(r,"allowed_loss_pct")),List.copyOf(reasons),access.has("subcontract_order:view"));
        return new Fact(key,materialKey,r,line);
    }
    private boolean approvedBasis(Map<String,Object> r) {
        if(r.get("approval_case_id")==null||!"APPROVED".equals(r.get("approval_status"))||r.get("approval_decided_at")==null
                ||timestamp(r.get("approval_decided_at")).isAfter(Instant.now()))return false;
        try {
            JsonNode snapshot=json.readTree(Objects.toString(r.get("approval_snapshot"),"null"));
            if(!equal(snapshot,"orderId",r.get("order_id"))||!equal(snapshot,"supplierId",r.get("supplier_id")))return false;
            int found=0;boolean valid=false;
            for(JsonNode item:snapshot.path("items"))if(equal(item,"itemId",r.get("order_item_id"))) {
                found++;valid=equal(item,"goodsId",r.get("goods_id"))&&equal(item,"colorId",r.get("color_id"))&&equal(item,"unitId",r.get("unit_id"))
                    &&equalNumber(item,"unitRate",number(r,"unit_rate"))&&equalNumber(item,"qty",number(r,"qty"));
            }
            return found==1&&valid;
        }catch(Exception missing){return false;}
    }
    private Group group(List<Fact> facts) {
        var first=facts.getFirst();var r=first.source();var lines=facts.stream().map(Fact::line).toList();
        var settled=lines.stream().filter(Line::included).toList();
        BigDecimal denominator=settled.stream().map(l->new BigDecimal(l.orderedQty())).reduce(BigDecimal.ZERO,BigDecimal::add);
        BigDecimal numerator=settled.stream().map(l->new BigDecimal(l.confirmedLossQty())).reduce(BigDecimal.ZERO,BigDecimal::add);
        List<BigDecimal> allowed=lines.stream().map(Line::allowedLossPct).filter(Objects::nonNull).map(BigDecimal::new).toList();
        var reasons=new LinkedHashSet<String>();lines.forEach(l->reasons.addAll(l.reasonCodes()));if(settled.isEmpty())reasons.add("NO_SETTLED_COMPARABLE_ORDERS");
        return new Group(first.key(),id(r,"supplier_id"),text(r,"supplier_name"),id(r,"color_id"),text(r,"color_name"),id(r,"unit_id"),text(r,"unit_name"),decimalText(number(r,"unit_rate")),
                first.materialKey(),(int)count(r,"material_count"),(int)lines.stream().map(Line::orderId).distinct().count(),
                (int)settled.stream().map(Line::orderId).distinct().count(),lines.size(),settled.size(),(int)lines.stream().filter(l->"PENDING".equals(l.status())).count(),
                (int)lines.stream().filter(l->"EXCLUDED".equals(l.status())).count(),settled.isEmpty()?null:decimalText(denominator),settled.isEmpty()?null:decimalText(numerator),
                denominator.signum()>0?decimalText(numerator.multiply(BigDecimal.valueOf(100)).divide(denominator,MathContext.DECIMAL128)):null,
                allowed.stream().min(BigDecimal::compareTo).map(GoodsPriceSourceReader::decimalText).orElse(null),allowed.stream().max(BigDecimal::compareTo).map(GoodsPriceSourceReader::decimalText).orElse(null),
                lines.stream().map(Line::orderDate).filter(Objects::nonNull).max(LocalDate::compareTo).orElse(null),List.copyOf(reasons),lines);
    }
    private static Result result(UUID goods,boolean applicable,String state,boolean complete,int days,List<String> reasons,List<Group> groups){return new Result(goods,applicable,state,complete,days,OffsetDateTime.now(),SUMMARY,reasons,groups);}
    private static boolean equal(JsonNode node,String key,Object value){JsonNode v=node.get(key);return value==null?v==null||v.isNull():v!=null&&!v.isNull()&&value.toString().equals(v.asText());}
    private static boolean equalNumber(JsonNode node,String key,BigDecimal value){JsonNode v=node.get(key);return value!=null&&v!=null&&!v.isNull()&&value.compareTo(new BigDecimal(v.asText()))==0;}
    private static BigDecimal number(Map<String,Object> r,String k){return (BigDecimal)r.get(k);}
    private static long count(Map<String,Object> r,String k){return r.get(k)==null?0:((Number)r.get(k)).longValue();}
    private static UUID id(Map<String,Object> r,String k){return (UUID)r.get(k);}
    private static String text(Map<String,Object> r,String k){return r.get(k)==null?null:r.get(k).toString();}
    private static LocalDate date(Map<String,Object> r,String k){Object v=r.get(k);return v instanceof LocalDate d?d:((java.sql.Date)v).toLocalDate();}
    private static Instant timestamp(Object value){return value instanceof OffsetDateTime t?t.toInstant():((java.sql.Timestamp)value).toInstant();}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
