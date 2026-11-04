package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.*;
import com.uten.imp.common.finance.AccountingExpensePurpose;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.expense.dto.*;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

/** One transaction over the existing source, cash ledger and GL. Workflow stores identities, never duplicate balances. */
@Service @RequiredArgsConstructor
public class FinanceApplicationExecutionService implements FinanceApplicationExecutionPort {
    private final FinanceApplicationLegacyPolicy legacy;private final FinanceApplicationService applications;private final FinanceApplicationRoles roles;private final JdbcTemplate db;
    private final SecurityContextCurrentUser current;private final TxSessionVars tx;private final FinanceApplicationControlPort controls;
    private final FinanceApplicationExpensePort claims;private final FinanceExpenseService expenses;private final FinancePaymentService payments;
    private final ObjectProvider<FinancePayrollPaymentPort> payroll;private final FinanceApplicationNoticePort notices;

    @Override @Transactional
    public Map<String,Object> execute(UUID id,Execute command){roles.live(FinanceApplicationPermissions.EXECUTE);tx.bind();return applications.operation(id,command.requestId(),"EXECUTE",command,()->{
        var app=applications.lockSourceAndRow(id);legacy.requireRound(app);applications.version(app,command.expectedVersion());applications.fresh(app,command.sourceFingerprint());
        if(!"APPROVED".equals(app.get("status"))||"TRAVEL_APPLICATION".equals(app.get("kind")))throw conflict("原申请尚未批准支付或已经登记，不能重复付款");
        legacy.requireUninvolvedPayer(app,current.requireEmployeeId());
        boolean zeroPayroll="PAYROLL_BATCH".equals(app.get("source_kind"))&&app.get("amount_original") instanceof BigDecimal net&&net.signum()==0;
        if(!zeroPayroll&&command.accountId()==null)throw invalid("请选择实际付款账户");LocalDate date=FinanceApplicationService.date(command.paymentDate(),zeroPayroll?"清偿/核对日期":"实际付款日期");if(date.isAfter(com.uten.imp.common.time.BusinessTime.today()))throw invalid("办理日期不能晚于今天");
        var proofs=db.queryForList("SELECT id,sha256,original_name FROM attachments WHERE owner_type='FINANCE_APPLICATION_PAYMENT_PROOF' AND owner_id=? AND lifecycle_state='CLEAN' AND delete_requested_at IS NULL AND sha256 IS NOT NULL ORDER BY id FOR SHARE",id);if(!zeroPayroll&&proofs.isEmpty())throw invalid("请先上传本申请的银行付款回单或现金签收凭据并完成安全核验");
        BigDecimal bank=zeroPayroll&&command.bankAmount()==null?BigDecimal.ZERO:amount(command.bankAmount(),"实际账户扣款"),fee=zeroPayroll&&command.bankFee()==null?BigDecimal.ZERO:amount(command.bankFee(),"银行手续费");if(zeroPayroll?(bank.signum()!=0||fee.signum()!=0):bank.signum()<=0||fee.signum()<0)throw invalid(zeroPayroll?"原工资实发为0，本次只能按真实非现金清偿或已核对无资金事件办理":"实际账户扣款应大于0，手续费不能小于0");
        String reference=FinanceApplicationService.text(command.bankReference(),128,"银行流水号/签收依据");OffsetDateTime booked=null;
        if(!zeroPayroll){if(reference.isBlank())throw invalid("请填写实际银行流水号或现金签收依据");try{booked=OffsetDateTime.parse(command.bankBookedAt());}catch(Exception e){throw invalid("请填写带时区的实际到账/付讫时间");}if(booked.toInstant().isAfter(Instant.now()))throw invalid("实际付款时间不能晚于当前时间");if(!booked.atZoneSameInstant(com.uten.imp.common.time.BusinessTime.ZONE).toLocalDate().equals(date))throw invalid("实际付款时间与付款日期不一致，请按回单核对");}
        String type;UUID doc;Map<String,Object> result=new LinkedHashMap<>();
        if("PAYROLL_BATCH".equals(app.get("source_kind"))){var bridge=payroll.getIfAvailable();if(bridge==null)throw conflict("原工资事实桥尚未准备好");var paid=bridge.execute(new FinancePayrollPaymentPort.Execute(command.requestId(),id,(UUID)app.get("source_id"),command.sourceFingerprint(),Objects.toString(app.get("payroll_instruction_fingerprint"),null),command.accountId(),date,reference,bank.toPlainString(),fee.toPlainString(),command.bankFeeStyleId(),booked));type="PAYROLL_PAYMENT";doc=paid.paymentId();result=applications.decode(applications.encode(paid));insert(id,app,command,type,doc,result);
        }else if("EXPENSE_CLAIM".equals(app.get("source_kind"))){
            roles.require(roles.staff(),"expense:pay");if(command.expenseStyleId()==null)throw invalid("请明确原报销支出科目");BigDecimal net=(BigDecimal)app.get("amount_original");if(fee.signum()!=0||bank.compareTo(net)!=0)throw invalid("原报销执行按已批准原额支付；银行扣款须与原报销额一致，手续费须另按真实费用申请办理");
            UUID source=(UUID)app.get("source_id");doc=NativeApplicationContext.call(new NativeApplicationContext.Value(id,source,NativeApplicationContext.Action.PAY),()->claims.pay(source,command.accountId(),command.expenseStyleId(),date,AccountingExpensePurpose.parse(command.postingPurpose())));type="EXPENSE";result.put("claimId",source);result.put("financeExpenseId",doc);insert(id,app,command,type,doc,result);
        }else{
            var payload=applications.decode(app.get("requested_payload").toString());String nature=payload.get("paymentNature").toString();
            if(nature.equals("GENERAL_EXPENSE")){
                var request=new FinanceExpenseSaveRequest();request.setBillDate(date);request.setAccountId(command.accountId());request.setCurrencyId((UUID)app.get("currency_id"));request.setExchangeRate(BigDecimal.ONE);request.setOperatorId(current.requireEmployeeId());request.setRemark("申请 "+app.get("application_no")+"；"+reference);
                BigDecimal net=(BigDecimal)app.get("amount_original");if(bank.compareTo(net.add(fee))!=0)throw invalid("本位币费用实际扣款应等于原申请合计加明确手续费");
                List<FinanceExpenseItemInput> items=new ArrayList<>();for(Object raw:(List<?>)payload.get("lines")){var line=(Map<?,?>)raw;var item=new FinanceExpenseItemInput();item.setLineNo(items.size()+1);item.setExpenseStyleId(line.get("expenseStyleId")==null?command.expenseStyleId():UUID.fromString(line.get("expenseStyleId").toString()));if(item.getExpenseStyleId()==null)throw invalid("请明确每条原费用的支出科目");item.setPostingPurpose(command.postingPurpose());item.setDepartmentId((UUID)app.get("department_id"));item.setQty(BigDecimal.ONE);item.setPrice(amount(line.get("amountOriginal").toString(),"原申请金额"));item.setAmountOriginal(item.getPrice());item.setSummary(Objects.toString(line.get("label"),""));items.add(item);}
                if(fee.signum()!=0){if(command.bankFeeStyleId()==null)throw invalid("请明确银行手续费科目");var item=new FinanceExpenseItemInput();item.setLineNo(items.size()+1);item.setExpenseStyleId(command.bankFeeStyleId());item.setPostingPurpose("ORDINARY_EXPENSE");item.setQty(BigDecimal.ONE);item.setPrice(fee);item.setAmountOriginal(fee);item.setSummary("银行手续费");items.add(item);}request.setItems(items);
                type="EXPENSE";doc=NativeApplicationContext.call(new NativeApplicationContext.Value(id,id,NativeApplicationContext.Action.POST_EXPENSE),()->{controls.requireNativeCreation("EXPENSE");return expenses.create(request).getId();});insert(id,app,command,type,doc,result);UUID nativeId=doc;NativeApplicationContext.run(new NativeApplicationContext.Value(id,doc,NativeApplicationContext.Action.POST_EXPENSE),()->expenses.approve(nativeId));
            }else{
                var request=new FinancePaymentSaveRequest();request.setCreateIdempotencyKey("finance-application:"+command.requestId());request.setBillDate(date);request.setSupplierId(UUID.fromString(payload.get("supplierId").toString()));request.setAccountId(command.accountId());request.setCurrencyId((UUID)app.get("currency_id"));request.setExchangeRate(amount(command.exchangeRate(),"原币汇率"));request.setAccountAmount(bank);request.setBankFeeAccountAmount(fee);request.setBankReference(reference);request.setBankBookedAt(booked);request.setSourceRemark("申请 "+app.get("application_no"));request.setRemark(Objects.toString(app.get("remark"),""));
                List<FinancePaymentLineInput> items=new ArrayList<>();if(nature.equals("SUPPLIER_PREPAYMENT"))request.setAmountOriginal((BigDecimal)app.get("amount_original"));else for(Object raw:(List<?>)payload.get("lines")){var line=(Map<?,?>)raw;var item=new FinancePaymentLineInput();item.setLineNo(items.size()+1);item.setAppliedLedgerId(UUID.fromString(line.get("appliedLedgerId").toString()));item.setAmountOriginal(amount(line.get("amountOriginal").toString(),"原应付金额"));item.setRemark(Objects.toString(line.get("label"),""));items.add(item);}request.setItems(items);
                type="PAYMENT";doc=NativeApplicationContext.call(new NativeApplicationContext.Value(id,id,NativeApplicationContext.Action.POST_PAYMENT),()->{controls.requireNativeCreation("PAYMENT");return payments.create(request).getId();});insert(id,app,command,type,doc,result);UUID nativeId=doc;NativeApplicationContext.run(new NativeApplicationContext.Value(id,doc,NativeApplicationContext.Action.POST_PAYMENT),()->payments.approve(nativeId));
            }
        }
        result.put("paymentProofs",proofs);result.put("bankBookedAt",booked==null?null:booked.toString());result.put("bankReference",reference);result.put("bankAmount",bank.toPlainString());result.put("bankFee",fee.toPlainString());if(!type.equals("PAYROLL_PAYMENT"))result.put("paymentVoucherId",voucher(type,doc));
        db.update("UPDATE finance_application_executions SET state='POSTED_PENDING_CONFIRMATION',result=?::jsonb WHERE application_id=? AND request_id=?",applications.encode(result),id,command.requestId());db.update("UPDATE finance_applications SET status='EXECUTED',native_doc_type=?,native_doc_id=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",type,doc,current.requireId(),id);applications.event(id,round(app),"PAYMENT_POSTED",null,Map.of("documentType",type,"documentId",doc));notices.resolve(id,"PAYMENT_POSTED");return applications.detail(id);
    });}

