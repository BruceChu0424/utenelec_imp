package com.uten.imp.features.finance.payroll;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.application.port.FinancePayrollPaymentPort.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;

/** Source amounts are immutable; this plan only assigns their accounting meaning. */
@Component @RequiredArgsConstructor
final class FinancePayrollAccountingPlan {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final FinancialChartCurrencyReadPort currencies;
    private final FinancialAuxiliaryValidationPort auxiliary;
    private final FinanceGlSettlementCapacityPort capacity;
    record Style(UUID id,String code,String category,String classification,UUID currencyId,boolean costAllowed,long version) { }
    record Cost(Slip slip,Style style) { }
    record Part(UUID itemId,UUID allocationId,Slip slip,DeductionPurpose purpose,Style style,BigDecimal amount,
                FinancialAuxiliaryValidationPort.Ref auxiliary,OpenItemReference original,String sourceReference) {
        boolean reduction(){return purpose==DeductionPurpose.EXPENSE_REDUCTION||purpose==DeductionPurpose.MANUFACTURING_COST_REDUCTION;}
    }
    record Liability(Style style,FinancialAuxiliaryValidationPort.Ref auxiliary,ExistingLiabilityLine source,BigDecimal amount) { }
    record Plan(Source source,Instruction instruction,LocalDate date,Style wage,List<Cost> costs,List<Part> parts,List<Liability> liabilities,
                List<Issue> issues,String fingerprint,Map<String,Object> priorAccrual,List<Object> proofs) {
        boolean reused(){return priorAccrual!=null;}
        boolean nativeAccrual(){return instruction!=null&&instruction.mode()==AccrualMode.NATIVE_APPROVED_PAYROLL;}
    }
    Plan build(UUID applicationId,Source source,Instruction instruction){
        var issues=new ArrayList<Issue>();var costs=new ArrayList<Cost>();var parts=new ArrayList<Part>();var liabilities=new ArrayList<Liability>();var proofs=new ArrayList<Object>();
        var styles=new LinkedHashMap<UUID,Style>();LocalDate date=null;Style wage=null;
        var prior=db.queryForList("SELECT * FROM finance_payroll_accruals WHERE batch_id=?",source.batchId());Map<String,Object> accrued=prior.isEmpty()?null:prior.getFirst();
        if(instruction==null||instruction.mode()==null)return new Plan(source,instruction,null,null,List.of(),List.of(),List.of(),List.of(new Issue("mode",null,"请明确本批工资是新计提还是认领已确认原工资负债")),hash(List.of(source.fingerprint(),"NO_PLAN")),accrued,List.of());
        try{reference(instruction.sourceReference());date=instruction.accountingAsOf();if(date==null||date.isAfter(BusinessTime.today())||date.isBefore(YearMonth.parse(source.period()).atDay(1)))throw invalid("请按原工资期间选择已到的会计核对日期");}catch(ApiException e){issues.add(issue("accountingAsOf",null,e));}
        if(source.grossIncome().signum()>0)try{
            wage=style(instruction.wagePayableStyleId(),source,styles);
            if(!Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_payroll_wage_style_allowed(?)",Boolean.class,wage.id())))throw invalid("应付工资须为明确对应职工薪酬的负债末级，不使用供应商应付或税款代替");
            auxiliary.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(wage.code(),null,wage.currencyId())));
        }catch(ApiException e){issues.add(issue("wagePayableStyleId",null,e));}
        boolean needsDeductions=instruction.mode()==AccrualMode.NATIVE_APPROVED_PAYROLL||instruction.existingLiabilityBasis()==ExistingLiabilityBasis.GROSS_BEFORE_DEDUCTIONS;
        Map<UUID,Item> actualItems=new HashMap<>();for(var slip:source.slips())for(var item:slip.items())actualItems.put(item.id(),item);
        if(instruction.deductionAllocations()!=null)for(UUID item:instruction.deductionAllocations().keySet())if(!actualItems.containsKey(item)||!"DEDUCTION".equals(actualItems.get(item).type()))issues.add(new Issue("deductionAllocations",Objects.toString(item,null),"扣款分配不属于本批原工资项目"));
        for(var slip:source.slips()){
            if(instruction.mode()==AccrualMode.NATIVE_APPROVED_PAYROLL&&slip.grossIncome().signum()>0)try{
                if(slip.departmentId()==null)throw invalid("原工资条缺少明确部门，请先核对原工资事实");
                Style cost=style(instruction.expenseStyleByDepartment()==null?null:instruction.expenseStyleByDepartment().get(slip.departmentId()),source,styles);
                if(!cost.costAllowed())throw invalid("部门工资成本须为在用费用末级或已明确的制造费用成本末级");costs.add(new Cost(slip,cost));
            }catch(ApiException e){issues.add(issue("expenseStyleByDepartment",slip.employeeCode(),e));}
            if(!needsDeductions)continue;
            for(var item:slip.items())if("DEDUCTION".equals(item.type())&&item.amount().signum()!=0)try{
                List<DeductionAllocation> allocations=instruction.deductionAllocations()==null?null:instruction.deductionAllocations().get(item.id());
                if(allocations==null||allocations.isEmpty())allocations=compatible(item,instruction,source,styles);
                if(allocations.size()>100)throw invalid("同一原扣款项目最多100个明确份额");
                BigDecimal total=BigDecimal.ZERO;var ids=new HashSet<UUID>();
                for(var a:allocations){
                    if(a==null||a.id()==null||!ids.add(a.id())||a.purpose()==null)throw invalid("请保留每个扣款份额的唯一身份并明确实际用途");
                    BigDecimal amount=amount(a.amount(),"原扣款分配");if(amount.signum()==0||amount.signum()!=item.amount().signum())throw invalid("扣款份额须非零且与该条原项目方向相同");total=total.add(amount);
                    Style s=style(a.styleId(),source,styles);FinancialAuxiliaryValidationPort.Ref ref=null;
                    switch(a.purpose()){
                        case STANDARD_LIABILITY->{if(!"LIABILITY".equals(s.category()))throw invalid("代扣负债须明确为负债科目");}
                        case STANDARD_INCOME->{if(!"INCOME".equals(s.category()))throw invalid("明确收入用途须对应收入科目");}
                        case EXPENSE_REDUCTION->{if(!"EXPENSE".equals(s.category()))throw invalid("费用冲减须为明确的费用末级");}
                        case MANUFACTURING_COST_REDUCTION->{if(!"ACCOUNT".equals(s.category())||!s.costAllowed())throw invalid("制造成本冲减须为明确的制造费用成本末级");}
                        case EMPLOYEE_SETTLEMENT->{
                            if(amount.signum()<0)throw invalid("负员工借款扣款不能冒充正向清偿，请按真实补发或借款返还来源办理");
                            if(!"ASSET".equals(s.classification())||!Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_payroll_employee_settlement_style_allowed(?)",Boolean.class,s.id())))throw invalid("员工借款清偿须使用明确的其他应收往来资产科目");
                            if(a.auxiliaryId()==null||a.original()==null)throw invalid("员工往来扣款须选择本人的真实辅助及原GL/余额池来源");
                            ref=auxiliary.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(s.code(),a.auxiliaryId(),s.currencyId()))).getFirst();
                            if(ref==null||!"EMPLOYEE".equals(ref.role())||!sameEmployee(slip.employeeId(),ref.partyId()))throw invalid("扣款辅助必须是这张原工资条的员工，不能按同名或其他人借款抵扣");
                        }
                    }
                    if(a.purpose()!=DeductionPurpose.EMPLOYEE_SETTLEMENT){if(a.auxiliaryId()!=null||a.original()!=null)throw invalid("非员工往来用途不能附带借款清偿来源");auxiliary.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(s.code(),null,s.currencyId())));}
                    parts.add(new Part(item.id(),a.id(),slip,a.purpose(),s,amount,ref,a.original(),a.sourceReference()));
                }
                if(total.compareTo(item.amount())!=0)throw invalid("分配合计须等于该员工这条原扣款金额，不能改写或遗漏原项目");
            }catch(ApiException e){issues.add(issue("deductionAllocations",slip.employeeCode()+" / "+item.name()+" / "+item.id(),e));}
        }
        if(accrued!=null){
            if(!source.fingerprint().equals(accrued.get("source_fingerprint")))issues.add(new Issue("source",null,"本批已有工资计提，原工资事实发生变化；须保留历史并先核对财务来源"));
            try{Instruction original=json.readValue(accrued.get("instruction_snapshot").toString(),Instruction.class);if(!effectHash(original).equals(effectHash(instruction)))throw invalid("本批已有一次工资计提/认领，不能在再次支付时替换科目或再扣一次原工资项目");}catch(ApiException e){issues.add(issue("instruction",null,e));}catch(Exception e){throw new IllegalStateException("原工资会计准备无法读取",e);}
            if(instruction.mode()==AccrualMode.NATIVE_APPROVED_PAYROLL&&source.grossIncome().signum()>0){UUID id=(UUID)accrued.get("voucher_id");if(id==null||db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE id=? AND status=1 AND NOT is_deleted AND reversed_by_voucher_id IS NULL",Integer.class,id)!=1)issues.add(new Issue("accrual",null,"原工资计提凭证已失效，不能再按完整工资支付"));}
        }
        if(date!=null&&!(accrued!=null&&instruction.mode()==AccrualMode.NATIVE_APPROVED_PAYROLL)){
            for(var part:parts)if(part.purpose()==DeductionPurpose.EMPLOYEE_SETTLEMENT)try{proofs.add(checkDeduction(source,part,date));}catch(ApiException e){issues.add(issue("deductionSettlements",part.itemId().toString(),e));}
        }
        if(instruction.mode()==AccrualMode.EXISTING_CONFIRMED_LIABILITY){
            if(instruction.existingLiabilityBasis()==null)issues.add(new Issue("existingLiabilityBasis",null,"请明确原工资负债是扣款前应发还是扣款后实发，不能重复拆扣"));
            if(instruction.originalEvidenceIds()==null||instruction.originalEvidenceIds().isEmpty())issues.add(new Issue("originalEvidenceIds",null,"认领原工资负债须选择本申请已核验的原始凭据"));
            if(wage!=null&&date!=null)try{
                BigDecimal required=instruction.existingLiabilityBasis()==ExistingLiabilityBasis.GROSS_BEFORE_DEDUCTIONS?source.grossIncome():source.netIncome();
                if(required.signum()>0){
                    var lines=instruction.existingLiabilityLines();if(lines==null||lines.isEmpty())throw invalid("请选择明确的原工资负债GL分录及本批份额");
                    var seen=new HashSet<String>();BigDecimal total=BigDecimal.ZERO;
                    for(var line:lines){if(line==null||line.entryId()==null||line.allocationNo()<1||!seen.add(line.entryId()+":"+line.allocationNo()))throw invalid("原工资负债来源不能缺失或重复");BigDecimal value=amount(line.amountLocal(),"原工资负债份额"),original=amount(line.amountOriginal(),"原工资负债原额");if(value.signum()<=0||value.compareTo(original)!=0)throw invalid("本批为本位币工资，原本币/原币份额须有相同的真实金额");
                        var fact=db.queryForMap("SELECT a.auxiliary_id FROM finance_gl_entry_allocations a WHERE a.entry_id=? AND a.allocation_no=?",line.entryId(),line.allocationNo());UUID aux=(UUID)fact.get("auxiliary_id");FinancialAuxiliaryValidationPort.Ref ref=aux==null?null:auxiliary.inspect(new FinancialAuxiliaryValidationPort.Selection(wage.code(),aux,wage.currencyId()));
                        if(ref!=null&&(!"EMPLOYEE".equals(ref.role())||source.slips().stream().noneMatch(s->sameEmployee(s.employeeId(),ref.partyId()))))throw invalid("原工资负债含本批之外的员工辅助，不能挪用他人工资");
                        var scope=new FinanceGlSettlementCapacityPort.Scope(wage.id(),wage.code(),aux,wage.currencyId(),source.currencyId(),-1,date);
                        var mode=aux==null?FinanceGlSettlementCapacityPort.Mode.CONFIRMED_AGGREGATE_LIABILITY:FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE;
                        var preview=capacity.preview(scope,mode,List.of(new FinanceGlSettlementCapacityPort.SourceRef(line.entryId(),line.allocationNo())));
                        requireCapacity(preview,line.sourceFingerprint(),value);proofs.add(preview.fingerprint());liabilities.add(new Liability(wage,ref,line,value));total=total.add(value);
                    }
                    if(total.compareTo(required)!=0)throw invalid("原工资负债明确份额须等于本批所选应发/实发基数");
                }else if(source.grossIncome().signum()>0){
                    UUID voucher=instruction.existingAccrualVoucherId();if(voucher==null)throw invalid("实发为零且原扣款已记账时，请明确原非现金工资凭证");
                    var rows=db.queryForList("SELECT e.id,e.style_id,e.direction,e.amount,e.entry_date FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.id=? AND v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL AND NOT e.is_deleted ORDER BY e.line_no,e.id",voucher);
                    BigDecimal debit=BigDecimal.ZERO,total=BigDecimal.ZERO;for(var row:rows){BigDecimal a=(BigDecimal)row.get("amount");total=total.add(a.multiply(BigDecimal.valueOf(((Number)row.get("direction")).intValue())));if(wage.id().equals(row.get("style_id"))&&((Number)row.get("direction")).intValue()==1)debit=debit.add(a);}
                    if(rows.isEmpty()||total.signum()!=0||debit.compareTo(source.grossIncome())!=0||db.queryForObject("SELECT count(*) FROM gl_entries e JOIN accounts a ON account_style_id(a.id)=e.style_id WHERE e.voucher_id=? AND NOT e.is_deleted",Integer.class,voucher)>0)throw invalid("原非现金凭证须有本批真实工资借项且借贷平衡，不得认领银行付款或按同额猜凭证");proofs.add(rows);
                }
            }catch(org.springframework.dao.EmptyResultDataAccessException e){issues.add(new Issue("existingLiabilityLines",null,"明确选择的原工资负债分配已缺失"));}catch(ApiException e){issues.add(issue("existingLiabilityLines",null,e));}
        }
        if(instruction.originalEvidenceIds()!=null){for(UUID id:instruction.originalEvidenceIds()){
            var rows=db.queryForList("SELECT id,sha256 FROM attachments WHERE id=? AND owner_type='FINANCE_APPLICATION' AND owner_id=? AND lifecycle_state='CLEAN' AND delete_requested_at IS NULL",id,applicationId);
            if(rows.size()!=1)issues.add(new Issue("originalEvidenceIds",Objects.toString(id,null),"原始依据文件尚未核验或已失效"));else proofs.add(rows.getFirst());
        }}
        String fingerprint=hash(Arrays.asList(source.fingerprint(),instruction,new TreeMap<>(styles.entrySet().stream().collect(java.util.stream.Collectors.toMap(e->e.getKey().toString(),Map.Entry::getValue))),proofs,accrued==null?null:accrued.get("batch_id")));
        return new Plan(source,instruction,date,wage,List.copyOf(costs),List.copyOf(parts),List.copyOf(liabilities),List.copyOf(issues),fingerprint,accrued,List.copyOf(proofs));
    }
    private List<DeductionAllocation> compatible(Item item,Instruction instruction,Source source,Map<UUID,Style> styles){
        UUID id=instruction.deductionStyleByCode()==null?null:instruction.deductionStyleByCode().get(item.code());
        if(id==null)throw invalid("请逐原扣款项目明确科目和用途");Style style=style(id,source,styles);
        DeductionPurpose purpose=switch(style.category()){case "LIABILITY"->DeductionPurpose.STANDARD_LIABILITY;case "INCOME"->DeductionPurpose.STANDARD_INCOME;default->throw invalid("往来和费用冲减不能仅按扣款代码统一科目，请逐原项目选择用途");};
        return List.of(new DeductionAllocation(item.id(),purpose,id,item.amount().toPlainString(),null,null,instruction.sourceReference()));
    }
    private Object checkDeduction(Source source,Part part,LocalDate date){
        var original=part.original();boolean pool="GL_AUXILIARY_BALANCE_POOL".equals(original.kind());
        if(!pool&&!"GL_ALLOCATION".equals(original.kind()))throw invalid("员工清偿只接受明确原GL分配或该员工实际余额池");
        if(pool&&!part.auxiliary().auxiliaryId().equals(original.sourceId()))throw invalid("余额池身份与原员工辅助不一致");
        var refs=pool?List.<FinanceGlSettlementCapacityPort.SourceRef>of():List.of(new FinanceGlSettlementCapacityPort.SourceRef(original.sourceId(),original.allocationNo()==null?0:original.allocationNo()));
        var preview=capacity.preview(new FinanceGlSettlementCapacityPort.Scope(part.style().id(),part.style().code(),part.auxiliary().auxiliaryId(),part.style().currencyId(),source.currencyId(),1,date),pool?FinanceGlSettlementCapacityPort.Mode.AUXILIARY_BALANCE_POOL:FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE,refs);
        requireCapacity(preview,original.sourceFingerprint(),part.amount());return preview.fingerprint();
    }
    private static void requireCapacity(FinanceGlSettlementCapacityPort.Preview p,String expected,BigDecimal amount){
        if(!p.ready())throw invalid(p.issues().stream().map(FinanceGlSettlementCapacityPort.Issue::message).reduce((a,b)->a+"；"+b).orElse("原GL余额待核对"));
        if(!Objects.equals(expected,p.fingerprint()))throw invalid("原GL来源或实际未结额已变化，请重新选择并核对本批份额");
        if(amount.compareTo(p.availableLocal())>0||amount.compareTo(p.availableOriginal())>0||!p.sources().isEmpty()&&p.sources().stream().noneMatch(s->s.amountLocal().compareTo(amount)>=0&&s.amountOriginal().compareTo(amount)>=0))throw invalid("本批明确份额超过实际未结的原GL金额");
    }
    private Style style(UUID id,Source source,Map<UUID,Style> cache){
        if(id==null)throw invalid("请选择明确的会计科目");if(cache.containsKey(id))return cache.get(id);
        var rows=db.queryForList("SELECT s.category,c.code,c.classification,c.row_version,fn_finance_cost_expense_style_allowed(s.id) AS cost_allowed FROM payment_styles s JOIN finance_chart_code_styles m ON m.style_id=s.id JOIN finance_chart_codes c ON c.code=m.code WHERE s.id=? AND s.status='使用' AND NOT s.is_deleted AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)",id);
        if(rows.size()!=1)throw invalid("请先将该在用末级科目明确对应财务代码");var row=rows.getFirst();String code=row.get("code").toString();var currency=currencies.read(Set.of(code)).get(code);
        if(currency==null||!source.currencyId().equals(currency.currencyId()))throw invalid("本批工资使用本位币，科目会计币别须已明确对应");
        var result=new Style(id,code,row.get("category").toString(),Objects.toString(row.get("classification"),null),currency.currencyId(),Boolean.TRUE.equals(row.get("cost_allowed")),((Number)row.get("row_version")).longValue());cache.put(id,result);return result;
    }
    Style postingStyle(UUID id,Source source){return style(id,source,new HashMap<>());}
    private boolean sameEmployee(UUID first,UUID second){return first!=null&&second!=null&&Boolean.TRUE.equals(db.queryForObject("SELECT fn_canonical_employee_identity(?)=fn_canonical_employee_identity(?)",Boolean.class,first,second));}
    Result result(String raw){try{return json.readValue(raw,Result.class);}catch(Exception e){throw new IllegalStateException("原工资动作回执无法读取",e);}}
    String hash(Object object){try{return ImmutableDocumentStore.digest(json.writer().with(com.fasterxml.jackson.databind.SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writeValueAsBytes(object));}catch(Exception e){throw new IllegalStateException("工资会计准备无法编码",e);}}
    String encode(Object object){try{return json.writeValueAsString(object);}catch(Exception e){throw new IllegalStateException("工资会计准备无法保存",e);}}
    Instruction instruction(Object raw){try{return json.readValue(raw.toString(),Instruction.class);}catch(Exception e){throw new IllegalStateException("原工资会计准备无法读取",e);}}
    private String effectHash(Instruction i){var node=json.valueToTree(i);if(node.isObject()){
        var object=(com.fasterxml.jackson.databind.node.ObjectNode)node;
        if(i.mode()==AccrualMode.NATIVE_APPROVED_PAYROLL)object.remove(List.of("existingAccrualVoucherId","existingLiabilityBasis","existingLiabilityLines"));
        else{object.remove("expenseStyleByDepartment");if(i.existingLiabilityBasis()==ExistingLiabilityBasis.NET_AFTER_DEDUCTIONS)object.remove(List.of("deductionStyleByCode","deductionAllocations","deductionSettlements"));}
    }stripMetadata(node);return hash(json.convertValue(node,Object.class));}
    private void stripMetadata(com.fasterxml.jackson.databind.JsonNode node){if(node.isObject()){var object=(com.fasterxml.jackson.databind.node.ObjectNode)node;object.remove(List.of("accountingAsOf","sourceReference","sourceFingerprint","originalEvidenceIds","id"));
        for(String key:List.of("amount","amountLocal","amountOriginal")){var value=object.get(key);if(value!=null&&value.isTextual())try{object.put(key,new BigDecimal(value.asText()).stripTrailingZeros().toPlainString());}catch(NumberFormatException ignored){}}
        for(var property:object.properties())stripMetadata(property.getValue());
    }else if(node.isArray())for(var child:node)stripMetadata(child);}
    static BigDecimal amount(String text,String label){if(text==null||text.length()>128||!text.matches("-?[0-9]+(?:\\.[0-9]+)?"))throw invalid(label+"须为完整十进制原文");try{return FinancialExactAmount.require(new BigDecimal(text),label);}catch(NumberFormatException e){throw invalid(label+"须为完整十进制原文");}}
    static void reference(String value){if(value==null||value.strip().length()<4||value.length()>2000)throw invalid("请填写明确的原工资会计依据（4至2000字）");}
    private static Issue issue(String field,String row,ApiException e){return new Issue(field,row,e.getMessage());}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
}
