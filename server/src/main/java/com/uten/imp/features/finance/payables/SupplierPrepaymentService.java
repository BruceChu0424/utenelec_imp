package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.FinanceControlledJournalService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.accountflow.AccountPosting;
import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;

/** Positive supplier advance assets tied to one real bank payment, never a fabricated AP credit. */
@Service @RequiredArgsConstructor
public class SupplierPrepaymentService implements SupplierPrepaymentPort {
    @org.springframework.beans.factory.annotation.Autowired private NativeFinancialPostingAccountPort nativeAccounts;
    @org.springframework.beans.factory.annotation.Autowired private FinancePayableClassificationPort payableClassifications;
    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinancialAuxiliaryValidationPort auxiliaries;
    private final FinancialChartCurrencyReadPort chartCurrencies;
    private final FinanceControlledJournalService journals;
    private final GlPostingService periods;
    private final SupplierClosedPeriodGuard closed;
    private final SupplierPayableHoldGuard holds;
    private final FinanceDocumentAccessPolicy access;
    private final AccountFlowLedgerService bank;
    private final FinanceGlSettlementCapacityPort capacity;
    private final FinanceSupplierSettlementDependencies dependencies;

    public record Category(String category,BigDecimal amountOriginal,BigDecimal amountLocal) { }
    public record Classify(String sourceReference,List<Category> parts) { }
    public record Apply(UUID requestId,UUID payableId,String sourceCategory,String targetCategory,
            BigDecimal amountOriginal,String sourceReference) { }
    public record Refund(UUID requestId,String sourceCategory,BigDecimal amountOriginal,UUID accountId,
            UUID accountCurrencyId,BigDecimal bankAmount,BigDecimal bankRate,BigDecimal bankFeeAmount,
            String bankReference,OffsetDateTime bankBookedAt,String sourceReference) { }
    private record Account(UUID style,String code,UUID currency,FinancialAuxiliaryValidationPort.Ref auxiliary) { }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public UUID assetStyle(UUID supplierId,UUID originalCurrencyId) {
        if(supplierId==null||originalCurrencyId==null)throw invalid("供应商预付必须选择供应商和真实原币");
        return account("SUPPLIER_PREPAYMENT_ASSET",supplierId,originalCurrencyId,BusinessTime.today()).style();
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void recognize(UUID paymentId) {
        tx.bind();var payment=payment(paymentId);
        if(number(payment,"amount_authority_version")!=2||number(payment,"status")!=1
                ||Boolean.TRUE.equals(payment.get("is_deleted"))||count("SELECT count(*) FROM finance_payment_lines WHERE payment_id=? AND NOT is_deleted",paymentId)!=0)
            throw conflict("预付资产只接受已审核的真实V2无应付明细付款");
        var account=account("SUPPLIER_PREPAYMENT_ASSET",(UUID)payment.get("supplier_id"),(UUID)payment.get("currency_id"),date(payment.get("bill_date")));
        if(!account.style().equals(payment.get("gl_ap_style_id")))throw conflict("预付资产科目已变化，请重新核对原付款");
        var existing=db.queryForList("SELECT * FROM finance_supplier_advances WHERE payment_id=?",paymentId);
        if(!existing.isEmpty())return;
        db.update("""
            INSERT INTO finance_supplier_advances(payment_id,supplier_id,currency_id,style_id,account_code,accounting_currency_id,
              auxiliary_id,auxiliary_snapshot,amount_original,amount_local,effective_date,created_by)
            VALUES(?,?,?,?,?,?,?,?::jsonb,?,?,?,?)
            """,paymentId,payment.get("supplier_id"),payment.get("currency_id"),account.style(),account.code(),account.currency(),account.auxiliary().auxiliaryId(),
                encode(account.auxiliary()),payment.get("amount_original"),payment.get("amount_local"),payment.get("bill_date"),current.requireId());
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void posted(UUID paymentId) {
        var advance=advance(paymentId,true);
        var entries=db.queryForList("""
            SELECT e.id,e.amount FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
            WHERE v.source='AUTO' AND v.source_type='PAYMENT' AND v.source_doc_id=? AND v.status=1
              AND NOT v.is_deleted AND e.line_no=1 AND NOT e.is_deleted AND e.direction=1 AND e.style_id=?
            """,paymentId,advance.get("style_id"));
        if(entries.size()!=1||decimal(entries.getFirst(),"amount").compareTo(decimal(advance,"amount_local"))!=0)
            throw conflict("预付资产与原付款GL不一致，本次付款未完成");
        attach((UUID)entries.getFirst().get("id"),advance,decimal(advance,"amount_original"),"PAYMENT:"+paymentId);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=ApiException.class)
    public void requireReversible(UUID paymentId) {
        var advance=advance(paymentId,false);
        if(!"OPEN".equals(advance.get("status")))throw conflict("预付资产已经反审");
        if(count("SELECT count(*) FROM finance_supplier_advance_applications WHERE payment_id=? AND status='APPLIED'",paymentId)>0)
            throw conflict("这笔预付款已有应付应用，请先按后发生的顺序撤回预付应用，再反审原付款");
        if(count("SELECT count(*) FROM finance_supplier_advance_refunds WHERE payment_id=? AND status='APPROVED'",paymentId)>0)
            throw conflict("这笔预付款已有实际退款，请先反审退款，再反审原付款");
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void reverse(UUID paymentId,OffsetDateTime reversedAt) {
        var advance=advance(paymentId,true);requireReversible(paymentId);
        if(reversedAt==null)throw invalid("预付反审缺少真实反审时间");
        var reverse=db.queryForList("""
            SELECT e.id FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
            WHERE v.source='AUTO' AND v.source_type='PAYMENT_REV' AND v.source_doc_id=? AND v.status=1
              AND NOT v.is_deleted AND e.line_no=1 AND e.direction=-1 AND e.style_id=? AND NOT e.is_deleted
            """,paymentId,advance.get("style_id"));
        if(reverse.size()!=1)throw conflict("原付款尚无真实对称GL红冲，不能释放预付资产");
        attach((UUID)reverse.getFirst().get("id"),advance,decimal(advance,"amount_original"),"PAYMENT_REV:"+paymentId);
        db.update("UPDATE finance_supplier_advances SET status='REVERSED',reversed_at=? WHERE payment_id=? AND status='OPEN'",reversedAt,paymentId);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> detail(UUID paymentId) {
        read();var row=new LinkedHashMap<>(advance(paymentId,false));
        row.remove("auxiliary_snapshot");row.remove("creation_tx");
        var payment= db.queryForMap("SELECT bill_no FROM finance_payments WHERE id=?",paymentId);
        row.put("billNo",payment.get("bill_no"));row.put("direction","AP");row.put("amountOriginal",row.get("amount_original"));row.put("amountLocal",row.get("amount_local"));
        row.put("currencyId",row.get("currency_id"));row.put("supplierId",row.get("supplier_id"));
        row.put("currencyName",db.queryForObject("SELECT name FROM currencies WHERE id=?",String.class,row.get("currency_id")));
        row.put("basis","真实供应商预付资产；原币单位与会计币别属性分别保存，应用不重复付款。分类独立守恒原币和本币。");
        row.put("parts",db.queryForList("SELECT category,amount_original,amount_local,source_reference FROM finance_supplier_advance_parts WHERE payment_id=? ORDER BY category",paymentId));
        var used=used(paymentId,null);row.put("remainingOriginal",decimal(row,"amount_original").subtract(used[0]).toPlainString());
        row.put("remainingLocal",decimal(row,"amount_local").subtract(used[1]).toPlainString());
        return view(row);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> list(UUID supplierId,UUID currencyId,int page,int size) {
        read();int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));var args=new ArrayList<Object>();String where=" WHERE true";
        if(supplierId!=null){where+=" AND a.supplier_id=?";args.add(supplierId);}if(currencyId!=null){where+=" AND a.currency_id=?";args.add(currencyId);}
        long total=db.queryForObject("SELECT count(*) FROM finance_supplier_advances a"+where,Long.class,args.toArray());args.add(s);args.add((long)(p-1)*s);
        var rows=db.queryForList("SELECT a.payment_id AS \"paymentId\",p.bill_no AS \"billNo\",a.effective_date AS \"billDate\",a.supplier_id AS \"supplierId\",supplier.code AS \"supplierCode\",supplier.name AS \"supplierName\",currency.code AS \"currencyCode\",a.currency_id AS \"currencyId\",a.amount_original AS \"amountOriginal\",a.amount_local AS \"amountLocal\",a.status FROM finance_supplier_advances a JOIN finance_payments p ON p.id=a.payment_id LEFT JOIN suppliers supplier ON supplier.id=a.supplier_id LEFT JOIN currencies currency ON currency.id=a.currency_id"+where+" ORDER BY a.effective_date DESC,p.bill_no,a.payment_id LIMIT ? OFFSET ?",args.toArray());
        rows.forEach(com.uten.imp.common.report.ReportQueryKit::includeDecimalTexts);return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> settlements(UUID paymentId,String kind,int page,int size) {
        read();advance(paymentId,false);boolean refunds="REFUND".equals(kind);if(!refunds&&!"APPLICATION".equals(kind))throw invalid("请选择预付应用或退款");
        int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));String table=refunds?"finance_supplier_advance_refunds":"finance_supplier_advance_applications";
        long total=db.queryForObject("SELECT count(*) FROM "+table+" WHERE payment_id=?",Long.class,paymentId);
        var rows=db.queryForList("SELECT * FROM "+table+" WHERE payment_id=? ORDER BY created_at DESC,id LIMIT ? OFFSET ?",paymentId,s,(long)(p-1)*s);
        if(!refunds)for(var row:rows){row.put("effectiveTargetParts",db.queryForList("SELECT batch_id AS \"batchId\",correction_id AS \"correctionId\",target_classification_id AS \"sourceClassificationId\",category,amount_original::text AS \"amountOriginal\",target_local::text AS \"targetLocal\" FROM v_finance_supplier_advance_target_parts_effective WHERE application_id=? ORDER BY category",row.get("id")));}
        rows.forEach(com.uten.imp.common.report.ReportQueryKit::includeDecimalTexts);return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }

    @Transactional
    public Map<String,Object> classify(UUID paymentId,Classify command) {
        write();tx.bind();reference(command==null?null:command.sourceReference());var a=advance(paymentId,true);
        if(!"OPEN".equals(a.get("status")))throw conflict("只可归类有效预付资产");
        if(command.parts()==null||command.parts().isEmpty()||command.parts().size()>2)throw invalid("请按货款/模具款分配原预付金额");
        BigDecimal original=BigDecimal.ZERO,local=BigDecimal.ZERO;var categories=new HashSet<String>();
        for(var p:command.parts()){
            category(p.category());if(!categories.add(p.category()))throw invalid("预付分类不能重复");
            nonnegative(p.amountOriginal(),false);nonnegative(p.amountLocal(),true);original=original.add(p.amountOriginal());local=local.add(p.amountLocal());
        }
        equal(original,decimal(a,"amount_original"),"预付原币归类");equal(local,decimal(a,"amount_local"),"预付本币归类");
        var existing=db.queryForList("SELECT * FROM finance_supplier_advance_parts WHERE payment_id=?",paymentId);
        if(!existing.isEmpty()) {
            boolean same=existing.size()==command.parts().size()&&existing.stream().allMatch(row->command.parts().stream().anyMatch(p->p.category().equals(row.get("category"))&&p.amountOriginal().compareTo(decimal(row,"amount_original"))==0&&p.amountLocal().compareTo(decimal(row,"amount_local"))==0&&command.sourceReference().equals(row.get("source_reference"))));
            if(same)return detail(paymentId);throw conflict("这笔预付已有保存的原归类，请核对原结果；已应用的来源不能独立改写");
        }
        for(var p:command.parts())db.update("INSERT INTO finance_supplier_advance_parts(payment_id,category,amount_original,amount_local,source_reference,created_by) VALUES(?,?,?,?,?,?)",
                paymentId,p.category(),p.amountOriginal(),p.amountLocal(),command.sourceReference(),current.requireId());
        return detail(paymentId);
    }

    @Transactional
    public Map<String,Object> apply(UUID paymentId,Apply command) {
        write();tx.bind();if(command==null||command.requestId()==null||command.payableId()==null)throw invalid("预付应用缺少提交或目标应付身份");
        requestLock(command.requestId());
        reference(command.sourceReference());category(command.sourceCategory());category(command.targetCategory());positive(command.amountOriginal(),false);
        String fingerprint=hash(encode(command));
        var replay=db.queryForList("SELECT * FROM finance_supplier_advance_applications WHERE request_id=?",command.requestId());
        if(!replay.isEmpty()) {if(!fingerprint.equals(replay.getFirst().get("payload_hash"))||!paymentId.equals(replay.getFirst().get("payment_id")))throw conflict("这个提交编号已用于不同预付应用，请核对原结果");return view(replay.getFirst());}
        PaymentStyleHierarchyLock.lock(em);LocalDate date=BusinessTime.today();periods.lockAutoProjectionPeriod(date);com.uten.imp.application.concurrency.FinanceClassificationLock.lock(em);
        // Supplier scope serializes with real AP payments and statement closing before either balance row is locked.
        var preview=advance(paymentId,false);closed.requireOpen((UUID)preview.get("supplier_id"),(UUID)preview.get("currency_id"),date,"供应商预付应用");
        journals.lockStyles(List.of((UUID)preview.get("style_id"),role("AP_CONTROL")));
        var a=advance(paymentId,true);if(!"OPEN".equals(a.get("status")))throw conflict("原预付资产已反审");
        holds.requireUnheld(List.of(command.payableId()),"供应商预付应用");
        var targets=db.queryForList("SELECT * FROM ar_ap_ledger WHERE id=? FOR UPDATE",command.payableId());
        if(targets.size()!=1)throw conflict("目标应付不存在");var target=targets.getFirst();
        if(!"AP".equals(target.get("direction"))||!"PAYABLE".equals(target.get("open_item_kind"))||number(target,"status")!=1||Boolean.TRUE.equals(target.get("is_deleted"))
                ||!Objects.equals(a.get("supplier_id"),target.get("supplier_id"))||!Objects.equals(a.get("currency_id"),target.get("currency_id")))
            throw conflict("预付只能应用于同供应商、同真实原币的有效正式应付");
        var parts=db.queryForList("SELECT * FROM finance_supplier_advance_parts WHERE payment_id=? AND category=?",paymentId,command.sourceCategory());
        if(parts.size()!=1)throw conflict("请先明确原预付的货款/模具款归类");
        var consumed=used(paymentId,command.sourceCategory());
        BigDecimal remainingOriginal=decimal(parts.getFirst(),"amount_original").subtract(consumed[0]),remainingLocal=decimal(parts.getFirst(),"amount_local").subtract(consumed[1]);
        BigDecimal beforeOriginal=decimal(target,"amount_balance_original"),beforeLocal=decimal(target,"amount_balance");
        if(command.amountOriginal().compareTo(remainingOriginal)>0||command.amountOriginal().compareTo(beforeOriginal)>0)throw conflict("本次应用超过预付分类或目标应付未结原币");
        BigDecimal sourceLocal=com.uten.imp.common.finance.FinancialBookAllocation.part(command.amountOriginal(),remainingOriginal,remainingLocal);
        BigDecimal targetLocal=com.uten.imp.common.finance.FinancialBookAllocation.part(command.amountOriginal(),beforeOriginal,beforeLocal);
        requireTargetCategory(command.payableId(),command.targetCategory(),command.amountOriginal(),targetLocal);
        var frozen=nativeAccounts.frozenArAp(command.payableId());
        if(frozen==null||!frozen.complete()||frozen.auxiliary()==null)throw conflict("目标应付缺少原科目与辅助快照，请先受审核对原分录，不按当前用途重新归类");
        var ap=new Account(frozen.styleId(),frozen.accountCode(),frozen.accountingCurrencyId(),frozen.auxiliary());
        var assetRef=ref(a);BigDecimal difference=sourceLocal.subtract(targetLocal);UUID id=UUID.randomUUID();
        UUID reservation=reserve(a,id,"SUPPLIER_ADVANCE_APPLICATION",sourceLocal,command.amountOriginal(),command.sourceReference());
        List<FinanceControlledJournalService.Entry> entries=new ArrayList<>();
        entries.add(new FinanceControlledJournalService.Entry(ap.style(),1,targetLocal,"供应商预付应用：正式应付冲减",allocation(ap.code(),ap.currency(),ap.auxiliary(),id,command.amountOriginal(),(UUID)a.get("currency_id"))));
        entries.add(new FinanceControlledJournalService.Entry((UUID)a.get("style_id"),-1,sourceLocal,"供应商预付应用：原预付资产释放",allocation(a.get("account_code").toString(),(UUID)a.get("accounting_currency_id"),assetRef,id,command.amountOriginal(),(UUID)a.get("currency_id"))));
        if(difference.signum()!=0)entries.add(new FinanceControlledJournalService.Entry(role("FX_GAIN_LOSS"),difference.signum(),difference.abs(),"供应商预付应用账面汇差"));
        var voucher=journals.post("YFYY-"+id,date,"SUPPLIER_ADVANCE_APPLICATION",id,"SUPPLIER_ADVANCE_APPLICATION",command.sourceReference(),entries,current.requireId());
        capacity.commit(new FinanceGlSettlementCapacityPort.Commit(UUID.randomUUID(),owner("SUPPLIER_ADVANCE_APPLICATION",id),reservation,
                List.of(new FinanceGlSettlementCapacityPort.Clearing(voucher.entryIds().get(1),1,originalSource(paymentId)))));
        db.update("""
            UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original+?,amount_offset_local=amount_offset_local+?,
              amount_balance_original=amount_balance_original-?,amount_balance=amount_balance-?,
              is_settled=(amount_balance_original-?=0 AND amount_balance-?=0),settled_date=CASE WHEN amount_balance_original-?=0 AND amount_balance-?=0 THEN ? ELSE NULL END,updated_at=now(),updated_by=? WHERE id=?
            """,command.amountOriginal(),targetLocal,command.amountOriginal(),targetLocal,command.amountOriginal(),targetLocal,command.amountOriginal(),targetLocal,date,current.requireId(),command.payableId());
        db.update("""
            INSERT INTO finance_supplier_advance_applications(id,request_id,payload_hash,payment_id,target_ledger_id,effective_date,source_reference,
              amount_original,source_local,target_local,source_category,target_category,target_before_original,target_after_original,
              target_before_local,target_after_local,voucher_id,reservation_id,status,created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'APPLIED',?)
            """,id,command.requestId(),fingerprint,paymentId,command.payableId(),date,command.sourceReference(),command.amountOriginal(),sourceLocal,targetLocal,command.sourceCategory(),command.targetCategory(),beforeOriginal,beforeOriginal.subtract(command.amountOriginal()),beforeLocal,beforeLocal.subtract(targetLocal),voucher.voucherId(),reservation,current.requireId());
        dependencies.advanceApplied(id);return view(db.queryForMap("SELECT * FROM finance_supplier_advance_applications WHERE id=?",id));
    }

    @Transactional
    public Map<String,Object> reverseApplication(UUID id,String reason) {
        write();tx.bind();reference(reason);PaymentStyleHierarchyLock.lock(em);LocalDate date=BusinessTime.today();periods.lockAutoProjectionPeriod(date);com.uten.imp.application.concurrency.FinanceClassificationLock.lock(em);
        var rows=db.queryForList("SELECT * FROM finance_supplier_advance_applications WHERE id=?",id);if(rows.size()!=1)throw conflict("预付应用来源不存在");
        var original=rows.getFirst();var a=advance((UUID)original.get("payment_id"),false);
        closed.requireOpen((UUID)a.get("supplier_id"),(UUID)a.get("currency_id"),date,"供应商预付应用反审");
        advance((UUID)original.get("payment_id"),true);
        var target=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=? FOR UPDATE",original.get("target_ledger_id"));
        original=db.queryForMap("SELECT * FROM finance_supplier_advance_applications WHERE id=? FOR UPDATE",id);
        if(!"APPLIED".equals(original.get("status")))throw conflict("这笔预付应用已反审，请核对原结果");
        dependencies.requireAdvanceReversible(id);
        equal(decimal(target,"amount_balance_original"),decimal(original,"target_after_original"),"反审前目标原币余额");
        equal(decimal(target,"amount_balance"),decimal(original,"target_after_local"),"反审前目标本币余额");
        var voucher=journals.reverse((UUID)original.get("voucher_id"),"YFYY-REV-"+id,date,"SUPPLIER_ADVANCE_APPLICATION_REV",id,"SUPPLIER_ADVANCE_APPLICATION_REV",reason,current.requireId());
        release(original,"SUPPLIER_ADVANCE_APPLICATION",id,voucher,1,reason);
        db.update("""
            UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original-?,amount_offset_local=amount_offset_local-?,
              amount_balance_original=?,amount_balance=?,is_settled=false,settled_date=NULL,updated_at=now(),updated_by=? WHERE id=?
            """,original.get("amount_original"),original.get("target_local"),original.get("target_before_original"),original.get("target_before_local"),current.requireId(),original.get("target_ledger_id"));
        db.update("UPDATE finance_supplier_advance_applications SET status='REVERSED',reversal_voucher_id=?,reversed_at=now() WHERE id=?",voucher.voucherId(),id);
        return view(db.queryForMap("SELECT * FROM finance_supplier_advance_applications WHERE id=?",id));
    }

    @Transactional
    public Map<String,Object> createRefund(UUID paymentId,Refund command) {
        read();CurrentAuthorityGuard.requireAll("finance_receipt:create");tx.bind();
        if(command==null||command.requestId()==null||command.accountId()==null||command.accountCurrencyId()==null||command.bankBookedAt()==null)throw invalid("退款须有真实来源、提交编号、收款账户与实际入账时间");
        requestLock(command.requestId());
        reference(command.sourceReference());reference(command.bankReference());category(command.sourceCategory());positive(command.amountOriginal(),false);positive(command.bankAmount(),false);positive(command.bankRate(),false);nonnegative(command.bankFeeAmount(),false);
        String hash=hash(encode(command));var prior=db.queryForList("SELECT * FROM finance_supplier_advance_refunds WHERE request_id=?",command.requestId());
        if(!prior.isEmpty()){if(!hash.equals(prior.getFirst().get("payload_hash"))||!paymentId.equals(prior.getFirst().get("payment_id")))throw conflict("退款提交编号已有不同内容，请核对原回执");return view(prior.getFirst());}
        var a=advance(paymentId,false);var account=bank.lockActive(command.accountId(),"供应商预付退款收款账户");
        if(!command.accountCurrencyId().equals(account.currencyId()))throw conflict("退款账户币别已变化，请重新核对");
        if(!account.baseCurrency()&&!Objects.equals(account.currencyId(),a.get("currency_id")))throw invalid("退款只支持真实原币账户或本位币账户");
        if(account.baseCurrency()&&command.bankRate().compareTo(BigDecimal.ONE)!=0)throw invalid("本位币退款账户汇率须为1");
        if(account.currencyId().equals(a.get("currency_id"))&&command.bankAmount().add(command.bankFeeAmount()).compareTo(command.amountOriginal())!=0)
            throw invalid("同币退款的实际到账加实际手续费须等于退回原币，不能用汇差补齐");
        if(account.styleId()==null)throw conflict("退款收款账户缺少明确会计科目");
        BigDecimal local=FinancialExactAmount.book(command.bankAmount().multiply(command.bankRate()),"退款实际到账本币");
        BigDecimal fee=FinancialExactAmount.book(command.bankFeeAmount().multiply(command.bankRate()),"退款实际手续费本币");
        UUID id=UUID.randomUUID();db.update("""
            INSERT INTO finance_supplier_advance_refunds(id,request_id,payload_hash,payment_id,source_category,source_reference,amount_original,
              account_id,account_currency_id,bank_reference,bank_booked_at,bank_amount,bank_rate,bank_local,fee_amount,fee_local,bank_style_id,fee_style_id,status,created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'DRAFT',?)
            """,id,command.requestId(),hash,paymentId,command.sourceCategory(),command.sourceReference(),command.amountOriginal(),command.accountId(),command.accountCurrencyId(),command.bankReference(),command.bankBookedAt(),command.bankAmount(),command.bankRate(),local,command.bankFeeAmount(),fee,account.styleId(),fee.signum()==0?null:role("BANK_FEE_EXPENSE"),current.requireId());
        return refund(id);
    }

    @Transactional
    public Map<String,Object> approveRefund(UUID id) {
        read();CurrentAuthorityGuard.requireAll("finance_receipt:approve");tx.bind();PaymentStyleHierarchyLock.lock(em);LocalDate date=BusinessTime.today();periods.lockAutoProjectionPeriod(date);com.uten.imp.application.concurrency.FinanceClassificationLock.lock(em);
        var r=refund(id);var a=advance((UUID)r.get("payment_id"),false);
        closed.requireOpen((UUID)a.get("supplier_id"),(UUID)a.get("currency_id"),date,"供应商预付退款");
        closed.requireOpen((UUID)a.get("supplier_id"),(UUID)a.get("currency_id"),offset(r.get("bank_booked_at")).atZoneSameInstant(BusinessTime.ZONE).toLocalDate(),"供应商预付退款银行日期");
        journals.lockStyles(List.of((UUID)a.get("style_id"),(UUID)r.get("bank_style_id")));
        a=advance((UUID)r.get("payment_id"),true);r=db.queryForMap("SELECT * FROM finance_supplier_advance_refunds WHERE id=? FOR UPDATE",id);
        if(!"DRAFT".equals(r.get("status"))||!"OPEN".equals(a.get("status")))throw conflict("退款已处理或原预付已反审，请核对原结果");
        if(current.requireId().equals(r.get("created_by")))throw conflict("退款制单人与审核人不能相同");
        com.uten.imp.common.finance.ActualBankBookingPolicy.requireOccurred(
                offset(r.get("bank_booked_at")),"退款银行实际入账时间");
        var bankAccount=bank.lockActive((UUID)r.get("account_id"),"预付退款实际收款账户");
        if(!Objects.equals(bankAccount.currencyId(),r.get("account_currency_id"))||!Objects.equals(bankAccount.styleId(),r.get("bank_style_id")))throw conflict("收款账户币种或会计科目已变化，请重建退款草稿");
        BigDecimal original=decimal(r,"amount_original");var parts=db.queryForList("SELECT * FROM finance_supplier_advance_parts WHERE payment_id=? AND category=?",r.get("payment_id"),r.get("source_category"));
        if(parts.size()!=1)throw conflict("请先确认原预付货款/模具款归类");var used=used((UUID)r.get("payment_id"),r.get("source_category").toString());
        BigDecimal available=decimal(parts.getFirst(),"amount_original").subtract(used[0]),bookAvailable=decimal(parts.getFirst(),"amount_local").subtract(used[1]);
        if(original.compareTo(available)>0)throw conflict("实际退款超过原预付该分类的剩余原币");
        BigDecimal book=com.uten.imp.common.finance.FinancialBookAllocation.part(original,available,bookAvailable);
        BigDecimal diff=decimal(r,"bank_local").add(decimal(r,"fee_local")).subtract(book);UUID fx=diff.signum()==0?null:role("FX_GAIN_LOSS");
        UUID reservation=reserve(a,id,"SUPPLIER_ADVANCE_REFUND",book,original,r.get("source_reference").toString());
        List<FinanceControlledJournalService.Entry> entries=new ArrayList<>();
        entries.add(new FinanceControlledJournalService.Entry((UUID)r.get("bank_style_id"),1,decimal(r,"bank_local"),"供应商预付退款实际到账"));
        entries.add(new FinanceControlledJournalService.Entry((UUID)a.get("style_id"),-1,book,"供应商预付退款：原资产释放",allocation(a.get("account_code").toString(),(UUID)a.get("accounting_currency_id"),ref(a),id,original,(UUID)a.get("currency_id"))));
        if(decimal(r,"fee_local").signum()>0)entries.add(new FinanceControlledJournalService.Entry((UUID)r.get("fee_style_id"),1,decimal(r,"fee_local"),"供应商预付退款银行实际手续费"));
        if(diff.signum()!=0)entries.add(new FinanceControlledJournalService.Entry(fx,-diff.signum(),diff.abs(),"供应商预付退款账面汇差"));
        var posted=journals.post("YFTK-"+id,date,"SUPPLIER_ADVANCE_REFUND",id,"SUPPLIER_ADVANCE_REFUND",r.get("source_reference").toString(),entries,current.requireId());
        capacity.commit(new FinanceGlSettlementCapacityPort.Commit(UUID.randomUUID(),owner("SUPPLIER_ADVANCE_REFUND",id),reservation,List.of(new FinanceGlSettlementCapacityPort.Clearing(posted.entryIds().get(1),1,originalSource((UUID)a.get("payment_id"))))));
        bank.post(bankAccount,AccountPosting.in("SUPPLIER_ADVANCE_REFUND",id,"YFTK-"+id,(UUID)r.get("account_id"))
                .rule(AccountPosting.CurrencyRule.ACCOUNT_CURRENCY,(UUID)r.get("account_currency_id"))
                .amounts(decimal(r,"bank_amount"),decimal(r,"bank_local")).bookedAt(offset(r.get("bank_booked_at"))).settledAt(OffsetDateTime.now()).checkNo(r.get("bank_reference").toString()).label("预付退款账户"));
        db.update("UPDATE finance_supplier_advance_refunds SET status='APPROVED',source_local=?,fx_style_id=?,effective_date=?,voucher_id=?,reservation_id=?,approved_by=?,approved_at=now() WHERE id=?",book,fx,date,posted.voucherId(),reservation,current.requireId(),id);
        return refund(id);
    }

    @Transactional
    public Map<String,Object> reverseRefund(UUID id,String reason) {
        read();CurrentAuthorityGuard.requireAll("finance_receipt:reverse");tx.bind();reference(reason);PaymentStyleHierarchyLock.lock(em);LocalDate date=BusinessTime.today();periods.lockAutoProjectionPeriod(date);com.uten.imp.application.concurrency.FinanceClassificationLock.lock(em);
        var r=refund(id);var a=advance((UUID)r.get("payment_id"),false);closed.requireOpen((UUID)a.get("supplier_id"),(UUID)a.get("currency_id"),date,"供应商预付退款反审");
        journals.lockStyles(List.of((UUID)a.get("style_id"),(UUID)r.get("bank_style_id")));advance((UUID)r.get("payment_id"),true);
        r=db.queryForMap("SELECT * FROM finance_supplier_advance_refunds WHERE id=? FOR UPDATE",id);if(!"APPROVED".equals(r.get("status")))throw conflict("只可反审已审核退款");
        bank.requireReversible("SUPPLIER_ADVANCE_REFUND",id);
        var reverse=journals.reverse((UUID)r.get("voucher_id"),"YFTK-REV-"+id,date,"SUPPLIER_ADVANCE_REFUND_REV",id,"SUPPLIER_ADVANCE_REFUND_REV",reason,current.requireId());
        release(r,"SUPPLIER_ADVANCE_REFUND",id,reverse,1,reason);
        bank.reverse("SUPPLIER_ADVANCE_REFUND",id,OffsetDateTime.now(),reason);
        db.update("UPDATE finance_supplier_advance_refunds SET status='REVERSED',reversal_voucher_id=?,reversed_at=now() WHERE id=?",reverse.voucherId(),id);return refund(id);
    }

    @Transactional(readOnly=true) public Map<String,Object> refund(UUID id){read();var rows=db.queryForList("SELECT * FROM finance_supplier_advance_refunds WHERE id=?",id);if(rows.size()!=1)throw conflict("预付退款不存在");return view(rows.getFirst());}

    private UUID reserve(Map<String,Object>a,UUID id,String kind,BigDecimal local,BigDecimal original,String reference){
        var source=originalSource((UUID)a.get("payment_id"));
        var scope=new FinanceGlSettlementCapacityPort.Scope((UUID)a.get("style_id"),a.get("account_code").toString(),(UUID)a.get("auxiliary_id"),(UUID)a.get("accounting_currency_id"),(UUID)a.get("currency_id"),1,BusinessTime.today(),"SUPPLIER");
        var preview=capacity.preview(scope,FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE,List.of(source),owner(kind,id));
        if(!preview.ready())throw conflict("预付原GL容量待核对："+preview.issues());
        return capacity.reserve(new FinanceGlSettlementCapacityPort.Reservation(UUID.randomUUID(),owner(kind,id),scope,FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE,preview.fingerprint(),local,original,List.of(new FinanceGlSettlementCapacityPort.SourceAmount(source,local,original)),reference)).reservationId();
    }
    private FinanceGlSettlementCapacityPort.Owner owner(String kind,UUID id){return new FinanceGlSettlementCapacityPort.Owner(kind,id,current.requireId());}
    private FinanceGlSettlementCapacityPort.SourceRef originalSource(UUID payment){return new FinanceGlSettlementCapacityPort.SourceRef(db.queryForObject("SELECT e.id FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source='AUTO' AND v.source_type='PAYMENT' AND v.source_doc_id=? AND e.line_no=1 AND NOT e.is_deleted",UUID.class,payment),1);}
    private void release(Map<String,Object> row,String kind,UUID id,FinanceControlledJournalService.Posted reverse,int entryIndex,String reason){
        if(row.get("reservation_id")==null)throw conflict("原清偿缺少受控预留，不能直接恢复容量");
        UUID originalEntry=db.queryForObject("SELECT id FROM gl_entries WHERE voucher_id=? AND line_no=? AND NOT is_deleted",UUID.class,row.get("voucher_id"),entryIndex+1);
        capacity.release(new FinanceGlSettlementCapacityPort.Release(UUID.randomUUID(),owner(kind,id),(UUID)row.get("reservation_id"),List.of(new FinanceGlSettlementCapacityPort.Reversal(reverse.entryIds().get(entryIndex),1,originalEntry,1)),reason));
    }

    private void requireTargetCategory(UUID target,String category,BigDecimal original,BigDecimal local) {
        var targetParts=payableClassifications.target(target).parts();
        var part=targetParts.stream().filter(p->p.category().equals(category)).findFirst().orElseThrow(()->conflict("目标正式应付须先明确本次货款/模具款归类"));
        if(part.remainingOriginal()==null||part.remainingLocal()==null)throw conflict("目标分类剩余金额尚未完整核验");
        if(original.compareTo(part.remainingOriginal())>0||local.compareTo(part.remainingLocal())>0)throw conflict("本次预付应用超过目标应付该分类的剩余原币或本币");
        if(count("SELECT count(*) FROM finance_payment_lines l JOIN finance_payments p ON p.id=l.payment_id WHERE l.applied_ledger_id=? AND p.status=1 AND NOT p.is_deleted AND NOT l.is_deleted AND NOT EXISTS(SELECT 1 FROM v_finance_payment_classification_current c WHERE c.payment_line_id=l.id)",target)>0
                ||count("SELECT count(*) FROM supplier_open_item_offsets o WHERE o.target_ledger_id=? AND o.status='APPLIED' AND NOT EXISTS(SELECT 1 FROM v_finance_supplier_offset_classification_current c WHERE c.offset_id=o.id)",target)>0)
            throw conflict("目标应付还有未归类的实际付款/抵销，请先核对后应用预付");
    }

    private Account account(String postingRole,UUID supplier,UUID originalCurrency,LocalDate day) {
        var resolved=nativeAccounts.resolve(new NativeFinancialPostingAccountPort.Request(postingRole,null,originalCurrency,new NativeFinancialPostingAccountPort.Party("SUPPLIER",supplier),day));
        if(!resolved.complete()||resolved.auxiliary()==null)throw conflict("请先明确该用途、真实币别与供应商的财务科目及辅助对应");
        return new Account(resolved.styleId(),resolved.accountCode(),resolved.accountingCurrencyId(),resolved.auxiliary());
    }
    private UUID role(String role){Object value=em.createNativeQuery("SELECT system_posting_style_id(:role)").setParameter("role",role).getSingleResult();if(!(value instanceof UUID id))throw conflict("请先维护会计科目用途："+role);return id;}
    private Map<String,Object> payment(UUID id){var rows=db.queryForList("SELECT * FROM finance_payments WHERE id=? FOR UPDATE",id);if(rows.size()!=1)throw conflict("采购付款不存在");return rows.getFirst();}
    private Map<String,Object> advance(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_supplier_advances WHERE payment_id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw conflict("这笔付款没有已核验的供应商预付资产来源");return rows.getFirst();}
    private BigDecimal[] used(UUID id,String category){var row=db.queryForMap("SELECT COALESCE(sum(amount_original),0) original,COALESCE(sum(source_local),0) local FROM (SELECT payment_id,source_category,amount_original,source_local FROM finance_supplier_advance_applications WHERE status='APPLIED' UNION ALL SELECT payment_id,source_category,amount_original,source_local FROM finance_supplier_advance_refunds WHERE status='APPROVED') consumed WHERE payment_id=? AND (?::text IS NULL OR source_category=?)",id,category,category);return new BigDecimal[]{decimal(row,"original"),decimal(row,"local")};}
    private FinancialAuxiliaryValidationPort.Ref ref(Map<String,Object> a){try{return json.readValue(a.get("auxiliary_snapshot").toString(),FinancialAuxiliaryValidationPort.Ref.class);}catch(Exception e){throw conflict("原预付辅助核算快照损坏");}}
    private FinanceControlledJournalService.Allocation allocation(String code,UUID currency,FinancialAuxiliaryValidationPort.Ref ref,UUID source,BigDecimal original,UUID originalCurrency){return new FinanceControlledJournalService.Allocation(code,currency,ref,source.toString(),1,"{}",originalCurrency,original,null);}
    private void attach(UUID entry,Map<String,Object>a,BigDecimal original,String source){
        if(count("SELECT count(*) FROM finance_gl_entry_allocations WHERE entry_id=?",entry)>0)return;
        var r=ref(a);db.update("""
            INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,original_currency_id,
              amount_local,amount_original,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,source_snapshot,created_by)
            VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,1,'{}'::jsonb,?)
            """,entry,a.get("account_code"),a.get("account_code"),r.auxiliaryId(),a.get("accounting_currency_id"),a.get("currency_id"),a.get("amount_local"),original,r.role(),r.partyId(),r.sourceSystem(),r.sourceCode(),r.sourceName(),source,current.requireId());
    }
    private String encode(Object o){try{return json.writeValueAsString(o);}catch(Exception e){throw invalid("无法保存预付来源快照");}}
    private static String hash(String s){try{return HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(s.getBytes(java.nio.charset.StandardCharsets.UTF_8)));}catch(java.security.NoSuchAlgorithmException e){throw new IllegalStateException(e);}}
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view","ar_ap_ledger:view");FinanceCompanyReportAccess.require(access);}
    private void write(){read();CurrentAuthorityGuard.requireAll("supplier_settlement:confirm","finance_payment:approve");}
    private int count(String sql,Object...args){return db.queryForObject(sql,Integer.class,args);}
    private void requestLock(UUID id){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:supplier-advance-request:'||?::text,0))",rs->{},id);}
    private static Map<String,Object> view(Map<String,Object> row){com.uten.imp.common.report.ReportQueryKit.includeDecimalTexts(row);return row;}
    private static int number(Map<String,Object> row,String key){return ((Number)row.get(key)).intValue();}
    private static OffsetDateTime offset(Object value){return value instanceof OffsetDateTime d?d:value instanceof java.sql.Timestamp d?d.toInstant().atOffset(ZoneOffset.UTC):OffsetDateTime.parse(value.toString());}
    private static LocalDate date(Object value){return value instanceof java.sql.Date d?d.toLocalDate():(LocalDate)value;}
    private static BigDecimal decimal(Map<String,Object> row,String key){Object v=row.get(key);if(v==null)throw conflict("来源金额缺少核验证据："+key);return (BigDecimal)v;}
    private static void category(String c){if(!Set.of("GOODS","MOULD").contains(Objects.toString(c,"")))throw invalid("请选择货款或模具款分类");}
    private static void reference(String s){if(s==null||s.isBlank()||s.length()>2000)throw invalid("请填写原来源/复核依据（最多2000字）");}
    private static void positive(BigDecimal amount,boolean book){nonnegative(amount,book);if(amount.signum()==0)throw invalid("本次金额须大于零");}
    private static void nonnegative(BigDecimal amount,boolean book){if(amount==null||amount.signum()<0)throw invalid("金额须完整且非负");if(book)FinancialExactAmount.book(amount,"账面本币");else FinancialExactAmount.require(amount,"真实原币");}
    private static void equal(BigDecimal a,BigDecimal b,String label){if(a.compareTo(b)!=0)throw invalid(label+"没有守恒");}
    private static ApiException invalid(String s){return new ApiException(ErrorCode.VALIDATION_FAILED,s);}
    private static ApiException conflict(String s){return new ApiException(ErrorCode.CONFLICT,s);}
}