    @Override @Transactional
    public Map<String,Object> confirm(UUID id,Action command){roles.live(FinanceApplicationPermissions.CONFIRM);tx.bind();return applications.operation(id,command.requestId(),"CONFIRM",command,()->{
        var app=applications.lockSourceAndRow(id);legacy.requireRound(app);applications.version(app,command.expectedVersion());if(!"EXECUTED".equals(app.get("status")))throw conflict("只有原已付款待确认分录可财务确认");var execution=execution(id);String type=execution.get("doc_type").toString();UUID doc=(UUID)execution.get("doc_id");
        UUID voucher=voucher(type,doc);if(type.equals("PAYROLL_PAYMENT"))payroll.getObject().confirm(id,command.requestId(),voucher);else if(type.equals("EXPENSE"))NativeApplicationContext.run(new NativeApplicationContext.Value(id,doc,NativeApplicationContext.Action.CONFIRM),()->expenses.glConfirm(doc));else verifyPayment(doc,voucher);
        db.update("UPDATE finance_application_executions SET state='CONFIRMED',confirmed_by=?,confirmed_name_snapshot=?,confirmed_at=now() WHERE id=?",current.requireEmployeeId(),applications.actorName(),execution.get("id"));db.update("UPDATE finance_applications SET status='CONFIRMED',row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);Map<String,Object> event=new LinkedHashMap<>();event.put("documentType",type);event.put("documentId",doc);event.put("voucherId",voucher);applications.event(id,round(app),"PAYMENT_CONFIRMED",null,event);return applications.detail(id);
    });}

    @Override @Transactional
    public Map<String,Object> unconfirm(UUID id,Action command){roles.live(FinanceApplicationPermissions.CONFIRM);tx.bind();return applications.operation(id,command.requestId(),"UNCONFIRM",command,()->{
        var app=applications.lockSourceAndRow(id);legacy.requireRound(app);applications.version(app,command.expectedVersion());if(!"CONFIRMED".equals(app.get("status")))throw conflict("原付款尚未财务确认或已变化");if(Objects.toString(command.reason(),"").strip().length()<4)throw invalid("请填写撤销财务确认的具体原因");var execution=execution(id);String type=execution.get("doc_type").toString();UUID doc=(UUID)execution.get("doc_id");if(type.equals("PAYROLL_PAYMENT"))throw conflict("工资付款保留确认历史并按原支付凭证对称反审，无须撤销确认");if(type.equals("EXPENSE"))NativeApplicationContext.run(new NativeApplicationContext.Value(id,doc,NativeApplicationContext.Action.CONFIRM),()->expenses.unconfirmFromFinancialApplication(doc));else verifyPayment(doc,voucher(type,doc));
        db.update("UPDATE finance_application_executions SET state='POSTED_PENDING_CONFIRMATION' WHERE id=?",execution.get("id"));db.update("UPDATE finance_applications SET status='EXECUTED',row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);applications.event(id,round(app),"PAYMENT_CONFIRMATION_WITHDRAWN",null,Map.of("documentId",doc,"reason",command.reason()));return applications.detail(id);
    });}

    @Override @Transactional
    public Map<String,Object> reverse(UUID id,Action command){roles.live(FinanceApplicationPermissions.REVERSE);tx.bind();return applications.operation(id,command.requestId(),"REVERSE",command,()->{
        var app=applications.lockSourceAndRow(id);legacy.requireRound(app);applications.version(app,command.expectedVersion());if(!Set.of("EXECUTED","CONFIRMED").contains(app.get("status")))throw conflict("只有原实际付款可反审");String reason=FinanceApplicationService.text(command.reason(),1000,"反审原因");if(reason.strip().length()<4)throw invalid("请填写明确反审原因");var execution=execution(id);String type=execution.get("doc_type").toString();UUID doc=(UUID)execution.get("doc_id");
        if("CONFIRMED".equals(app.get("status"))&&!type.equals("PAYROLL_PAYMENT"))throw conflict("原付款已财务确认，请先撤销财务确认，再反审原付款；原确认记录保留");
        if(type.equals("PAYROLL_PAYMENT"))payroll.getObject().reverse(new FinancePayrollPaymentPort.Reverse(command.requestId(),id,voucher(type,doc),reason));else if(type.equals("PAYMENT"))NativeApplicationContext.run(new NativeApplicationContext.Value(id,doc,NativeApplicationContext.Action.REVERSE),()->payments.reverse(doc));else{NativeApplicationContext.run(new NativeApplicationContext.Value(id,doc,NativeApplicationContext.Action.REVERSE),()->expenses.reverse(doc));if("EXPENSE_CLAIM".equals(app.get("source_kind")))NativeApplicationContext.run(new NativeApplicationContext.Value(id,(UUID)app.get("source_id"),NativeApplicationContext.Action.REVERSE),()->claims.paymentReversed((UUID)app.get("source_id"),doc,reason));}
        db.update("UPDATE finance_application_executions SET state='REVERSED',reversed_by=?,reversed_name_snapshot=?,reversed_at=now() WHERE id=?",current.requireEmployeeId(),applications.actorName(),execution.get("id"));db.update("UPDATE finance_applications SET status='REVERSED',native_doc_type=NULL,native_doc_id=NULL,payroll_instruction=NULL,payroll_instruction_fingerprint=NULL,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);applications.event(id,round(app),"PAYMENT_REVERSED",null,Map.of("documentType",type,"documentId",doc,"reason",reason));return applications.detail(id);
    });}

    private void insert(UUID id,Map<String,Object> app,Execute command,String type,UUID doc,Map<String,Object> result){db.update("INSERT INTO finance_application_executions(application_id,submission_round,request_id,doc_type,doc_id,state,result,paid_by,paid_name_snapshot) VALUES(?,?,?,?,?,'PREPARING',?::jsonb,?,?)",id,app.get("submission_round"),command.requestId(),type,doc,applications.encode(result),current.requireEmployeeId(),applications.actorName());}
    private Map<String,Object> execution(UUID id){var rows=db.queryForList("SELECT * FROM finance_application_executions WHERE application_id=? AND state IN('POSTED_PENDING_CONFIRMATION','CONFIRMED') FOR UPDATE",id);if(rows.size()!=1)throw conflict("原付款回执不存在或不唯一，请核对，不能重新扣款");return rows.getFirst();}
    private UUID voucher(String type,UUID doc){if(type.equals("PAYROLL_PAYMENT")){var ids=db.queryForList("SELECT application_id FROM finance_application_executions WHERE doc_type='PAYROLL_PAYMENT' AND doc_id=?",UUID.class,doc);if(ids.size()!=1)throw conflict("原工资付款身份缺失");var result=payroll.getObject().result(ids.getFirst()).orElseThrow(()->conflict("原工资办理回执缺失"));UUID actual=result.receiptKind()==FinancePayrollPaymentPort.ReceiptKind.NON_CASH_CLEARED?result.nonCashVoucherId():result.paymentVoucherId();if(!doc.equals(result.paymentId())||(actual==null&&result.receiptKind()!=FinancePayrollPaymentPort.ReceiptKind.NO_FINANCIAL_EVENT))throw conflict("原工资清偿/付款凭证缺失或身份不一致");return actual;}var rows=db.queryForList("SELECT id FROM gl_vouchers WHERE source_doc_id=? AND source_type=? AND status=1 AND NOT is_deleted",UUID.class,doc,type);if(rows.size()!=1)throw conflict("原付款总账凭证缺失或重复");return rows.getFirst();}
    private void verifyPayment(UUID doc,UUID voucher){roles.require(roles.staff(),"finance_payment:view");int valid=db.queryForObject("SELECT count(*) FROM gl_vouchers v JOIN finance_payments p ON p.id=v.source_doc_id WHERE v.id=? AND p.id=? AND p.status=1 AND p.amount_authority_version=2 AND NOT p.is_deleted AND v.status=1 AND NOT v.is_deleted AND (SELECT count(*) FROM gl_entries e WHERE e.voucher_id=v.id AND NOT e.is_deleted)>=2 AND (SELECT sum(e.amount*e.direction) FROM gl_entries e WHERE e.voucher_id=v.id AND NOT e.is_deleted)=0",Integer.class,voucher,doc);if(valid!=1)throw conflict("原采购付款/平衡分录无法核对，不能财务确认");}
    private static int round(Map<String,Object> app){return ((Number)app.get("submission_round")).intValue();}
    private static BigDecimal amount(String raw,String label){try{return FinancialExactAmount.require(new BigDecimal(raw),label);}catch(NullPointerException|NumberFormatException e){throw invalid(label+"必须是有效十进制原文");}}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
