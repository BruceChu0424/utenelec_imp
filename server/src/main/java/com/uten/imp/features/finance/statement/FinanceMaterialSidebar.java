package com.uten.imp.features.finance.statement;
import java.util.*;
import java.time.LocalDate;
import com.uten.imp.common.util.FinancialExactAmount;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementService.*;
/** The original four hidden slots are independent reference data. A reference
 * price or name never creates a material group, quantity, fee or GL entry. */
final class FinanceMaterialSidebar {
 private final FinanceMaterialStatementService s;
 FinanceMaterialSidebar(FinanceMaterialStatementService s){this.s=s;}
 static Map<String,Object> family(Map<String,Object> context){var result=new TreeMap<String,Object>();for(String key:List.of("auxiliary_id","account_code","accounting_currency_id","amount_basis","original_currency_id")){result.put(key,Objects.toString(context.get(key),null));}return result;}
 String key(Map<String,Object> context,SidebarLine line){return "side:"+s.hash(family(context))+":"+line.slot()+":"+line.dateFrom()+":"+line.dateTo();}
 Map<String,Object> validate(Map<String,Object> context,SidebarLine line){
  requireContext((UUID)context.get("id"),line.contextId());reference(line.sourceReference());if(line.slot()<1||line.slot()>4||line.dateFrom()==null||line.dateTo()==null||line.dateFrom().isAfter(line.dateTo()))throw invalid("原旁算只有四个位置，请明确适用起止日期和1至4位置");
  if(line.productNameCaption()==null||line.productNameCaption().isBlank()||line.productNameCaption().length()>240||!"PCS".equals(line.unitCaption()))throw invalid("请按原旁算维护名称和PCS单位；不按同名自动对应商品");
  UUID paperCurrency;if("ORIGINAL".equals(context.get("amount_basis")))paperCurrency=(UUID)context.get("original_currency_id");else{var base=s.db.queryForList("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);if(base.size()!=1)throw invalid("本位币单位尚未明确");paperCurrency=base.getFirst();}
  if(line.referencePrice()!=null){if(FinancialExactAmount.unitPrice(line.referencePrice(),"本型号有效期间参考报价").signum()<0||!Objects.equals(line.referenceCurrencyId(),paperCurrency))throw invalid("参考报价须为非负原值且实际币别与纸面相同，不按币别属性或汇率反推");}
  var proof=new LinkedHashMap<String,Object>();proof.put("family",family(context));
  if(line.materialContextId()!=null){var bound=s.context(line.materialContextId(),false);if(!Boolean.TRUE.equals(bound.get("active"))||!family(context).equals(family(bound)))throw invalid("旁算只可明确引用同财务辅助、科目、会计币别和实际纸面币别的真实材料分组");s.approvedContext(line.materialContextId());proof.put("materialContextId",line.materialContextId());}
  return proof;
 }
 List<Map<String,Object>> current(Map<String,Object> context){
  var args=new ArrayList<Object>(List.of(context.get("auxiliary_id"),context.get("account_code"),context.get("accounting_currency_id"),context.get("amount_basis")));args.add(context.get("original_currency_id"));
  return s.db.queryForList("SELECT e.* FROM finance_material_evidence e JOIN finance_material_contexts c ON c.id=e.context_id WHERE e.kind='SIDEBAR' AND e.current_approved AND c.auxiliary_id=? AND c.account_code=? AND c.accounting_currency_id=? AND c.amount_basis=? AND c.original_currency_id IS NOT DISTINCT FROM CAST(? AS uuid) ORDER BY e.id",args.toArray()).stream().map(s::decodeEvidence).toList();
 }
 Map<Integer,Map<String,Object>> applicable(Map<String,Object> context,LocalDate from,LocalDate to,FinanceMaterialStatementService.ReadScope scope){
  var slots=new LinkedHashMap<Integer,Map<String,Object>>();for(var evidence:current(context)){var line=s.input(evidence,SidebarLine.class);if(!line.active()||line.dateFrom().isAfter(from)||line.dateTo().isBefore(to))continue;boolean valid;try{valid=s.validate(evidence,false,scope).fingerprint().equals(evidence.get("source_fingerprint"));}catch(com.uten.imp.common.web.ApiException failure){valid=false;}
   var value=new LinkedHashMap<>(evidence);value.put("__valid",valid);if(slots.putIfAbsent(line.slot(),value)!=null)throw invalid("同一原旁算位置有重叠有效资料，请先核对原记录，不能随意取第一条");}
  return slots;
 }
 void claim(Map<String,Object> evidence,SidebarLine line){
  if(!line.active())return;var context=s.context((UUID)evidence.get("context_id"),false);s.lock("sidebar:"+s.hash(family(context))+":"+line.slot());
  for(var previous:current(context)){if(Objects.equals(previous.get("id"),evidence.get("expected_approved_id")))continue;var other=s.input(previous,SidebarLine.class);if(other.active()&&other.slot()==line.slot()&&!other.dateFrom().isAfter(line.dateTo())&&!other.dateTo().isBefore(line.dateFrom()))throw conflict("同一旁算位置的适用期间与已审资料重叠，请从原版本新建更正或先停用");}
 }
}
