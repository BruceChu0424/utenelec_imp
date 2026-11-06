package com.uten.imp.features.finance.cost;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.YearMonth;
import java.util.*;
import java.util.function.LongSupplier;
import static com.uten.imp.features.finance.cost.FinanceCostInputContracts.*;

@Service @RequiredArgsConstructor
public class FinanceCostInputService {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void write(){read();CurrentAuthorityGuard.requireAll("payment_style:edit");}

    @Transactional(readOnly=true)
    public Map<String,Object> sales(String period,UUID client){
        read();validPeriod(period);requireClient(client);
        return exact(one("SELECT period,client_id AS \"clientId\",channel,tax_rate AS \"taxRate\",freight_local AS \"freightLocal\",exchange_rate AS \"exchangeRate\",confirmed,source_reference AS \"sourceReference\",row_version AS version,client_name_snapshot AS \"clientName\",seller_name_snapshot AS \"sellerName\",region_snapshot AS region,director_snapshot AS director FROM finance_sales_cost_inputs WHERE period=? AND client_id=?",period,client));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> plastic(UUID id){
        read();var source=plasticSource(id);var result=new LinkedHashMap<String,Object>(source);
        result.putAll(one("SELECT source_close_id AS \"sourceCloseId\",reject_return_qty AS \"rejectReturnQty\",reject_issue_qty AS \"rejectIssueQty\",reason,confirmed,row_version AS version,weight_kg_per_unit AS \"weightKgPerUnit\",material_name AS \"materialName\",template_row AS \"templateRow\",source_reference AS \"sourceReference\" FROM finance_plastic_template_inputs WHERE period_line_id=?",id));return exact(result);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> order(UUID id){
        read();if(db.queryForObject("SELECT count(*) FROM workshop_material_requisitions WHERE id=?",Integer.class,id)==0)throw missing();
        return one("SELECT order_no AS \"orderNo\",source_reference AS \"sourceReference\",confirmed,row_version AS version FROM finance_material_order_references WHERE requisition_id=?",id);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> copper(UUID id){
        read();copperSource(id);var result=new LinkedHashMap<String,Object>(one("SELECT section_key AS \"sectionKey\",source_reference AS \"sourceReference\",confirmed,row_version AS version FROM finance_copper_template_inputs WHERE source_line_id=?",id));
        var sections=com.uten.imp.features.finance.gl.FinanceTemplateContract.template("copperDetail").required("bodySections");
        result.put("sectionChoices",Map.of("PICKLING_INSERT",sections.required("PICKLING_INSERT").asText(),"COPPER_PICKLING",sections.required("COPPER_PICKLING").asText()));return result;
    }
    @Transactional(readOnly=true)
    public Map<String,Object> operation(UUID id){
        read();var rows=db.queryForList("SELECT result::text FROM finance_cost_input_operations WHERE request_id=? AND actor_id=?",String.class,id,current.requireId());
        if(rows.isEmpty())throw missing();return decode(rows.getFirst());
    }

    @Transactional
    public Saved saveSales(Sales input){
        write();if(input==null)throw invalid("请填写销售成本原表资料");validPeriod(input.period());
        if(input.channel()!=null&&!Set.of("OEM","FOREIGN","DOMESTIC").contains(input.channel()))throw invalid("销售费用类型不正确");
        com.uten.imp.common.util.FinancialExactAmount.optional(input.freightLocal(),"运费");com.uten.imp.common.util.FinancialExactAmount.optional(input.exchangeRate(),"汇率");
        if(input.exchangeRate()!=null&&input.exchangeRate().signum()<=0)throw invalid("汇率必须大于0");
        if(input.taxRate()!=null&&input.taxRate().compareTo(BigDecimal.ZERO)!=0&&input.taxRate().compareTo(new BigDecimal("0.10"))!=0)throw invalid("原表税费适用比例只能明确选择0或10%");
        if(input.confirmed()&&(input.channel()==null||input.taxRate()==null||input.sourceReference()==null||input.sourceReference().isBlank()))throw invalid("确认前请填写销售费用类型、税费适用比例和核对依据");
        if(input.confirmed()&&(input.clientName()==null||input.clientName().isBlank()||input.sellerName()==null||input.region()==null||input.director()==null))throw invalid("请核对原表客户名称、业务员、区域和总监（确无归属可留空文本）");
        return execute(input.requestId(),"SALES",input,"sales:"+input.period()+":"+input.clientId(),()->{
            requireClient(input.clientId());
        if(input.exchangeRate()!=null) {
            var period=YearMonth.parse(input.period());
            var rates=db.queryForMap("WITH "+FinanceSalesRevenueSql.ctes().replace(":from","?").replace(":to","?")+"""
                SELECT count(DISTINCT currency_id) AS currencies,count(DISTINCT exchange_rate) AS rates,
                    max(exchange_rate) AS known_rate FROM sales_revenue_events WHERE client_id=?
                """,period.atDay(1),period.atEndOfMonth(),input.clientId());
            if(((Number)rates.get("currencies")).intValue()>1||((Number)rates.get("rates")).intValue()>1)throw invalid("该客户本月有多个币种或记账汇率，不能用一个汇率代表整组");
            if(rates.get("known_rate") instanceof BigDecimal known&&known.compareTo(input.exchangeRate())!=0)throw invalid("所填汇率与本月唯一已知记账汇率不一致，请核对原凭证");
        }

            long version=version("SELECT row_version FROM finance_sales_cost_inputs WHERE period=? AND client_id=? FOR UPDATE",input.period(),input.clientId());expected(version,input.expectedVersion());
            long next=version+1;
            db.update("""
                INSERT INTO finance_sales_cost_inputs(period,client_id,channel,freight_local,exchange_rate,confirmed,source_reference,row_version,updated_by,tax_rate,
                    client_name_snapshot,seller_name_snapshot,region_snapshot,director_snapshot)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(period,client_id) DO UPDATE SET channel=excluded.channel,freight_local=excluded.freight_local,
                exchange_rate=excluded.exchange_rate,confirmed=excluded.confirmed,source_reference=excluded.source_reference,
                row_version=excluded.row_version,updated_at=now(),updated_by=excluded.updated_by,tax_rate=excluded.tax_rate,
                client_name_snapshot=excluded.client_name_snapshot,seller_name_snapshot=excluded.seller_name_snapshot,
                region_snapshot=excluded.region_snapshot,director_snapshot=excluded.director_snapshot
                """,input.period(),input.clientId(),input.channel(),input.freightLocal(),input.exchangeRate(),input.confirmed(),input.sourceReference(),next,current.requireId(),input.taxRate(),
                    input.clientName(),input.sellerName(),input.region(),input.director());return next;
        });
    }
    @Transactional
    public Saved savePlastic(Plastic input){
        write();if(input==null||input.periodLineId()==null)throw invalid("请选择已结算塑料期间行");
        validateQuantity(input.rejectReturnQty());validateQuantity(input.rejectIssueQty());
        if(input.weightKgPerUnit()!=null)com.uten.imp.common.util.FinancialExactAmount.rate(input.weightKgPerUnit(),"单位换算");
        if(input.weightKgPerUnit()!=null&&input.weightKgPerUnit().signum()<=0)throw invalid("每原单位千克数必须大于0");
        if(input.confirmed()&&(input.weightKgPerUnit()==null||input.sourceReference()==null||input.sourceReference().isBlank()))throw invalid("请核对原单位到KG的换算及来源依据后确认");
        return execute(input.requestId(),"PLASTIC",input,"plastic:"+input.periodLineId(),()->{
            var source=plasticSource(input.periodLineId());
            BigDecimal returns=(BigDecimal)source.get("returnQty"),issues=(BigDecimal)source.get("otherIssueQty");
            if(input.rejectReturnQty().compareTo(returns)>0||input.rejectIssueQty().compareTo(issues)>0)throw invalid("安装挑选不良分类不能超过相应已结算退料/其它耗用数量");
            if(input.confirmed()&&((BigDecimal)source.get("diff")).signum()!=0&&(input.reason()==null||input.reason().isBlank()))throw invalid("存在差异时请填写原因后确认");
            long previous=version("SELECT row_version FROM finance_plastic_template_inputs WHERE period_line_id=? FOR UPDATE",input.periodLineId());expected(previous,input.expectedVersion());long next=previous+1;
            db.update("""
                INSERT INTO finance_plastic_template_inputs(period_line_id,source_close_id,reject_return_qty,reject_issue_qty,reason,confirmed,row_version,updated_by,
                    source_unit_id,weight_kg_per_unit,material_name,template_row,source_reference)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(period_line_id) DO UPDATE SET source_close_id=excluded.source_close_id,
                reject_return_qty=excluded.reject_return_qty,reject_issue_qty=excluded.reject_issue_qty,reason=excluded.reason,
                confirmed=excluded.confirmed,row_version=excluded.row_version,updated_at=now(),updated_by=excluded.updated_by,
                source_unit_id=excluded.source_unit_id,weight_kg_per_unit=excluded.weight_kg_per_unit,material_name=excluded.material_name,
                template_row=excluded.template_row,source_reference=excluded.source_reference
                """,input.periodLineId(),source.get("closeId"),input.rejectReturnQty(),input.rejectIssueQty(),input.reason(),input.confirmed(),next,current.requireId(),
                    source.get("unitId"),input.weightKgPerUnit(),input.materialName(),input.templateRow(),input.sourceReference());return next;
        });
    }
    @Transactional
    public Saved saveOrder(Order input){
        write();if(input==null||input.requisitionId()==null||input.orderNo()==null||input.orderNo().isBlank()||input.sourceReference()==null||input.sourceReference().isBlank())throw invalid("请填写原表订单号和来源依据");
        return execute(input.requestId(),"ORDER",input,"order:"+input.requisitionId(),()->{
            if(db.queryForObject("SELECT count(*) FROM workshop_material_requisitions WHERE id=?",Integer.class,input.requisitionId())==0)throw missing();
            long previous=version("SELECT row_version FROM finance_material_order_references WHERE requisition_id=? FOR UPDATE",input.requisitionId());expected(previous,input.expectedVersion());long next=previous+1;
            db.update("""
                INSERT INTO finance_material_order_references(requisition_id,order_no,source_reference,confirmed,row_version,updated_by)
                VALUES(?,?,?,?,?,?) ON CONFLICT(requisition_id) DO UPDATE SET order_no=excluded.order_no,source_reference=excluded.source_reference,
                confirmed=excluded.confirmed,row_version=excluded.row_version,updated_at=now(),updated_by=excluded.updated_by
                """,input.requisitionId(),input.orderNo().strip(),input.sourceReference(),input.confirmed(),next,current.requireId());return next;
        });
    }
    @Transactional
    public Saved saveCopper(Copper input){
        write();if(input==null||input.sourceLineId()==null||input.sectionKey()==null||!Set.of("PICKLING_INSERT","COPPER_PICKLING").contains(input.sectionKey())||input.sourceReference()==null||input.sourceReference().isBlank())throw invalid("请按原表明确分类并填写核对依据");
        return execute(input.requestId(),"COPPER",input,"copper:"+input.sourceLineId(),()->{
            var source=copperSource(input.sourceLineId());long old=version("SELECT row_version FROM finance_copper_template_inputs WHERE source_line_id=? FOR UPDATE",input.sourceLineId());expected(old,input.expectedVersion());long next=old+1;
            db.update("INSERT INTO finance_copper_template_inputs(source_line_id,supplier_id,goods_id,section_key,source_reference,confirmed,row_version,updated_by) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(source_line_id) DO UPDATE SET supplier_id=excluded.supplier_id,goods_id=excluded.goods_id,section_key=excluded.section_key,source_reference=excluded.source_reference,confirmed=excluded.confirmed,row_version=excluded.row_version,updated_at=now(),updated_by=excluded.updated_by",input.sourceLineId(),source.get("supplier_id"),source.get("goods_id"),input.sectionKey(),input.sourceReference(),input.confirmed(),next,current.requireId());return next;
        });
    }
    private Map<String,Object> copperSource(UUID id){var rows=db.queryForList("SELECT d.supplier_id,i.goods_id FROM subcontract_receipt_items i JOIN subcontract_receipts d ON d.id=i.receipt_id WHERE i.id=? AND NOT i.is_deleted AND NOT d.is_deleted AND d.status=1",id);if(rows.size()!=1||rows.getFirst().get("goods_id")==null)throw invalid("原委外入库行已变化或未审核，请刷新核对");return rows.getFirst();}
    private Saved execute(UUID request,String kind,Object payload,String scope,LongSupplier action){
        if(request==null)throw invalid("缺少原请求编号，请重开原表资料");tx.bind();
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,996))",rs->{},"finance-cost-request:"+request);
        String fingerprint=ImmutableDocumentStore.digest(encode(payload).getBytes(StandardCharsets.UTF_8));
        var old=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_cost_input_operations WHERE request_id=?",request);
        if(!old.isEmpty()) {
            var saved=old.getFirst();if(!current.requireId().equals(saved.get("actor_id"))||!fingerprint.equals(saved.get("fingerprint")))throw conflict("原请求编号已用于其他内容，请先核对原操作结果");
            Map<String,Object> result=decode((String)saved.get("result"));return new Saved(request,kind,((Number)result.get("version")).longValue());
        }
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,996))",rs->{},scope);
        Saved saved=new Saved(request,kind,action.getAsLong());
        db.update("INSERT INTO finance_cost_input_operations(request_id,actor_id,kind,fingerprint,result) VALUES(?,?,?,?,?::jsonb)",request,current.requireId(),kind,fingerprint,encode(saved));return saved;
    }
    private Map<String,Object> plasticSource(UUID id){
        var rows=db.queryForList("""
            SELECT report.period_line_id AS "periodLineId",report.close_id AS "closeId",report.unit_id AS "unitId",unit.name AS "sourceUnitName",return_qty AS "returnQty",other_issue_qty AS "otherIssueQty",
              closing_qty-(opening_qty+transfer_in_qty-return_qty-other_issue_qty-
                (CASE cost_basis WHEN 'OWN' THEN COALESCE(theory_qty,0) WHEN 'SHARED' THEN consumed_qty ELSE 0 END)) AS diff
            FROM v_workshop_material_period_report report LEFT JOIN units unit ON unit.id=report.unit_id WHERE report.period_line_id=? AND close_id IS NOT NULL
            """,id);if(rows.size()!=1)throw invalid("期间尚未结算或原行已失效，请刷新核对");return rows.getFirst();
    }
    private Map<String,Object> one(String sql,Object...args){var rows=db.queryForList(sql,args);return rows.isEmpty()?Map.of("version",-1):rows.getFirst();}
    private static Map<String,Object> exact(Map<String,Object> values){var result=new LinkedHashMap<String,Object>();values.forEach((k,v)->result.put(k,v instanceof BigDecimal amount?amount.toPlainString():v));return result;}
    private long version(String sql,Object...args){var rows=db.queryForList(sql,Long.class,args);return rows.isEmpty()?-1:rows.getFirst();}
    private void requireClient(UUID id){if(id==null||db.queryForObject("SELECT count(*) FROM clients WHERE id=? AND NOT is_deleted",Integer.class,id)!=1)throw invalid("客户不存在或已删除");}
    private static void validPeriod(String period){try{if(period==null||!period.matches("[0-9]{4}-(0[1-9]|1[0-2])"))throw new IllegalArgumentException();YearMonth.parse(period);}catch(RuntimeException e){throw invalid("月份格式应为YYYY-MM");}}
    private static void expected(long actual,long expected){if(actual!=expected)throw conflict("原表资料已变化，请刷新核对后重试");}
    private static void validateQuantity(BigDecimal value){
        if(value==null||value.signum()<0)throw invalid("数量须为非负数");
        com.uten.imp.common.util.FinancialExactAmount.quantity(value,"原表分类数量");
    }
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalStateException("原表资料无法编码",e);}}
    @SuppressWarnings("unchecked") private Map<String,Object> decode(String value){try{return json.readValue(value,Map.class);}catch(Exception e){throw new IllegalStateException("原表资料回执无效",e);}}
    private static ApiException invalid(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);}
    private static ApiException conflict(String m){return new ApiException(ErrorCode.CONFLICT,m);}
    private static ApiException missing(){return new ApiException(ErrorCode.NOT_FOUND,"原表资料不存在或不属于当前账号");}
}
