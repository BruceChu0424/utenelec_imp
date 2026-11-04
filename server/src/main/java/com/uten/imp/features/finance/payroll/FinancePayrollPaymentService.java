package com.uten.imp.features.finance.payroll;

import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.*;
import com.uten.imp.application.port.FinancePayrollPaymentPort.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.accountflow.*;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;

/** One native salary accrual, actual bank/GL clearings and durable original receipts. */
@Service @RequiredArgsConstructor
public class FinancePayrollPaymentService implements FinancePayrollPaymentPort {
    private final JdbcTemplate db;private final EntityManager em;
    private final FinancePayrollSourceReader sources;private final FinancePayrollAccountingPlan plans;
    private final FinanceApplicationPaymentAuthorityPort authority;private final FinanceGlSettlementCapacityPort capacity;
    private final FinanceControlledJournalService journals;private final AccountFlowLedgerService bank;
    private final GlPostingService periods;private final SecurityContextCurrentUser current;private final TxSessionVars tx;
    @Override @Transactional public Source source(UUID batchId,boolean forUpdate){current.requireId();return sources.read(batchId,forUpdate);}
    @Override @Transactional public Prepared prepare(UUID applicationId,UUID batchId,String expected,Instruction instruction){
        Source source=sources.read(batchId,true);authority.requirePayrollPreparation(applicationId,batchId,expected);tx.bind();
        if(!source.fingerprint().equals(expected))throw conflict("原工资内容已变化，请重新核对本批事实");
        PaymentStyleHierarchyLock.lock(em);var plan=plans.build(applicationId,source,instruction);
        db.update("""
            INSERT INTO finance_payroll_preparations(application_id,batch_id,source_fingerprint,instruction_fingerprint,instruction,issues,prepared_by)
            VALUES(?,?,?,?,?::jsonb,?::jsonb,?) ON CONFLICT(application_id)DO UPDATE SET batch_id=excluded.batch_id,
              source_fingerprint=excluded.source_fingerprint,instruction_fingerprint=excluded.instruction_fingerprint,
              instruction=excluded.instruction,issues=excluded.issues,prepared_by=excluded.prepared_by,prepared_at=now()
            """,applicationId,batchId,source.fingerprint(),plan.fingerprint(),plans.encode(instruction),plans.encode(plan.issues()),current.requireId());
        return new Prepared(applicationId,batchId,source.fingerprint(),plan.fingerprint(),plan.issues());
    }
    @Override @Transactional public Result execute(Execute command){
        if(command==null||command.requestId()==null||command.applicationId()==null||command.batchId()==null)throw invalid("请保留原工资申请、批次与支付请求编号");
        Source source=sources.read(command.batchId(),true);requestLock(command.requestId());String payload=plans.hash(command);
        var replay=db.queryForList("SELECT * FROM finance_payroll_payment_attempts WHERE request_id=?",command.requestId());
        if(!replay.isEmpty()){var row=replay.getFirst();if(!payload.equals(row.get("payload_fingerprint"))||!command.applicationId().equals(row.get("application_id"))||!current.requireId().equals(row.get("paid_by")))throw conflict("这个原支付请求已有不同内容或办理人，请核对原回执");return result(row);}
        var permit=authority.requirePayrollExecution(command);tx.bind();
        if(!source.fingerprint().equals(command.sourceFingerprint()))throw conflict("原工资事实已变化，不能沿旧批准金额出款");
        var prepared=db.queryForList("SELECT * FROM finance_payroll_preparations WHERE application_id=? AND batch_id=? FOR UPDATE",command.applicationId(),command.batchId());
        if(prepared.size()!=1||!source.fingerprint().equals(prepared.getFirst().get("source_fingerprint"))||!Objects.equals(command.instructionFingerprint(),prepared.getFirst().get("instruction_fingerprint")))throw conflict("请按原工资完成明确会计准备并由原流程批准");
        if(db.queryForObject("SELECT count(*) FROM finance_payroll_payment_attempts WHERE batch_id=? AND state<>'REVERSED'",Integer.class,source.batchId())>0)throw conflict("本批原工资已有实际办理回执，不能再次付款");
        Instruction instruction=plans.instruction(prepared.getFirst().get("instruction"));PaymentStyleHierarchyLock.lock(em);
        if(command.paymentDate()==null||command.paymentDate().isAfter(BusinessTime.today())||instruction.accountingAsOf()==null||instruction.accountingAsOf().isAfter(command.paymentDate()))throw invalid("实际办理日期须已到且不得早于本批会计核对日期");
        var dates=new TreeSet<LocalDate>();dates.add(command.paymentDate());dates.add(instruction.accountingAsOf());
        for(var date:dates)periods.lockAutoProjectionPeriod(date);
        var plan=plans.build(command.applicationId(),source,instruction);
        if(!plan.issues().isEmpty())throw invalid(plan.issues().stream().map(Issue::message).reduce((a,b)->a+"；"+b).orElse("工资会计资料待核对"));
        if(!plan.fingerprint().equals(command.instructionFingerprint()))throw conflict("原科目、工资负债、扣款未结来源或依据已变化，请重新复核会计准备");
        BigDecimal fee=amount(command.bankFee(),"实际手续费"),bankAmount=amount(command.bankAmount(),"实际账户扣款");
        if(fee.signum()<0||bankAmount.signum()<0||bankAmount.compareTo(source.netIncome().add(fee))!=0)throw invalid("实际账户扣款须等于原实发金额加明确手续费，不能改写原工资或以手续费轧差");
        if((fee.signum()>0)!=(command.bankFeeStyleId()!=null))throw invalid("实际手续费与明确手续费科目须一致");
        UUID attempt=stable("PAYROLL_PAYMENT",command.applicationId(),command.requestId());
        var entries=new ArrayList<FinanceControlledJournalService.Entry>();var bindings=new ArrayList<Binding>();
        var allStyles=new ArrayList<UUID>();for(var cost:plan.costs()){allStyles.add(cost.style().id());}for(var part:plan.parts()){allStyles.add(part.style().id());}if(plan.wage()!=null)allStyles.add(plan.wage().id());
        UUID cashStyle=null;FinancePayrollAccountingPlan.Style cash=null,feeStyle=null;
        if(source.netIncome().signum()>0){
            if(command.accountId()==null||command.bankBookedAt()==null||command.bankReference()==null||command.bankReference().isBlank()||permit.cleanPaymentEvidence().isEmpty())throw invalid("工资实际出款须有明确账户、回单号/签收依据、带时区的实际入账时间和已核验付款凭据");
            if(command.bankBookedAt().toInstant().isAfter(Instant.now())||!command.paymentDate().equals(command.bankBookedAt().atZoneSameInstant(BusinessTime.ZONE).toLocalDate()))throw invalid("实际付款时间与付款日期不一致或尚未发生");
            cashStyle=db.queryForObject("SELECT account_style_id(id) FROM accounts WHERE id=? AND NOT is_deleted AND status='使用'",UUID.class,command.accountId());
            cash=plans.postingStyle(cashStyle,source);if(!"ACCOUNT".equals(cash.category())||!"ASSET".equals(cash.classification())||!(cash.code().startsWith("1001")||cash.code().startsWith("1002")||db.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key='BS_1' AND binding_kind='STYLE' AND style_id=?",Integer.class,cashStyle)>0))throw invalid("工资实际付款账户须明确对应货币资金资产科目");allStyles.add(cashStyle);
            if(fee.signum()>0){feeStyle=plans.postingStyle(command.bankFeeStyleId(),source);if(!"EXPENSE".equals(feeStyle.category()))throw invalid("银行实际手续费须使用明确的费用末级");allStyles.add(feeStyle.id());}
        }else if(command.accountId()!=null||fee.signum()!=0||bankAmount.signum()!=0)throw invalid("原工资实发为零，只能核对真实非现金清偿或无财务事件，不创建零金额资金流水");
        journals.lockStyles(allStyles);
        UUID accrual=plan.reused()?(UUID)plan.priorAccrual().get("voucher_id"):null;
        if(!plan.reused()){
            if(plan.nativeAccrual()){
                var accruedEntries=new ArrayList<FinanceControlledJournalService.Entry>();var deductionBindings=new ArrayList<Binding>();var costIndexes=new LinkedHashMap<FinancePayrollAccountingPlan.Cost,Integer>();
                for(var cost:plan.costs()){costIndexes.put(cost,accruedEntries.size());accruedEntries.add(entry(cost.style(),1,cost.slip().grossIncome(),"原工资部门成本",null,cost.slip().id(),source));}
                appendDeductions(plan,accruedEntries,deductionBindings,"PAYROLL_DEDUCTION_ACCRUAL",source.batchId());
                if(source.netIncome().signum()>0)accruedEntries.add(entry(plan.wage(),-1,source.netIncome(),"原工资应付实发",null,source.batchId(),source));
                var posted=journals.post("GZJT-"+source.batchId(),plan.date(),"PAYROLL_ACCRUAL",source.batchId(),"PAYROLL_ACCRUAL",instruction.sourceReference(),accruedEntries,current.requireId());accrual=posted.voucherId();
                saveAccrual(plan,command.applicationId(),accrual);commit(deductionBindings,posted);
                for(var mapping:costIndexes.entrySet())recordCost(posted.entryIds().get(mapping.getValue()),source,mapping.getKey().slip(),mapping.getKey().style(),null,null);
                for(var part:plan.parts())if(part.reduction()){
                    var cost=plan.costs().stream().filter(c->c.slip().id().equals(part.slip().id())&&c.style().id().equals(part.style().id())).findFirst();
                    if(cost.isPresent()){int index=deductionIndex(plan,part,plan.costs().size());recordCost(posted.entryIds().get(index),source,part.slip(),part.style(),part.itemId(),part.allocationId());}
                }
            }else{accrual=instruction.existingAccrualVoucherId();saveAccrual(plan,command.applicationId(),accrual);}
        }
        FinanceControlledJournalService.Posted payment=null;UUID flow=null,nonCash=null;boolean claimOnly=false;ReceiptKind kind;
        if(source.netIncome().signum()>0||!plan.nativeAccrual()&&instruction.existingLiabilityBasis()==ExistingLiabilityBasis.GROSS_BEFORE_DEDUCTIONS&&source.grossIncome().signum()>0){
            if(plan.nativeAccrual()){
                UUID wageEntry=db.queryForObject("SELECT id FROM gl_entries WHERE voucher_id=? AND style_id=? AND direction=-1 AND NOT is_deleted ORDER BY line_no LIMIT 1",UUID.class,accrual,plan.wage().id());
                int index=entries.size();entries.add(entry(plan.wage(),1,source.netIncome(),"原工资实发支付",null,source.batchId(),source));
                bindings.addAll(reserveWages(source,command.paymentDate(),attempt,List.of(new Wage(plan.wage(),null,new FinanceGlSettlementCapacityPort.SourceRef(wageEntry,1),source.netIncome(),index))));
            }else{
                var wages=new ArrayList<Wage>();for(var liability:plan.liabilities()){
                    int index=entries.size();entries.add(entry(liability.style(),1,liability.amount(),"原工资负债清偿",liability.auxiliary(),liability.source().entryId(),source));
                    wages.add(new Wage(liability.style(),liability.auxiliary(),new FinanceGlSettlementCapacityPort.SourceRef(liability.source().entryId(),liability.source().allocationNo()),liability.amount(),index));
                }bindings.addAll(reserveWages(source,command.paymentDate(),attempt,wages));
                if(instruction.existingLiabilityBasis()==ExistingLiabilityBasis.GROSS_BEFORE_DEDUCTIONS)appendDeductions(plan,entries,bindings,"PAYROLL_DEDUCTION_PAYMENT",attempt);
            }
            if(fee.signum()>0)entries.add(entry(feeStyle,1,fee,"工资付款实际银行手续费",null,attempt,source));
            if(source.netIncome().signum()>0)entries.add(entry(cash,-1,bankAmount,"工资实际银行扣款",null,attempt,source));
            payment=journals.post("GZZF-"+attempt,command.paymentDate(),"PAYROLL_PAYMENT",attempt,"PAYROLL_PAYMENT",command.bankReference(),entries,current.requireId());commit(bindings,payment);
            if(source.netIncome().signum()>0){
                var account=bank.lockActive(command.accountId(),"工资实际付款账户");if(!account.baseCurrency()||!source.currencyId().equals(account.currencyId())||!Objects.equals(cashStyle,account.styleId()))throw conflict("付款账户会计身份或本位币已变化，本次未记账");
                flow=bank.post(account,AccountPosting.out("PAYROLL_PAYMENT",attempt,"GZZF-"+attempt,command.accountId()).rule(AccountPosting.CurrencyRule.BASE_ONLY,source.currencyId()).amounts(bankAmount,bankAmount).bookedAt(command.bankBookedAt()).settledAt(OffsetDateTime.now()).checkNo(command.bankReference()).counterpart("原工资批次 "+source.period()).actor(current.requireId()).label("工资付款账户")).flowId();kind=ReceiptKind.BANK_PAYMENT;
            }else{nonCash=payment.voucherId();kind=ReceiptKind.NON_CASH_CLEARED;}
        }else if(source.grossIncome().signum()>0){kind=ReceiptKind.NON_CASH_CLEARED;nonCash=accrual;claimOnly=true;if(nonCash==null)throw conflict("原零实发工资缺少明确的真实非现金凭证");}
        else{kind=ReceiptKind.NO_FINANCIAL_EVENT;claimOnly=true;}
        OffsetDateTime now=OffsetDateTime.now();String state=kind==ReceiptKind.BANK_PAYMENT?"POSTED_PENDING_CONFIRMATION":kind.name();UUID paymentVoucher=kind==ReceiptKind.BANK_PAYMENT?payment.voucherId():null;
        db.update("""
            INSERT INTO finance_payroll_payment_attempts(id,request_id,application_id,batch_id,payload_fingerprint,source_fingerprint,instruction_fingerprint,
              accrual_voucher_id,source_snapshot,instruction_snapshot,account_id,payment_date,bank_reference,net_amount,fee_amount,bank_amount,fee_style_id,
              payment_voucher_id,non_cash_voucher_id,receipt_kind,source_claim_only,account_flow_id,state,evidence_snapshot,paid_at,paid_by,bank_booked_at)
            VALUES(?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?,?,?)
            """,attempt,command.requestId(),command.applicationId(),source.batchId(),payload,source.fingerprint(),command.instructionFingerprint(),accrual,plans.encode(source),plans.encode(instruction),kind==ReceiptKind.BANK_PAYMENT?command.accountId():null,command.paymentDate(),command.bankReference(),source.netIncome(),fee,bankAmount,command.bankFeeStyleId(),paymentVoucher,nonCash,kind.name(),claimOnly,flow,state,plans.encode(permit.cleanPaymentEvidence()),now,current.requireId(),command.bankBookedAt());
        return result(db.queryForMap("SELECT * FROM finance_payroll_payment_attempts WHERE id=?",attempt));
    }
    @Override @Transactional(readOnly=true) public Optional<Result> result(UUID applicationId){
        current.requireId();var rows=db.queryForList("SELECT * FROM finance_payroll_payment_attempts WHERE application_id=? ORDER BY (state<>'REVERSED') DESC,paid_at DESC,id DESC LIMIT 1",applicationId);return rows.isEmpty()?Optional.empty():Optional.of(result(rows.getFirst()));
    }
    @Override @Transactional public Result confirm(UUID applicationId,UUID requestId,UUID expectedVoucher){
        var header=attempt(applicationId,false);sources.read((UUID)header.get("batch_id"),true);requestLock(requestId);String fingerprint=plans.hash(Arrays.asList("CONFIRM",applicationId,expectedVoucher));
        var replay=action(requestId,fingerprint);if(replay!=null)return replay;
        authority.requirePayrollConfirmation(applicationId,(UUID)header.get("batch_id"),expectedVoucher);tx.bind();var row=attempt(applicationId,true);expected(row,expectedVoucher);
        if("REVERSED".equals(row.get("state")))throw conflict("原工资办理回执已经反审");if(!"CONFIRMED".equals(row.get("state")))db.update("UPDATE finance_payroll_payment_attempts SET state='CONFIRMED',confirmed_at=now(),confirmed_by=? WHERE id=?",current.requireId(),row.get("id"));
        Result result=result(db.queryForMap("SELECT * FROM finance_payroll_payment_attempts WHERE id=?",row.get("id")));saveAction(requestId,applicationId,row,"CONFIRM",fingerprint,result);return result;
    }
    @Override @Transactional public Result reverse(Reverse command){
        if(command==null||command.requestId()==null)throw invalid("请保留原工资反审请求编号");var header=attempt(command.applicationId(),false);sources.read((UUID)header.get("batch_id"),true);requestLock(command.requestId());String fingerprint=plans.hash(command);
        var replay=action(command.requestId(),fingerprint);if(replay!=null)return replay;
        authority.requirePayrollReversal(command.applicationId(),(UUID)header.get("batch_id"),command);FinancePayrollAccountingPlan.reference(command.reason());tx.bind();var row=attempt(command.applicationId(),true);expected(row,command.expectedClearingVoucherId());
        if("REVERSED".equals(row.get("state")))throw conflict("这笔原工资办理已反审，请核对原反审回执");
        PaymentStyleHierarchyLock.lock(em);LocalDate date=BusinessTime.today();periods.lockAutoProjectionPeriod(date);UUID reversal=null;
        if(!Boolean.TRUE.equals(row.get("source_claim_only"))){
            UUID original=(UUID)("BANK_PAYMENT".equals(row.get("receipt_kind"))?row.get("payment_voucher_id"):row.get("non_cash_voucher_id"));
            if("BANK_PAYMENT".equals(row.get("receipt_kind")))bank.requireReversible("PAYROLL_PAYMENT",(UUID)row.get("id"));
            var posted=journals.reverse(original,"GZZF-REV-"+row.get("id"),date,"PAYROLL_PAYMENT_REV",(UUID)row.get("id"),"PAYROLL_PAYMENT_REV",command.reason(),current.requireId());reversal=posted.voucherId();
            var reservations=db.queryForList("SELECT id,owner_kind FROM finance_gl_settlement_reservations WHERE owner_id=? AND owner_kind IN('PAYROLL_WAGE_PAYMENT','PAYROLL_DEDUCTION_PAYMENT') AND status='COMMITTED' ORDER BY id",row.get("id"));
            for(var reservation:reservations){var clears=db.queryForList("SELECT c.entry_id,c.allocation_no,e.line_no FROM finance_gl_settlement_clearings c JOIN gl_entries e ON e.id=c.entry_id WHERE c.reservation_id=? ORDER BY c.line_no",reservation.get("id"));var links=new ArrayList<FinanceGlSettlementCapacityPort.Reversal>();
                for(var clear:clears)links.add(new FinanceGlSettlementCapacityPort.Reversal(posted.entryIds().get(((Number)clear.get("line_no")).intValue()-1),((Number)clear.get("allocation_no")).intValue(),(UUID)clear.get("entry_id"),((Number)clear.get("allocation_no")).intValue()));
                capacity.release(new FinanceGlSettlementCapacityPort.Release(stable("PAYROLL_RELEASE",command.requestId(),(UUID)reservation.get("id")),owner(reservation.get("owner_kind").toString(),(UUID)row.get("id")),(UUID)reservation.get("id"),links,command.reason()));
            }
            if("BANK_PAYMENT".equals(row.get("receipt_kind")))bank.reverse("PAYROLL_PAYMENT",(UUID)row.get("id"),OffsetDateTime.now(),command.reason());
        }
        db.update("UPDATE finance_payroll_payment_attempts SET state='REVERSED',reversal_voucher_id=?,reversed_at=now(),reversed_by=? WHERE id=?",reversal,current.requireId(),row.get("id"));
        Result result=result(db.queryForMap("SELECT * FROM finance_payroll_payment_attempts WHERE id=?",row.get("id")));saveAction(command.requestId(),command.applicationId(),row,"REVERSE",fingerprint,result);return result;
    }
    private record Clear(int index,FinanceGlSettlementCapacityPort.SourceRef source) { }
    private record Binding(UUID reservation,String kind,UUID owner,List<Clear> clearings) { }
    private record Wage(FinancePayrollAccountingPlan.Style style,FinancialAuxiliaryValidationPort.Ref auxiliary,FinanceGlSettlementCapacityPort.SourceRef source,BigDecimal amount,int index) { }
    private void appendDeductions(FinancePayrollAccountingPlan.Plan plan,List<FinanceControlledJournalService.Entry> entries,List<Binding> bindings,String kind,UUID owner){
        var grouped=new LinkedHashMap<String,List<Wage>>();
        for(var part:plan.parts()){
            int index=entries.size();entries.add(entry(part.style(),part.reduction()?1:-1,part.reduction()?part.amount().negate():part.amount(),"原工资扣款："+part.purpose(),part.auxiliary(),part.itemId(),plan.source()));
            if(part.purpose()==DeductionPurpose.EMPLOYEE_SETTLEMENT){boolean pool="GL_AUXILIARY_BALANCE_POOL".equals(part.original().kind());var ref=pool?null:new FinanceGlSettlementCapacityPort.SourceRef(part.original().sourceId(),part.original().allocationNo());
                grouped.computeIfAbsent(part.style().id()+":"+part.auxiliary().auxiliaryId()+":"+pool,k->new ArrayList<>()).add(new Wage(part.style(),part.auxiliary(),ref,part.amount(),index));}
        }
        for(var group:grouped.values())bindings.add(reserve(plan.source(),plan.date(),kind,owner,group,1));
    }
    private List<Binding> reserveWages(Source source,LocalDate date,UUID owner,List<Wage> lines){var groups=new LinkedHashMap<String,List<Wage>>();for(var line:lines){groups.computeIfAbsent(line.style().id()+":"+(line.auxiliary()==null?null:line.auxiliary().auxiliaryId()),k->new ArrayList<>()).add(line);}var out=new ArrayList<Binding>();for(var group:groups.values()){out.add(reserve(source,date,"PAYROLL_WAGE_PAYMENT",owner,group,-1));}return out;}
    private Binding reserve(Source source,LocalDate date,String kind,UUID owner,List<Wage> group,int direction){
        var first=group.getFirst();var scope=new FinanceGlSettlementCapacityPort.Scope(first.style().id(),first.style().code(),first.auxiliary()==null?null:first.auxiliary().auxiliaryId(),first.style().currencyId(),source.currencyId(),direction,date);
        boolean pool=first.source()==null;var mode=pool?FinanceGlSettlementCapacityPort.Mode.AUXILIARY_BALANCE_POOL:first.auxiliary()==null?FinanceGlSettlementCapacityPort.Mode.CONFIRMED_AGGREGATE_LIABILITY:FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE;
        var portions=new LinkedHashMap<FinanceGlSettlementCapacityPort.SourceRef,BigDecimal>();for(var line:group)if(line.source()!=null)portions.merge(line.source(),line.amount(),BigDecimal::add);
        var preview=capacity.preview(scope,mode,new ArrayList<>(portions.keySet()));if(!preview.ready())throw conflict(preview.issues().stream().map(FinanceGlSettlementCapacityPort.Issue::message).reduce((a,b)->a+"；"+b).orElse("原工资清偿来源待核对"));
        BigDecimal amount=group.stream().map(Wage::amount).reduce(BigDecimal.ZERO,BigDecimal::add);var requested=portions.entrySet().stream().map(e->new FinanceGlSettlementCapacityPort.SourceAmount(e.getKey(),e.getValue(),e.getValue())).toList();
        UUID request=stable(kind,owner,UUID.nameUUIDFromBytes((first.style().id()+":"+scope.auxiliaryId()+":"+pool).getBytes(StandardCharsets.UTF_8)));
        var receipt=capacity.reserve(new FinanceGlSettlementCapacityPort.Reservation(request,owner(kind,owner),scope,mode,preview.fingerprint(),amount,amount,requested,"按本批原工资逐项目明确的真实清偿份额"));
        return new Binding(receipt.reservationId(),kind,owner,group.stream().map(w->new Clear(w.index(),w.source())).toList());
    }
    private void commit(List<Binding> bindings,FinanceControlledJournalService.Posted posted){for(var binding:bindings)capacity.commit(new FinanceGlSettlementCapacityPort.Commit(stable("PAYROLL_COMMIT",binding.owner(),binding.reservation()),owner(binding.kind(),binding.owner()),binding.reservation(),binding.clearings().stream().map(c->new FinanceGlSettlementCapacityPort.Clearing(posted.entryIds().get(c.index()),1,c.source())).toList()));}
    private FinanceControlledJournalService.Entry entry(FinancePayrollAccountingPlan.Style style,int direction,BigDecimal amount,String label,FinancialAuxiliaryValidationPort.Ref ref,UUID sourceId,Source source){return new FinanceControlledJournalService.Entry(style.id(),direction,amount,label,new FinanceControlledJournalService.Allocation(style.code(),style.currencyId(),ref,sourceId.toString(),1,"{}",source.currencyId(),amount,BigDecimal.ONE));}
    private void saveAccrual(FinancePayrollAccountingPlan.Plan plan,UUID application,UUID voucher){var s=plan.source();db.update("INSERT INTO finance_payroll_accruals(batch_id,application_id,source_fingerprint,instruction_fingerprint,mode,voucher_id,wage_style_id,gross_amount,deduction_amount,net_amount,source_snapshot,instruction_snapshot,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?)",s.batchId(),application,s.fingerprint(),plan.fingerprint(),plan.instruction().mode().name(),voucher,plan.wage()==null?null:plan.wage().id(),s.grossIncome(),s.totalDeduction(),s.netIncome(),plans.encode(s),plans.encode(plan.instruction()),current.requireId());}
    private int deductionIndex(FinancePayrollAccountingPlan.Plan plan,FinancePayrollAccountingPlan.Part part,int start){return start+plan.parts().indexOf(part);}
    private void recordCost(UUID entry,Source source,Slip slip,FinancePayrollAccountingPlan.Style style,UUID item,UUID allocation){db.update("INSERT INTO finance_payroll_accrual_lines(entry_id,batch_id,payroll_slip_id,employee_id,department_id,source_payroll_period,expense_style_id,created_by,amount_kind,source_payroll_item_id,deduction_allocation_id) VALUES(?,?,?,?,?,?,?,?,?,?,?)",entry,source.batchId(),slip.id(),slip.employeeId(),slip.departmentId(),source.period(),style.id(),current.requireId(),item==null?"GROSS":"REDUCTION",item,allocation);}
    private Map<String,Object> attempt(UUID app,boolean lock){var rows=db.queryForList("SELECT * FROM finance_payroll_payment_attempts WHERE application_id=? ORDER BY (state<>'REVERSED') DESC,paid_at DESC,id DESC LIMIT 1"+(lock?" FOR UPDATE":""),app);if(rows.size()!=1)throw conflict("原工资办理回执不存在，请核对原请求");return rows.getFirst();}
    private void expected(Map<String,Object> row,UUID expected){UUID actual=(UUID)("NON_CASH_CLEARED".equals(row.get("receipt_kind"))?row.get("non_cash_voucher_id"):row.get("payment_voucher_id"));if(!Objects.equals(actual,expected))throw conflict("原工资付款/非现金凭证与请求不一致");if(actual!=null&&db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE id=? AND status=1 AND NOT is_deleted AND reversed_by_voucher_id IS NULL",Integer.class,actual)!=1)throw conflict("原工资凭证已变化，不能确认或反审其他事实");}
    private Result action(UUID request,String fingerprint){var rows=db.queryForList("SELECT fingerprint,result::text,actor_id FROM finance_payroll_payment_actions WHERE request_id=?",request);if(rows.isEmpty())return null;if(!current.requireId().equals(rows.getFirst().get("actor_id"))||!fingerprint.equals(rows.getFirst().get("fingerprint")))throw conflict("原工资动作编号已有不同内容或办理人");return decodeResult(rows.getFirst().get("result").toString());}
    private void saveAction(UUID request,UUID app,Map<String,Object> payment,String action,String fingerprint,Result result){db.update("INSERT INTO finance_payroll_payment_actions(request_id,application_id,payment_request_id,action,actor_id,fingerprint,result) VALUES(?,?,?,?,?,?,?::jsonb)",request,app,payment.get("request_id"),action,current.requireId(),fingerprint,plans.encode(result));}
    private Result decodeResult(String raw){return plans.result(raw);}
    private Result result(Map<String,Object> row){Object raw=row.get("paid_at");OffsetDateTime paid=raw instanceof OffsetDateTime value?value:raw instanceof java.sql.Timestamp stamp?stamp.toInstant().atOffset(ZoneOffset.UTC):OffsetDateTime.parse(raw.toString());return new Result((UUID)row.get("application_id"),(UUID)row.get("batch_id"),(UUID)row.get("id"),(UUID)row.get("request_id"),(UUID)row.get("accrual_voucher_id"),(UUID)row.get("payment_voucher_id"),(UUID)row.get("non_cash_voucher_id"),(UUID)row.get("account_flow_id"),row.get("state").toString(),ReceiptKind.valueOf(row.get("receipt_kind").toString()),Boolean.TRUE.equals(row.get("source_claim_only")),(BigDecimal)row.get("net_amount"),(BigDecimal)row.get("fee_amount"),(BigDecimal)row.get("bank_amount"),paid,(UUID)row.get("paid_by"));}
    private FinanceGlSettlementCapacityPort.Owner owner(String kind,UUID id){return new FinanceGlSettlementCapacityPort.Owner(kind,id,current.requireId());}
    private void requestLock(UUID request){if(request==null)throw invalid("请保留原动作请求编号");db.query("SELECT pg_advisory_xact_lock(hashtextextended(?::text,0))",rs->{},"uten:payroll-payment:"+request);}
    private static UUID stable(String kind,UUID first,UUID second){return UUID.nameUUIDFromBytes((kind+":"+first+":"+second).getBytes(StandardCharsets.UTF_8));}
    private static BigDecimal amount(String text,String label){return FinancePayrollAccountingPlan.amount(text,label);}
    private static ApiException invalid(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
    private static ApiException conflict(String text){return new ApiException(ErrorCode.CONFLICT,text);}
}
