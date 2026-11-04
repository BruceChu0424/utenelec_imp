package com.uten.imp.features.finance.statement;
import com.uten.imp.common.util.FinancialExactAmount;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementService.*;
/** Explicit actual credit shares explain an adjusted amount. No rate, tax, AR or cash is invented. */
final class FinanceMaterialProcessingAdjustment {
 private final FinanceMaterialStatementService s;
 FinanceMaterialProcessingAdjustment(FinanceMaterialStatementService s){this.s=s;}
 Map<String,Object> credit(GlAllocationKey key,Map<String,Object> receivable,AdjustmentPurpose purpose){
  if(key==null||key.entryId()==null||key.allocationNo()<0||purpose==null)throw invalid("请明确真实附加款贷方分录、原allocation序号（无辅助为0）和性质");
  var rows=s.db.queryForList("SELECT e.id AS entry_id,e.style_id,e.direction,e.amount AS amount_local,e.entry_date,e.voucher_id,v.voucher_no,e.line_no FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE e.id=? AND NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND v.reversal_of_voucher_id IS NULL AND e.direction=-1 AND NOT fn_finance_entry_is_pnl_closing(e.id)",key.entryId());
  if(rows.size()!=1)throw invalid("附加款须为真实已记账原贷方，不用回款、反向或损益结转冒充");var row=new TreeMap<String,Object>(rows.getFirst());
  if(!Objects.equals(row.get("voucher_id"),receivable.get("voucher_id")))throw invalid("附加款须有本张应收原凭证的真实对方分录关系，不能按同月同名拼接其他凭证");
  String binding=purpose==AdjustmentPurpose.VAT?"BS_36":"PL_22";
  if(s.db.queryForObject("SELECT count(*) FROM finance_report_line_bindings b JOIN payment_styles ancestor ON ancestor.id=b.style_id JOIN payment_styles actual ON actual.id=? WHERE b.binding_kind='STYLE' AND b.line_key=? AND (actual.id=ancestor.id OR (ancestor.path IS NOT NULL AND ancestor.path<>'' AND actual.path LIKE ancestor.path||'/%'))",Integer.class,row.get("style_id"),binding)==0)throw invalid(purpose==AdjustmentPurpose.VAT?"VAT须为已明确应交税费科目的真实贷方；客户税点不能套VAT":"收客户税点须为财务明确营业外收入科目的真实贷方");
  row.put("allocation_no",key.allocationNo());row.put("purpose",purpose);row.put("amount_original",null);row.put("original_currency_id",null);
  var allocations=s.db.queryForList("SELECT * FROM finance_gl_entry_allocations WHERE entry_id=? ORDER BY allocation_no",key.entryId());
  if(key.allocationNo()==0){if(!allocations.isEmpty())throw invalid("该贷方有真实辅助分配，请选明确allocation，不能再认领整笔");}
  else{var a=allocations.stream().filter(v->((Number)v.get("allocation_no")).intValue()==key.allocationNo()).findFirst().orElseThrow(()->invalid("原贷方辅助分配不存在"));
   for(String field:List.of("auxiliary_id","currency_id","party_id_snapshot","auxiliary_role"))if(!Objects.equals(a.get(field),receivable.get(field)))throw invalid("附加款原辅助/对象/会计币别与本张应收不一致");
   for(String field:List.of("amount_local","amount_original","original_currency_id","currency_id","auxiliary_id","party_id_snapshot","auxiliary_role"))row.put(field,a.get(field));
  }
  if(key.allocationNo()==0&&receivable.get("original_currency_id")!=null&&s.db.queryForObject("SELECT count(*) FROM currencies WHERE id=? AND is_base_currency AND NOT is_deleted",Integer.class,receivable.get("original_currency_id"))==1){row.put("amount_original",row.get("amount_local"));row.put("original_currency_id",receivable.get("original_currency_id"));row.put("originalBasis","BASE_BOOK_CURRENCY_SAME_VALUE");}
  return row;
 }
 List<Map<String,Object>> validate(FeeAssignment value,Map<String,Object> receivable,boolean posting,Map<String,Object> evidence){
  var sources=value.adjustmentSources()==null?List.<AdjustmentSource>of():value.adjustmentSources();if(sources.size()>2000)throw invalid("附加款来源超过2000条，请分原应收凭证核对");
  var defined=new LinkedHashMap<GlAllocationKey,AdjustmentSource>();var result=new ArrayList<Map<String,Object>>();
  for(var source:sources){if(source==null||source.source()==null||defined.put(source.source(),source)!=null)throw invalid("同一真实附加款来源不能重复定义");reference(source.sourceReference());var fact=credit(source.source(),receivable,source.purpose());if(posting&&!Objects.equals(source.expectedSourceFingerprint(),s.hash(fact)))throw conflict("附加款来源已变化，请重新读取原值");
   var local=new ArrayList<BigDecimal>();var original=new ArrayList<BigDecimal>();
   for(var part:value.processingParts()){
   var included=new ArrayList<BigDecimal>();var includedOriginal=new ArrayList<BigDecimal>();BigDecimal taken=BigDecimal.ZERO,takenOriginal=BigDecimal.ZERO;
   for(var a:part.adjustments()==null?List.<AdjustmentPart>of():part.adjustments())if(a.includedInProcessing()){included.add(a.amountLocal());taken=taken.add(a.amountLocal());if(a.amountOriginal()!=null){includedOriginal.add(a.amountOriginal());takenOriginal=takenOriginal.add(a.amountOriginal());}}
   included.add(part.amountLocal().subtract(taken));conserve(part.amountLocal(),included);if(part.amountOriginal()!=null){includedOriginal.add(part.amountOriginal().subtract(takenOriginal));conserve(part.amountOriginal(),includedOriginal);}
  }
  for(var part:value.processingParts())for(var a:part.adjustments()==null?List.<AdjustmentPart>of():part.adjustments())if(source.source().equals(a.source())){
    if(!part.adjustmentReviewed())throw invalid("有附加份额时须明确本加工份额的调整口径已核对");local.add(FinancialExactAmount.book(a.amountLocal(),"附加本币份额"));
    if(fact.get("amount_original")==null){if(a.amountOriginal()!=null)throw invalid("附加源没有真实原币，不能按本币或汇率造原币");}else{if(!Objects.equals(fact.get("original_currency_id"),receivable.get("original_currency_id")))throw invalid("附加款实际原币单位与应收不一致");original.add(FinancialExactAmount.require(a.amountOriginal(),"附加原币份额"));}
   }
   local.add(FinancialExactAmount.book(source.unrelatedLocal(),"明确非本表附加款本币余项"));conserve(decimal(fact.get("amount_local")),local);
   if(fact.get("amount_original")!=null){original.add(FinancialExactAmount.require(source.unrelatedOriginal(),"明确非本表附加款原币余项"));conserve(decimal(fact.get("amount_original")),original);}else if(source.unrelatedOriginal()!=null)throw invalid("缺原币证据的附加余项不能假填0");
   result.add(fact);
  }
  for(var part:value.processingParts())for(var a:part.adjustments()==null?List.<AdjustmentPart>of():part.adjustments())if(a==null||!defined.containsKey(a.source()))throw invalid("加工附加份额缺少完整原贷方来源定义");
  return result;
 }
 boolean effectProven(AdjustmentSource source,Map<String,Object> receivable,UUID eventVoucher,int sign){
  var fact=credit(source.source(),receivable,source.purpose());
  var actual=s.db.queryForList("SELECT fn_finance_credit_occurrence(e.id) occurrence FROM gl_entries e WHERE e.voucher_id=? AND e.style_id=? AND e.line_no=? AND NOT e.is_deleted",eventVoucher,fact.get("style_id"),fact.get("line_no"));
  return actual.size()==1&&decimal(actual.getFirst().get("occurrence"))!=null&&decimal(actual.getFirst().get("occurrence")).compareTo(decimal(fact.get("amount_local")).multiply(BigDecimal.valueOf(sign)))==0;
 }
 void claim(Map<String,Object> evidence,FeeAssignment value){
  for(var source:(value.adjustmentSources()==null?List.<AdjustmentSource>of():value.adjustmentSources()).stream().sorted(Comparator.comparing(x->x.source().entryId().toString()+":"+x.source().allocationNo())).toList()){
   s.lock("adjustment-credit:"+source.source().entryId()+":"+source.source().allocationNo());
   int others=s.db.queryForObject("SELECT count(*) FROM finance_material_evidence e CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e.source_snapshot->'effectiveInput'->'adjustmentSources',e.input->'adjustmentSources','[]'::jsonb)) credit WHERE e.kind='FEE' AND e.current_approved AND e.resource_key<>? AND credit->'source'->>'entryId'=? AND (credit->'source'->>'allocationNo')::integer=?",Integer.class,value.source().entryId()+":"+value.source().allocationNo(),source.source().entryId().toString(),source.source().allocationNo());
   if(others>0)throw conflict("同一真实附加款贷方已归属另一原应收，请在原完整分配内更正，不能重复认领");
  }
 }
}
