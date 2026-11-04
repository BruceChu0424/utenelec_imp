package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.CurrentAuthorityGuard;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Real physical slices only. This purpose never reads prices or writes stock/GL. */
@Service @RequiredArgsConstructor
public class FinanceMaterialPhysicalSourceReader implements FinanceMaterialStatementSourcePort {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final FinanceDocumentAccessPolicy access;
    private void authorize(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}

    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Page candidates(Query q){
        authorize();if(q==null||q.kind()==null||q.dateFrom()==null||q.dateTo()==null||q.dateFrom().isAfter(q.dateTo()))throw invalid("请选择真实来源类型及完整期间");
        if(q.colorMode()==ColorMode.EXACT&&q.colorId()==null)throw invalid("精确颜色筛选须提供颜色编号");
        var args=new ArrayList<Object>();String where=" WHERE EXISTS(SELECT 1 FROM ("+movements(q.kind())+") effect WHERE effect.line_id=physical.line_id AND effect.business_date BETWEEN ? AND ?)";
        args.add(q.dateFrom());args.add(q.dateTo());
        if(q.supplierId()!=null){where+=" AND supplier_id=?";args.add(q.supplierId());}
        if(q.customerId()!=null){where+=" AND customer_id=?";args.add(q.customerId());}
        if(q.goodsId()!=null){where+=" AND goods_id=?";args.add(q.goodsId());}
        if(q.colorMode()==null||q.colorMode()==ColorMode.NO_COLOR)where+=" AND color_id IS NULL";
        else if(q.colorMode()==ColorMode.EXACT){where+=" AND color_id=?";args.add(q.colorId());}
        for(String term:KeywordSearch.terms(q.keyword())){
            where+=" AND (bill_no ILIKE ? ESCAPE '\\' OR goods_code ILIKE ? ESCAPE '\\' OR goods_name ILIKE ? ESCAPE '\\' OR specification ILIKE ? ESCAPE '\\' OR document_remark ILIKE ? ESCAPE '\\' OR item_remark ILIKE ? ESCAPE '\\')";
            for(int i=0;i<6;i++)args.add(KeywordSearch.containsPattern(term));
        }
        String source=" FROM ("+source(q.kind())+") physical";
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+source+where,Long.class,args.toArray()));
        int page=Math.max(1,q.page()),size=Math.max(1,Math.min(200,q.size()));args.add(size);args.add((long)(page-1)*size);
        var rows=db.queryForList("SELECT *"+source+where+" ORDER BY business_date,bill_no,line_id LIMIT ? OFFSET ?",args.toArray());
        var facts=facts(q.kind(),rows,q.includeDerivedQuantity());
        return new Page(facts,page,size,total,(int)((total+size-1)/size));
    }
    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public List<Fact> read(List<Key> keys){return readInternal(keys,true);}
    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public List<Fact> readForIdentity(List<Key> keys){return readInternal(keys,false);}
    private List<Fact> readInternal(List<Key> keys,boolean derived){
        authorize();if(keys==null||keys.isEmpty()||keys.size()>200||keys.stream().anyMatch(k->k==null||k.kind()==null||k.lineId()==null))throw invalid("请提供1至200条明确真实来源行");
        var byKind=new EnumMap<Kind,Set<UUID>>(Kind.class);keys.forEach(k->byKind.computeIfAbsent(k.kind(),ignored->new LinkedHashSet<>()).add(k.lineId()));
        var found=new HashMap<Key,Fact>();
        byKind.forEach((kind,ids)->{
            var rows=db.queryForList("SELECT * FROM ("+source(kind)+") physical WHERE line_id IN("+slots(ids.size())+")",ids.toArray());
            facts(kind,rows,derived).forEach(f->{if(derived&&!f.approved())throw invalid("来源尚不能证明真实已入/出库效应，请核对原单号与实际入库批次");found.put(f.key(),f);});
        });
        var result=new ArrayList<Fact>();for(var k:keys){var f=found.get(k);if(f==null)throw new ApiException(ErrorCode.NOT_FOUND,"所选原始物理来源不存在");result.add(f);}return List.copyOf(result);
    }
    private List<Fact> facts(Kind kind,List<Map<String,Object>> rows,boolean derived){
        if(rows.isEmpty())return List.of();var ids=rows.stream().map(r->r.get("line_id")).toList();
        var effects=new HashMap<UUID,List<Effect>>();int effectCount=0;
        for(var r:db.queryForList("SELECT * FROM ("+movements(kind)+") movement WHERE line_id IN("+slots(ids.size())+") ORDER BY transaction_date,ledger_seq,movement_id LIMIT 20001",ids.toArray())){
            if(++effectCount>20000)throw invalid("本次原单实际切片超过20000条安全读取范围，未截断或确认金额，请按真实来源范围分段核对");
            var s=new TreeMap<String,Object>();for(String key:List.of("movement_id","stock_in_item_id","business_date","source_business_date","confirmation_date","transaction_date","event_sign","is_reversal","warehouse_id","unit_id","base_quantity","unit_rate","weight","weight_source","goods_id","color_id","quantity_tranche","pass_event_id"))s.put(key,normal(r.get(key)));
            var base=decimal(r.get("base_quantity"));var rate=decimal(r.get("unit_rate"));BigDecimal quantity=null;
            if(derived&&base!=null&&rate!=null&&rate.signum()>0)quantity=FinancialExactAmount.book(BusinessPrecisionContext.divide(base,rate,"finance.material.sourceQuantity","本次来源单位数量",30),"来源单位数量");
            var weight=decimal(r.get("weight"));String weightSource=Objects.toString(r.get("weight_source"),"");
            boolean measured=Set.of("MEASURED","EXACT","SLICE").contains(weightSource);
            var effect=new Effect((UUID)r.get("movement_id"),(UUID)r.get("stock_in_item_id"),date(r.get("business_date")),date(r.get("source_business_date")),date(r.get("confirmation_date")),((Number)r.get("event_sign")).intValue(),Boolean.TRUE.equals(r.get("is_reversal")),
                    (UUID)r.get("warehouse_id"),(UUID)r.get("unit_id"),base,rate,quantity,measured?weight:null,measured?null:weight,weightSource,hash(s),Collections.unmodifiableMap(s));
            effects.computeIfAbsent((UUID)r.get("line_id"),ignored->new ArrayList<>()).add(effect);
        }
        var result=new ArrayList<Fact>();
        for(var r:rows){
            UUID id=(UUID)r.get("line_id");var events=List.copyOf(effects.getOrDefault(id,List.of()));var original=events.stream().filter(e->!e.reversal()).toList();
            var snapshot=new TreeMap<String,Object>();for(String key:List.of("line_id","document_id","bill_no","business_date","supplier_id","customer_id","goods_id","color_id","unit_id","unit_rate","reported_quantity","gift_quantity","quantity_semantics","document_remark","item_remark","original_goods_code","original_goods_name","original_specification"))snapshot.put(key,normal(r.get(key)));
            snapshot.put("originalEffects",original.stream().map(e->Map.of("id",e.movementId(),"fingerprint",e.identityFingerprint())).toList());
            String fingerprint=hash(snapshot);snapshot.put("currentStatus",r.get("status"));snapshot.put("labelBasis",r.get("original_goods_name")==null?"CURRENT_REFERENCE_LABEL":"ORIGINAL_DOCUMENT_SNAPSHOT");
            var issues=new ArrayList<String>();boolean approved=Boolean.TRUE.equals(r.get("approved_effect"))&&!original.isEmpty();
            if(!approved&&!original.isEmpty())issues.add("原业务单已变化，实际实物流仍保留，请核对原历史");
            if(original.isEmpty())issues.add("没有已确认可用入库/实际出库流水；收货待检及未确认库存不作为进仓");
            if(((Number)r.get("status")).intValue()==-1&&events.stream().noneMatch(Effect::reversal))issues.add("已反审单据缺少真实物理反向流水，不能用更新时间补日期");
            boolean missingReverse=((Number)r.get("status")).intValue()==-1&&events.stream().noneMatch(Effect::reversal);
            boolean changedIdentity=events.stream().anyMatch(effect->!Objects.equals(Objects.toString(effect.sourceSnapshot().get("goods_id"),null),Objects.toString(r.get("goods_id"),null))||!Objects.equals(Objects.toString(effect.sourceSnapshot().get("color_id"),null),Objects.toString(r.get("color_id"),null)));
            if(changedIdentity)issues.add("实际实物流货品/颜色与原行身份不一致，请核对原历史切片，不能换成当前货品后继续计算");
            boolean invalidQuantity=events.stream().anyMatch(e->e.baseQuantity()==null||e.baseQuantity().signum()<=0);
            if(invalidQuantity)issues.add("原实物流基本数量不完整");
            if(events.stream().anyMatch(e->e.unitId()==null))issues.add("原实物流单位未完整，PCS须明确实点依据，不按名称猜换算");
            BigDecimal quantity=null;if(derived&&decimal(r.get("unit_rate"))!=null&&decimal(r.get("unit_rate")).signum()>0){var totalBase=sumKnown(original.stream().map(Effect::baseQuantity).toList());if(totalBase!=null)quantity=BusinessPrecisionContext.divide(totalBase,decimal(r.get("unit_rate")),"finance.material.sourceQuantity","本次来源单位数量",30);}BigDecimal weight=sumKnown(original.stream().map(Effect::weightKg).toList());
            LocalDate first=original.stream().map(Effect::businessDate).min(LocalDate::compareTo).orElse(date(r.get("business_date")));
            LocalDate reversed=events.stream().filter(Effect::reversal).map(Effect::businessDate).min(LocalDate::compareTo).orElse(null);
            result.add(new Fact(new Key(kind,id),(UUID)r.get("document_id"),Objects.toString(r.get("bill_no"),""),first,reversed,
                (UUID)r.get("supplier_id"),(UUID)r.get("customer_id"),original.size()==1?original.getFirst().warehouseId():null,(UUID)r.get("goods_id"),(UUID)r.get("color_id"),
                Objects.toString(r.get("goods_code"),""),Objects.toString(r.get("goods_name"),""),Objects.toString(r.get("specification"),""),(UUID)r.get("unit_id"),Objects.toString(r.get("unit_name"),""),
                quantity,decimal(r.get("unit_rate")),weight,sumKnown(original.stream().map(Effect::estimatedWeightKg).toList()),
                "仅真实stock_movements的MEASURED/EXACT/SLICE为实称；AVERAGE/ESTIMATE或缺来源只作参考",approved,approved&&!missingReverse&&!invalidQuantity&&!changedIdentity&&r.get("goods_id")!=null,fingerprint,Collections.unmodifiableMap(snapshot),events,List.copyOf(issues)));
        }return List.copyOf(result);
    }
    static String source(Kind kind){
        String header,item,parent,supplier,customer,predicate;
        switch(kind){
            case PURCHASE_RECEIPT_LINE->{header="purchase_receipts";item="purchase_receipt_items";parent="receipt_id";supplier="document.supplier_id";customer="NULL::uuid";predicate="true";}
            case STOCK_OTHER_OUT_LINE->{header="stock_documents";item="stock_document_items";parent="doc_id";supplier="document.supplier_id";customer="document.client_id";predicate="document.doc_type='OTHER_OUT'";}
            case SALES_OTHER_SHIPMENT_LINE->{header="sales_other_shipments";item="sales_other_shipment_items";parent="shipment_id";supplier="NULL::uuid";customer="document.client_id";predicate="true";}
            case SUBCONTRACT_MATERIAL_ISSUE_LINE->{header="subcontract_material_issues";item="subcontract_material_issue_items";parent="issue_id";supplier="document.supplier_id";customer="NULL::uuid";predicate="true";}
            case SUBCONTRACT_MATERIAL_RETURN_LINE->{header="subcontract_material_returns";item="subcontract_material_return_items";parent="material_return_id";supplier="document.supplier_id";customer="NULL::uuid";predicate="true";}
            default->throw new IllegalArgumentException("kind");
        }
        return """
            SELECT item.id line_id,document.id document_id,document.bill_no,COALESCE(item.bill_date,document.bill_date) business_date,
              %s supplier_id,%s customer_id,item.goods_id,item.color_id,item.unit_id,item.unit_rate,unit.name unit_name,
              item.qty reported_quantity,NULLIF(to_jsonb(item)->>'gift_qty','')::numeric gift_quantity,to_jsonb(item)->>'quantity_semantics' quantity_semantics,
              NULLIF(to_jsonb(item)->>'goods_code_snapshot','') original_goods_code,NULLIF(to_jsonb(item)->>'goods_name_snapshot','') original_goods_name,
              COALESCE(NULLIF(to_jsonb(item)->>'goods_spec_snapshot',''),NULLIF(to_jsonb(item)->>'goods_model_snapshot','')) original_specification,
              COALESCE(NULLIF(to_jsonb(item)->>'goods_code_snapshot',''),goods.code) goods_code,
              COALESCE(NULLIF(to_jsonb(item)->>'goods_name_snapshot',''),goods.name) goods_name,
              COALESCE(NULLIF(to_jsonb(item)->>'goods_spec_snapshot',''),NULLIF(to_jsonb(item)->>'goods_model_snapshot',''),goods.spec,goods.model,'') specification,
              to_jsonb(document)->>'remark' document_remark,to_jsonb(item)->>'remark' item_remark,
              document.status,((document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted) OR document.status=-1) approved_effect
            FROM %s item JOIN %s document ON document.id=item.%s
            LEFT JOIN goods ON goods.id=item.goods_id LEFT JOIN units unit ON unit.id=item.unit_id WHERE %s
            """.formatted(supplier,customer,item,header,parent,predicate);
    }
    /** Internal position/prestock movements never pass this source relation. */
    static String movements(Kind kind){
        String relation,source,type,natural;
        if(kind==Kind.PURCHASE_RECEIPT_LINE){
            relation="""
                SELECT inspection.receipt_item_id line_id,m.*,stocked.id stock_in_item_id,inspection.quantity_tranche,stocked.pass_event_id
                FROM procurement_iqc_stock_in_batch_items stocked
                JOIN procurement_iqc_stock_in_batches batch ON batch.id=stocked.batch_id AND batch.receipt_type='PURCHASE'
                JOIN procurement_inspection_items inspection ON inspection.id=stocked.inspection_item_id AND inspection.receipt_type='PURCHASE' AND inspection.receipt_id=batch.receipt_id
                JOIN procurement_inspection_events pass ON pass.id=stocked.pass_event_id AND pass.inspection_item_id=inspection.id AND pass.action='PASS'
                JOIN stock_movements m ON m.source_doc_type='PURCHASE_RECEIPT' AND m.source_doc_id=batch.receipt_id AND m.source_item_id=stocked.id AND m.movement_type=1
                  AND m.goods_id=stocked.goods_id AND m.color_id IS NOT DISTINCT FROM stocked.color_id AND m.warehouse_id=stocked.warehouse_id
                  AND ((m.direction=1 AND m.id=stocked.stock_movement_id) OR m.direction=-1)
                UNION ALL
                SELECT item.id line_id,m.*,NULL::uuid stock_in_item_id,'LEGACY'::text quantity_tranche,NULL::uuid pass_event_id
                FROM purchase_receipt_items item JOIN stock_movements m ON m.source_doc_type='PURCHASE_RECEIPT' AND m.source_doc_id=item.receipt_id AND m.source_item_id=item.id AND m.movement_type=1
                WHERE NOT EXISTS(SELECT 1 FROM procurement_inspection_items inspection WHERE inspection.receipt_type='PURCHASE' AND inspection.receipt_item_id=item.id)
                """;natural="1";
        }else{
            source=switch(kind){case STOCK_OTHER_OUT_LINE->"STOCK_DOC";case SALES_OTHER_SHIPMENT_LINE->"SALES_OTHER_SHIPMENT";case SUBCONTRACT_MATERIAL_ISSUE_LINE->"SUBCONTRACT_MATERIAL_ISSUE";case SUBCONTRACT_MATERIAL_RETURN_LINE->"SUBCONTRACT_MATERIAL_RETURN";default->throw new IllegalArgumentException("kind");};
            type=switch(kind){case STOCK_OTHER_OUT_LINE->"12";case SALES_OTHER_SHIPMENT_LINE->"20";case SUBCONTRACT_MATERIAL_ISSUE_LINE->"15";case SUBCONTRACT_MATERIAL_RETURN_LINE->"16";default->throw new IllegalArgumentException("kind");};natural="-1";
            relation="SELECT m.source_item_id line_id,m.*,NULL::uuid stock_in_item_id,NULL::text quantity_tranche,NULL::uuid pass_event_id FROM stock_movements m WHERE m.source_doc_type='"+source+"' AND m.movement_type="+type;
        }
        String originalDirection=kind==Kind.PURCHASE_RECEIPT_LINE||kind==Kind.SUBCONTRACT_MATERIAL_RETURN_LINE?"1":"-1";
        return "SELECT relation.*,relation.id movement_id,business.business_date source_business_date,(transaction_date AT TIME ZONE 'Asia/Shanghai')::date confirmation_date,"+
            "CASE WHEN direction<>("+originalDirection+") THEN (transaction_date AT TIME ZONE 'Asia/Shanghai')::date ELSE business.business_date END business_date,"+
            "direction*("+natural+") event_sign,(direction<>("+originalDirection+")) is_reversal,qty base_quantity FROM ("+relation+") relation JOIN ("+source(kind)+") business ON business.line_id=relation.line_id";

    }
    private String hash(Object source){try{return ImmutableDocumentStore.digest(json.writeValueAsBytes(source));}catch(Exception e){throw new IllegalStateException("来源摘要不能生成",e);}}
    private static String slots(int n){return String.join(",",Collections.nCopies(n,"?"));}
    private static BigDecimal sumKnown(List<BigDecimal> values){return values.isEmpty()||values.stream().anyMatch(Objects::isNull)?null:values.stream().reduce(BigDecimal.ZERO,BigDecimal::add);}
    private static BigDecimal decimal(Object v){return v==null?null:new BigDecimal(v.toString());}
    private static LocalDate date(Object v){return v==null?null:v instanceof java.sql.Date d?d.toLocalDate():v instanceof LocalDate d?d:LocalDate.parse(v.toString());}
    private static Object normal(Object v){return v==null?null:v instanceof BigDecimal n?n.toPlainString():v instanceof java.sql.Date d?d.toLocalDate().toString():v instanceof UUID u?u.toString():v instanceof java.sql.Timestamp t?t.toInstant().toString():v instanceof java.time.OffsetDateTime t?t.toInstant().toString():v;}
    private static ApiException invalid(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);}
}
