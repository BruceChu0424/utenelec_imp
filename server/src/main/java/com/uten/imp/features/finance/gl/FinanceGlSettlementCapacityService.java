package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.FinanceGlSettlementCapacityPort;
import com.uten.imp.application.port.FinancialAuxiliaryValidationPort;
import com.uten.imp.application.port.FinancialChartCurrencyReadPort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;

/** Actual GL capacity plus unfinished reservations, shared by payroll and employee advances. */
@Service @RequiredArgsConstructor
public class FinanceGlSettlementCapacityService implements FinanceGlSettlementCapacityPort {
    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final GlPostingService periods;
    private final FinancialAuxiliaryValidationPort auxiliary;
    private final FinancialChartCurrencyReadPort currencies;

    @Override @Transactional(readOnly=true)
    public Preview preview(Scope scope,Mode mode,List<SourceRef> sources){
        current.requireId();return read(scope,mode,refs(sources),false);
    }
    @Override @Transactional(readOnly=true)
    public Preview preview(Scope scope,Mode mode,List<SourceRef> sources,Owner owner){
        owned(owner);return read(scope,mode,refs(sources),nativePrepayment(owner));
    }
    @Override @Transactional
    public Receipt reserve(Reservation command){
        if(command==null)throw invalid("缺少清偿预留内容");owned(command.owner());operationLock(command.requestId());
        String payload=hash(command);var replay=replay(command.requestId(),"RESERVE",payload);if(replay!=null)return replay;
        validateAmount(command.amountLocal(),command.amountOriginal());reference(command.sourceReference());
        var parts=command.sources()==null?List.<SourceAmount>of():List.copyOf(command.sources());
        if(parts.stream().anyMatch(Objects::isNull))throw invalid("原GL份额不能为空");
        for(var part:parts)validateAmount(part.amountLocal(),part.amountOriginal());
        var refs=refs(parts.stream().map(SourceAmount::source).toList());
        if(command.mode()==Mode.CONFIRMED_AGGREGATE_LIABILITY&&!command.owner().kind().startsWith("PAYROLL_"))throw invalid("聚合工资负债须由可信工资批准指令调用");
        Scope scope=command.scope();writeLock(scope);UUID scopeId=scopeId(scope);
        var preview=read(scope,command.mode(),refs,nativePrepayment(command.owner()));
        if(!preview.ready())throw invalid(preview.issues().stream().map(Issue::message).reduce((a,b)->a+"；"+b).orElse("清偿来源待核对"));
        if(!Objects.equals(preview.fingerprint(),command.expectedFingerprint()))throw conflict("实际总账或其他清偿预留已变化，请重新核对余额和原来源");
        if(command.amountLocal().compareTo(preview.availableLocal())>0||command.amountOriginal().compareTo(preview.availableOriginal())>0)
            throw conflict("实际未结余额不足，不能重复清偿或挪用其他员工、币种的余额");
        if(command.mode()!=Mode.AUXILIARY_BALANCE_POOL){
            if(parts.isEmpty())throw invalid("指定原GL来源时须逐分录明确本次清偿份额");
            equal(sum(parts,true),command.amountLocal(),"原GL本币份额");equal(sum(parts,false),command.amountOriginal(),"原GL原币份额");
            Map<SourceRef,SourceAmount> available=new HashMap<>();preview.sources().forEach(p->available.put(p.source(),p));
            for(var part:parts){validateAmount(part.amountLocal(),part.amountOriginal());var capacity=available.get(part.source());
                if(capacity==null||part.amountLocal().compareTo(capacity.amountLocal())>0||part.amountOriginal().compareTo(capacity.amountOriginal())>0)
                    throw conflict("所选原GL分录的未结份额不足，不能重复认领");}
        }else if(!parts.isEmpty())throw invalid("辅助余额池不声明某张旧单已结清，请移除逐单来源份额");
        var identity=auxiliary.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId()))).getFirst();
        db.update("INSERT INTO finance_gl_settlement_scopes(id,style_id,account_code,auxiliary_id,accounting_currency_id,original_currency_id,natural_direction,auxiliary_role,party_id_snapshot) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING",
                scopeId,scope.styleId(),scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId(),scope.originalCurrencyId(),scope.naturalDirection(),identity==null?null:identity.role(),identity==null?null:identity.partyId());
        UUID id=UUID.randomUUID();
        db.update("""
                INSERT INTO finance_gl_settlement_reservations(id,request_id,scope_id,owner_kind,owner_id,actor_id,as_of,mode,
                  amount_local,amount_original,fingerprint,source_reference,status)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'RESERVED')
                """,id,command.requestId(),scopeId,command.owner().kind(),command.owner().id(),current.requireId(),scope.asOf(),command.mode().name(),
                    command.amountLocal(),command.amountOriginal(),preview.fingerprint(),command.sourceReference());
        for(var part:parts)db.update("INSERT INTO finance_gl_settlement_source_parts(reservation_id,entry_id,allocation_no,amount_local,amount_original) VALUES(?,?,?,?,?)",
                id,part.source().entryId(),part.source().allocationNo(),part.amountLocal(),part.amountOriginal());
        var result=new Receipt(id,command.requestId(),"RESERVED",preview.fingerprint());saveOperation(command.requestId(),"RESERVE",payload,result);return result;
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public Receipt commit(Commit command){
        if(command==null)throw invalid("缺少实际清偿内容");owned(command.owner());operationLock(command.requestId());
        String payload=hash(command);var replay=replay(command.requestId(),"COMMIT",payload);if(replay!=null)return replay;
        var row=reservation(command.reservationId(),command.owner(),true);Scope scope=scope(row);writeLock(scope);
        if(!"RESERVED".equals(row.get("status")))throw conflict("本次清偿预留已处理，请先核对原回执");
        List<Clearing> clearings=command.clearings();
        if(clearings==null||clearings.isEmpty()||clearings.size()>10000||clearings.stream().anyMatch(Objects::isNull))throw invalid("请选择完整的真实清偿GL分录");
        var keys=new HashSet<SourceRef>();BigDecimal local=BigDecimal.ZERO,original=BigDecimal.ZERO;
        Map<SourceRef,BigDecimal[]> grouped=new HashMap<>();int line=0;
        boolean exact=!"AUXILIARY_BALANCE_POOL".equals(row.get("mode"));
        boolean nativePrepayment=nativePrepayment(command.owner());
        for(var clearing:clearings){
            var key=new SourceRef(clearing.entryId(),clearing.allocationNo());if(!keys.add(key))throw invalid("真实清偿GL分录不能重复使用");
            var fact=fact(key);
            if(nativePrepayment){
                if(!Objects.equals(command.owner().kind(),fact.get("source_type"))||!Objects.equals(command.owner().kind(),fact.get("entry_source_type"))||!Objects.equals(command.owner().id(),fact.get("entry_source_id")))
                    throw invalid("原生预付清偿须来自该原应用或退款自己的真实受控凭证");
            }else if(!Boolean.TRUE.equals(fact.get("general_eligible")))throw invalid("原生往来或现金分录须从原业务清偿，不能用于另一通用清偿");
            match(new Scope(scope.styleId(),scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId(),scope.originalCurrencyId(),scope.naturalDirection(),BusinessTime.today(),scope.expectedAuxiliaryRole()),fact);
            if(date(fact.get("entry_date")).isBefore(scope.asOf()))throw invalid("实际清偿日期不能早于已核对来源的截止日期");
            matchParty(row,fact);
            if(((Number)fact.get("voucher_status")).intValue()!=1||fact.get("reversed_by_voucher_id")!=null)throw invalid("实际清偿凭证已被红冲，不能再确认该清偿");
            BigDecimal l=signed(fact,"amount_local",-scope.naturalDirection()),o=signed(fact,"amount_original",-scope.naturalDirection());
            validateAmount(l,o);local=local.add(l);original=original.add(o);
            if(exact!=(clearing.original()!=null))throw invalid("实际清偿分录须与本次指定原来源或辅助余额池模式一致");
            if(exact){requirePartition(fact(clearing.original()),nativePrepayment);var totals=grouped.computeIfAbsent(clearing.original(),ignored->new BigDecimal[]{BigDecimal.ZERO,BigDecimal.ZERO});totals[0]=totals[0].add(l);totals[1]=totals[1].add(o);}
            db.update("INSERT INTO finance_gl_settlement_clearings(reservation_id,line_no,entry_id,allocation_no,source_entry_id,source_allocation_no) VALUES(?,?,?,?,?,?)",
                    command.reservationId(),++line,key.entryId(),key.allocationNo(),clearing.original()==null?null:clearing.original().entryId(),clearing.original()==null?null:clearing.original().allocationNo());
        }
        equal(local,decimal(row.get("amount_local")),"实际清偿本币合计");equal(original,decimal(row.get("amount_original")),"实际清偿原币合计");
        var parts=parts(command.reservationId());
        if(exact){if(grouped.size()!=parts.size())throw invalid("实际清偿与指定原GL份额未逐项对应");
            for(var part:parts){var values=grouped.get(part.source());if(values==null)throw invalid("缺少原GL份额对应的实际清偿分录");equal(values[0],part.amountLocal(),"原来源实际本币清偿");equal(values[1],part.amountOriginal(),"原来源实际原币清偿");}}
        db.update("UPDATE finance_gl_settlement_reservations SET status='COMMITTED',updated_at=now() WHERE id=?",command.reservationId());
        var result=receiptRow(row,"COMMITTED");saveOperation(command.requestId(),"COMMIT",payload,result);return result;
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public Receipt release(Release command){
        if(command==null)throw invalid("缺少原清偿反向事实");owned(command.owner());operationLock(command.requestId());reference(command.reason());
        String payload=hash(command);var replay=replay(command.requestId(),"RELEASE",payload);if(replay!=null)return replay;
        var row=reservation(command.reservationId(),command.owner(),true);Scope scope=scope(row);writeLock(scope);
        if(!"COMMITTED".equals(row.get("status")))throw conflict("只可按已完成清偿的真实反向GL释放，不能直接恢复余额");
        var prior=db.queryForList("SELECT entry_id,allocation_no FROM finance_gl_settlement_clearings WHERE reservation_id=? ORDER BY line_no",command.reservationId());
        if(command.reversals()==null||command.reversals().size()!=prior.size()||command.reversals().stream().anyMatch(Objects::isNull))throw invalid("须逐项核对原清偿的完整反向分录");
        Set<SourceRef> expected=new HashSet<>();prior.forEach(p->expected.add(new SourceRef((UUID)p.get("entry_id"),((Number)p.get("allocation_no")).intValue())));
        int line=0;for(var reverse:command.reversals()){
            var originalRef=new SourceRef(reverse.originalEntryId(),reverse.originalAllocationNo());if(!expected.remove(originalRef))throw invalid("原清偿分录重复或不属于本次清偿");
            var before=fact(originalRef);var after=fact(new SourceRef(reverse.entryId(),reverse.allocationNo()));
            match(new Scope(scope.styleId(),scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId(),scope.originalCurrencyId(),scope.naturalDirection(),BusinessTime.today(),scope.expectedAuxiliaryRole()),after);matchParty(row,after);
            if(!Objects.equals(after.get("reversal_of_voucher_id"),before.get("voucher_id"))||!Objects.equals(before.get("reversed_by_voucher_id"),after.get("voucher_id"))
                    ||((Number)after.get("direction")).intValue()!=-((Number)before.get("direction")).intValue())throw invalid("新分录不是原清偿凭证的真实对称红冲");
            equal(decimal(after.get("amount_local")),decimal(before.get("amount_local")),"反向本币金额");equal(decimal(after.get("amount_original")),decimal(before.get("amount_original")),"反向原币金额");
            db.update("INSERT INTO finance_gl_settlement_reversals(reservation_id,line_no,entry_id,allocation_no,original_entry_id,original_allocation_no) VALUES(?,?,?,?,?,?)",
                    command.reservationId(),++line,reverse.entryId(),reverse.allocationNo(),originalRef.entryId(),originalRef.allocationNo());
        }
        db.update("UPDATE finance_gl_settlement_reservations SET status='RELEASED',updated_at=now() WHERE id=?",command.reservationId());
        var result=receiptRow(row,"RELEASED");saveOperation(command.requestId(),"RELEASE",payload,result);return result;
    }
    @Override @Transactional
    public Receipt cancel(Cancel command){
        if(command==null)throw invalid("缺少取消清偿内容");owned(command.owner());operationLock(command.requestId());reference(command.reason());
        String payload=hash(command);var replay=replay(command.requestId(),"CANCEL",payload);if(replay!=null)return replay;
        var row=reservation(command.reservationId(),command.owner(),true);writeLock(scope(row));
        if(!"RESERVED".equals(row.get("status"))||db.queryForObject("SELECT count(*) FROM finance_gl_settlement_clearings WHERE reservation_id=?",Integer.class,command.reservationId())!=0)
            throw conflict("已有真实清偿只能按原反向GL释放，不能直接取消");
        db.update("UPDATE finance_gl_settlement_reservations SET status='CANCELLED',updated_at=now() WHERE id=?",command.reservationId());
        var result=receiptRow(row,"CANCELLED");saveOperation(command.requestId(),"CANCEL",payload,result);return result;
    }
    @Override @Transactional(readOnly=true)
    public Receipt receipt(UUID id,Owner owner){owned(owner);var row=reservation(id,owner,false);return receiptRow(row,row.get("status").toString());}

    private Preview read(Scope scope,Mode mode,List<SourceRef> sources,boolean nativePrepayment){
        validateScope(scope);if(mode==null)throw invalid("请选择辅助余额池或指定原GL来源");
        List<Issue> issues=new ArrayList<>();
        var readScope=FinancialLedgerReadScope.asOf(em,scope.asOf());
        if(!readScope.complete())issues.add(new Issue("asOf",readScope.basis()));
        var metadata=db.queryForList("""
                SELECT s.category,s.status,c.row_version,c.currency_id FROM payment_styles s
                JOIN finance_chart_code_styles m ON m.style_id=s.id JOIN finance_chart_codes c ON c.code=m.code
                WHERE s.id=? AND m.code=? AND NOT s.is_deleted
                  AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)
                """,scope.styleId(),scope.accountCode());
        if(metadata.size()!=1||!"使用".equals(metadata.getFirst().get("status"))||!Set.of("ACCOUNT","LIABILITY").contains(metadata.getFirst().get("category")))
            issues.add(new Issue("accountCode","清偿科目须为明确对应财务代码的在用往来/负债末级"));
        var references=currencies.read(Set.of(scope.accountCode()));var currency=references.get(scope.accountCode());
        if(currency==null||!Objects.equals(currency.currencyId(),scope.accountingCurrencyId()))issues.add(new Issue("accountingCurrencyId","科目币别属性尚未对应，不能用本币值冒充原币"));
        FinancialAuxiliaryValidationPort.Ref employee=null;
        try{var ref=auxiliary.inspect(new FinancialAuxiliaryValidationPort.Selection(scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId()));employee=ref;
            if(scope.auxiliaryId()!=null&&(ref==null||!Objects.equals(scope.expectedAuxiliaryRole(),ref.role())))issues.add(new Issue("auxiliaryId","清偿须明确对应本业务指定类别的真实往来对象"));
        }catch(ApiException failure){issues.add(new Issue("auxiliaryId",failure.getMessage()));}
        if(mode==Mode.AUXILIARY_BALANCE_POOL&&scope.auxiliaryId()==null)issues.add(new Issue("auxiliaryId","辅助余额池须明确真实往来对象，不能使用未分配的总额"));
        if(mode!=Mode.AUXILIARY_BALANCE_POOL&&sources.isEmpty())issues.add(new Issue("sources","须选择本次财务明确关联的原GL来源范围"));
        if(mode==Mode.CONFIRMED_AGGREGATE_LIABILITY&&(scope.auxiliaryId()!=null||metadata.size()!=1||!"LIABILITY".equals(metadata.getFirst().get("category"))))
            issues.add(new Issue("mode","聚合未分人来源只适用于明确的工资负债及其原GL范围，不能伪造员工辅助"));
        if(mode==Mode.EXPLICIT_GL_SOURCE&&scope.auxiliaryId()==null)issues.add(new Issue("mode","未分人的工资负债须采用明确受审的聚合负债策略"));
        if(mode==Mode.AUXILIARY_BALANCE_POOL&&!sources.isEmpty())issues.add(new Issue("sources","辅助余额池不声明某张历史单据已结清"));
        if(nativePrepayment&&(mode!=Mode.EXPLICIT_GL_SOURCE||!"SUPPLIER".equals(scope.expectedAuxiliaryRole())))
            issues.add(new Issue("mode","原生预付只可按真实供应商和原资产分录逐源应用或退款"));
        UUID scopeId=scopeId(scope);var pending=db.queryForList("SELECT id,as_of,amount_local,amount_original FROM finance_gl_settlement_reservations WHERE scope_id=? AND status='RESERVED' AND fn_finance_gl_settlement_native_prepayment_owner(owner_kind)=? ORDER BY as_of,id",scopeId,nativePrepayment);
        LocalDate through=BusinessTime.today();for(var p:pending)if(date(p.get("as_of")).isAfter(through))through=date(p.get("as_of"));
        var facts=db.queryForList(FACTS+" WHERE e.style_id=? AND a.account_code=? AND a.auxiliary_id IS NOT DISTINCT FROM CAST(? AS uuid) AND a.currency_id=? AND a.original_currency_id=? AND e.entry_date<=? AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND fn_finance_gl_settlement_allocation_eligible(e.id,a.allocation_no,?) ORDER BY e.entry_date,e.id,a.allocation_no",
                scope.styleId(),scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId(),scope.originalCurrencyId(),through,nativePrepayment);
        facts.replaceAll(fact->partitionFact(fact,nativePrepayment));
        if(facts.stream().anyMatch(f->f.get("amount_local")==null||f.get("amount_original")==null))
            issues.add(new Issue("source","原来源已分配给旧往来的份额缺少明确币别金额，剩余清偿不能猜配"));
        for(var fact:facts)if(!Objects.equals(employee==null?null:employee.partyId(),fact.get("party_id_snapshot"))
                ||!Objects.equals(employee==null?null:employee.role(),fact.get("auxiliary_role"))) {
            issues.add(new Issue("auxiliaryId","总账冻结的真实对象与当前辅助目录不一致，不能合并其他对象的余额"));break;
        }
        var registered=db.queryForList("SELECT auxiliary_role,party_id_snapshot FROM finance_gl_settlement_scopes WHERE id=?",scopeId);
        if(!registered.isEmpty()&&(!Objects.equals(registered.getFirst().get("party_id_snapshot"),employee==null?null:employee.partyId())
                ||!Objects.equals(registered.getFirst().get("auxiliary_role"),employee==null?null:employee.role())))
            issues.add(new Issue("auxiliaryId","本清偿范围冻结的对象身份已变化，请先纠正辅助对应关系"));
        int unknown=db.queryForObject("""
                SELECT count(*) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
                WHERE e.style_id=? AND e.entry_date<=? AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id)
                  AND (NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations a WHERE a.entry_id=e.id)
                    OR EXISTS(SELECT 1 FROM finance_gl_entry_allocations a WHERE a.entry_id=e.id
                      AND (a.currency_id IS NULL OR (CAST(? AS uuid) IS NOT NULL AND a.auxiliary_id IS NULL)
                        OR (a.auxiliary_id IS NOT DISTINCT FROM CAST(? AS uuid) AND a.currency_id=?
                          AND (a.original_currency_id IS NULL OR a.amount_original IS NULL)))))
                """,Integer.class,scope.styleId(),through,scope.auxiliaryId(),scope.auxiliaryId(),scope.accountingCurrencyId());
        if(unknown>0)issues.add(new Issue("source","同科目仍有未明确员工辅助或原币单位的已记账事实，清偿余额待核对"));
        var boundaries=new TreeSet<LocalDate>();boundaries.add(scope.asOf());boundaries.add(BusinessTime.today());for(var p:pending)if(!date(p.get("as_of")).isBefore(scope.asOf()))boundaries.add(date(p.get("as_of")));
        BigDecimal local=null,original=null;
        for(LocalDate boundary:boundaries){BigDecimal l=BigDecimal.ZERO,o=BigDecimal.ZERO;
            for(var f:facts)if(!date(f.get("entry_date")).isAfter(boundary)&&f.get("amount_local")!=null&&f.get("amount_original")!=null){l=l.add(signed(f,"amount_local",scope.naturalDirection()));o=o.add(signed(f,"amount_original",scope.naturalDirection()));}
            for(var p:pending)if(!date(p.get("as_of")).isAfter(boundary)){l=l.subtract(decimal(p.get("amount_local")));o=o.subtract(decimal(p.get("amount_original")));}
            local=local==null?l:local.min(l);original=original==null?o:original.min(o);
        }
        if(local==null||original==null)throw invalid("清偿范围缺少截止边界，不能计算可用清偿余额");
        List<SourceAmount> available=new ArrayList<>();List<Object> originalProof=new ArrayList<>();
        for(var ref:sources){try{var fact=fact(ref);match(scope,fact);
            requirePartition(fact,nativePrepayment);
            fact=partitionFact(fact,nativePrepayment);
            if(((Number)fact.get("voucher_status")).intValue()!=1||fact.get("reversed_by_voucher_id")!=null)throw invalid("指定原GL来源已被红冲，请明确选择仍有效的来源");
            BigDecimal l=signed(fact,"amount_local",scope.naturalDirection()),o=signed(fact,"amount_original",scope.naturalDirection());validateAmount(l,o);
            var spent=sourceConsumed(ref,BusinessTime.today(),scope.naturalDirection());l=l.subtract(spent[0]);o=o.subtract(spent[1]);
            var reserved=db.queryForMap("SELECT COALESCE(sum(p.amount_local),0) AS local,COALESCE(sum(p.amount_original),0) AS original FROM finance_gl_settlement_source_parts p JOIN finance_gl_settlement_reservations r ON r.id=p.reservation_id WHERE p.entry_id=? AND p.allocation_no=? AND r.status='RESERVED'",ref.entryId(),ref.allocationNo());
            l=l.subtract(decimal(reserved.get("local")));o=o.subtract(decimal(reserved.get("original")));
            available.add(new SourceAmount(ref,l.max(BigDecimal.ZERO).min(local.max(BigDecimal.ZERO)),o.max(BigDecimal.ZERO).min(original.max(BigDecimal.ZERO))));originalProof.add(List.of(ref,fact,spent[0],spent[1],reserved));
        }catch(ApiException failure){issues.add(new Issue("sources",failure.getMessage()));}}
        String fingerprint=hash(Arrays.asList(scope,mode,sources,nativePrepayment,readScope,metadata,currency,employee,registered,pending,facts,originalProof,unknown));
        return new Preview(fingerprint,issues.isEmpty()?local.max(BigDecimal.ZERO):null,issues.isEmpty()?original.max(BigDecimal.ZERO):null,List.copyOf(available),List.copyOf(issues),
                mode==Mode.AUXILIARY_BALANCE_POOL?"按该往来对象、会计属性与真实原币单位的已记账净额清偿；不声明历史某张单据结清":"原GL范围与实际余额双重守恒；已完成清偿由真实GL计算，不再次扣减");
    }
    private static final String FACTS="SELECT e.id,e.style_id,e.direction,e.entry_date,e.voucher_id,e.source_doc_type AS entry_source_type,e.source_doc_id AS entry_source_id,v.status AS voucher_status,v.source_type,v.source_doc_id,v.reversal_of_voucher_id,v.reversed_by_voucher_id,a.allocation_no,a.account_code,a.auxiliary_id,a.currency_id,a.original_currency_id,a.amount_local,a.amount_original,a.auxiliary_role,a.party_id_snapshot,fn_finance_gl_settlement_general_local(e.id,a.allocation_no) AS general_local,fn_finance_gl_settlement_general_original(e.id,a.allocation_no) AS general_original,fn_finance_gl_settlement_allocation_eligible(e.id,a.allocation_no,false) AS general_eligible,fn_finance_gl_settlement_allocation_eligible(e.id,a.allocation_no,true) AS native_prepayment_eligible FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_entry_allocations a ON a.entry_id=e.id";
    private static Map<String,Object> partitionFact(Map<String,Object> raw,boolean nativePrepayment){
        if(nativePrepayment)return raw;var result=new LinkedHashMap<>(raw);result.put("raw_amount_local",raw.get("amount_local"));result.put("raw_amount_original",raw.get("amount_original"));result.put("amount_local",raw.get("general_local"));result.put("amount_original",raw.get("general_original"));return result;
    }
    private boolean nativePrepayment(Owner owner){return Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_gl_settlement_native_prepayment_owner(?)",Boolean.class,owner.kind()));}
    private static void requirePartition(Map<String,Object> fact,boolean nativePrepayment){
        if(!Boolean.TRUE.equals(fact.get(nativePrepayment?"native_prepayment_eligible":"general_eligible")))
            throw invalid(nativePrepayment?"预付应用或退款须对应原预付资产的真实分录":"该分录由原应收应付、现金或预付业务管理，请从原业务清偿，不能再次认领");
    }
    private Map<String,Object> fact(SourceRef ref){
        if(ref==null||ref.entryId()==null||ref.allocationNo()<1)throw invalid("缺少真实GL分录及辅助分配编号");
        var rows=db.queryForList(FACTS+" WHERE e.id=? AND a.allocation_no=? AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id)",ref.entryId(),ref.allocationNo());
        if(rows.size()!=1)throw invalid("原GL分录不存在、未入账或已变化");return rows.getFirst();
    }
    private BigDecimal[] sourceConsumed(SourceRef ref,LocalDate cutoff,int direction){
        var row=db.queryForMap("""
                SELECT COALESCE(sum(amount_local*direction*?),0) AS local,COALESCE(sum(amount_original*direction*?),0) AS original FROM (
                  SELECT a.amount_local,a.amount_original,e.direction FROM finance_gl_settlement_clearings c
                    JOIN gl_entries e ON e.id=c.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_entry_allocations a ON a.entry_id=c.entry_id AND a.allocation_no=c.allocation_no
                    WHERE c.source_entry_id=? AND c.source_allocation_no=? AND e.entry_date<=? AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id)
                  UNION ALL SELECT a.amount_local,a.amount_original,e.direction FROM finance_gl_settlement_reversals reversed
                    JOIN finance_gl_settlement_clearings c ON c.reservation_id=reversed.reservation_id AND c.entry_id=reversed.original_entry_id AND c.allocation_no=reversed.original_allocation_no
                    JOIN gl_entries e ON e.id=reversed.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_entry_allocations a ON a.entry_id=reversed.entry_id AND a.allocation_no=reversed.allocation_no
                    WHERE c.source_entry_id=? AND c.source_allocation_no=? AND e.entry_date<=? AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id)
                ) facts
                """,-direction,-direction,ref.entryId(),ref.allocationNo(),cutoff,ref.entryId(),ref.allocationNo(),cutoff);
        return new BigDecimal[]{decimal(row.get("local")),decimal(row.get("original"))};
    }
    private static void match(Scope s,Map<String,Object> f){
        if(!Objects.equals(s.styleId(),f.get("style_id"))||!Objects.equals(s.accountCode(),f.get("account_code"))||!Objects.equals(s.auxiliaryId(),f.get("auxiliary_id"))
                ||!Objects.equals(s.accountingCurrencyId(),f.get("currency_id"))||!Objects.equals(s.originalCurrencyId(),f.get("original_currency_id"))||f.get("amount_original")==null
                ||date(f.get("entry_date")).isAfter(s.asOf()))throw invalid("真实GL的科目、员工、会计币别、原币单位或日期与清偿范围不一致");
    }
    private static void matchParty(Map<String,Object> reservation,Map<String,Object> fact){
        if(!Objects.equals(reservation.get("scope_party_id"),fact.get("party_id_snapshot"))
                ||!Objects.equals(reservation.get("scope_auxiliary_role"),fact.get("auxiliary_role")))throw invalid("实际清偿分录的冻结员工身份与原范围不一致");
    }
    private void writeLock(Scope scope){validateScope(scope);tx.bind();PaymentStyleHierarchyLock.lock(em);periods.lockAutoProjectionPeriod(scope.asOf());
        db.query("SELECT fn_finance_gl_settlement_lock_style(?)",rs->{},scope.styleId());}
    private static void validateScope(Scope s){if(s==null||s.styleId()==null||s.accountCode()==null||!s.accountCode().matches("[0-9]{1,32}")||s.accountingCurrencyId()==null||s.originalCurrencyId()==null
            ||(s.auxiliaryId()==null?s.expectedAuxiliaryRole()!=null:s.expectedAuxiliaryRole()==null||!Set.of("EMPLOYEE","SUPPLIER","CUSTOMER","OTHER").contains(s.expectedAuxiliaryRole()))
            ||s.naturalDirection()!=1&&s.naturalDirection()!=-1||s.asOf()==null||s.asOf().isAfter(BusinessTime.today()))throw invalid("请明确科目、会计币别、真实原币单位、方向和有效截止日期");}
    private void owned(Owner owner){if(owner==null||owner.id()==null||owner.kind()==null||!owner.kind().matches("[A-Z][A-Z0-9_]{0,79}")||!current.requireId().equals(owner.actorId()))
        throw new ApiException(ErrorCode.FORBIDDEN,"清偿操作人与当前业务授权身份不一致");tx.bind();}
    private Map<String,Object> reservation(UUID id,Owner owner,boolean lock){var rows=db.queryForList("SELECT r.*,s.style_id,s.account_code,s.auxiliary_id,s.accounting_currency_id,s.original_currency_id,s.natural_direction,s.party_id_snapshot AS scope_party_id,s.auxiliary_role AS scope_auxiliary_role FROM finance_gl_settlement_reservations r JOIN finance_gl_settlement_scopes s ON s.id=r.scope_id WHERE r.id=?"+(lock?" FOR UPDATE OF r":""),id);
        if(rows.size()!=1||!owner.kind().equals(rows.getFirst().get("owner_kind"))||!owner.id().equals(rows.getFirst().get("owner_id")))throw new ApiException(ErrorCode.NOT_FOUND,"本业务的清偿预留不存在");return rows.getFirst();}
    private static Scope scope(Map<String,Object> r){return new Scope((UUID)r.get("style_id"),r.get("account_code").toString(),(UUID)r.get("auxiliary_id"),(UUID)r.get("accounting_currency_id"),(UUID)r.get("original_currency_id"),((Number)r.get("natural_direction")).intValue(),date(r.get("as_of")),(String)r.get("scope_auxiliary_role"));}
    private List<SourceAmount> parts(UUID id){return db.query("SELECT entry_id,allocation_no,amount_local,amount_original FROM finance_gl_settlement_source_parts WHERE reservation_id=?",(r,n)->new SourceAmount(new SourceRef(r.getObject(1,UUID.class),r.getInt(2)),r.getBigDecimal(3),r.getBigDecimal(4)),id);}
    private void operationLock(UUID request){if(request==null)throw invalid("缺少耐久请求编号");db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1006))",rs->{},"finance-gl-settlement-request:"+request);}
    private Receipt replay(UUID id,String action,String fingerprint){var rows=db.queryForList("SELECT actor_id,operation,fingerprint,result::text FROM finance_gl_settlement_operations WHERE request_id=?",id);if(rows.isEmpty())return null;var row=rows.getFirst();
        if(!current.requireId().equals(row.get("actor_id"))||!action.equals(row.get("operation"))||!fingerprint.equals(row.get("fingerprint")))throw conflict("该请求编号已用于其他清偿内容，请核对原回执");
        try{return json.readValue(row.get("result").toString(),Receipt.class);}catch(Exception failure){throw new IllegalStateException("清偿回执无法读取",failure);}}
    private void saveOperation(UUID id,String action,String fingerprint,Receipt result){db.update("INSERT INTO finance_gl_settlement_operations(request_id,actor_id,fingerprint,operation,result) VALUES(?,?,?,?,?::jsonb)",id,current.requireId(),fingerprint,action,encode(result));}
    private static Receipt receiptRow(Map<String,Object> r,String status){return new Receipt((UUID)r.get("id"),(UUID)r.get("request_id"),status,r.get("fingerprint").toString());}
    private static UUID scopeId(Scope scope){return UUID.nameUUIDFromBytes((scope.styleId()+"|"+scope.accountCode()+"|"+scope.auxiliaryId()+"|"+scope.accountingCurrencyId()+"|"+scope.originalCurrencyId()+"|"+scope.naturalDirection()).getBytes(StandardCharsets.UTF_8));}
    private String hash(Object value){return ImmutableDocumentStore.digest(encode(value).getBytes(StandardCharsets.UTF_8));}
    private String encode(Object value){try{return json.writeValueAsString(normalize(value));}catch(Exception failure){throw new IllegalStateException("清偿事实无法编码",failure);}}
    private static Object normalize(Object value){if(value instanceof BigDecimal number)return number.stripTrailingZeros().toPlainString();if(value instanceof Map<?,?> map){var result=new TreeMap<String,Object>();map.forEach((k,v)->result.put(k.toString(),normalize(v)));return result;}if(value instanceof Collection<?> list)return list.stream().map(FinanceGlSettlementCapacityService::normalize).toList();return value;}
    private static List<SourceRef> refs(List<SourceRef> input){var refs=input==null?List.<SourceRef>of():input;if(refs.size()>10000||new HashSet<>(refs).size()!=refs.size()||refs.stream().anyMatch(r->r==null||r.entryId()==null||r.allocationNo()<1))throw invalid("原GL范围不能缺失、重复或超过10000项");return refs.stream().sorted(Comparator.comparing((SourceRef r)->r.entryId().toString()).thenComparingInt(SourceRef::allocationNo)).toList();}
    private static void validateAmount(BigDecimal local,BigDecimal original){FinancialExactAmount.book(local,"清偿本币金额");FinancialExactAmount.require(original,"清偿原币金额");if(local.signum()<=0||original.signum()<=0)throw invalid("清偿金额须为明确的正数");}
    private static BigDecimal sum(List<SourceAmount> parts,boolean local){return parts.stream().map(p->local?p.amountLocal():p.amountOriginal()).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private static BigDecimal signed(Map<String,Object> row,String field,int sign){return decimal(row.get(field)).multiply(BigDecimal.valueOf(((Number)row.get("direction")).intValue()*(long)sign));}
    private static BigDecimal decimal(Object value){if(value==null)throw invalid("真实GL缺少明确金额");return value instanceof BigDecimal d?d:new BigDecimal(value.toString());}
    private static LocalDate date(Object value){return value instanceof java.sql.Date d?d.toLocalDate():value instanceof LocalDate d?d:LocalDate.parse(value.toString());}
    private static void equal(BigDecimal actual,BigDecimal expected,String label){if(actual.compareTo(expected)!=0)throw invalid(label+"与原事实不一致，本次未保存");}
    private static void reference(String value){if(value==null||value.isBlank()||value.length()>2000)throw invalid("请填写明确的来源/处理依据（最多2000字）");}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
