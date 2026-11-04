package com.uten.imp.features.finance.gl;

import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.FinancialAuxiliaryValidationPort;
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
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.*;

/**
 * One writer for controlled subledger journals. The owning workflow authorizes the
 * action and freezes its source first; this writer owns exact balance, period,
 * original journal locking and symmetric reversal. It never regenerates journals.
 */
@Service @RequiredArgsConstructor
public class FinanceControlledJournalService {
    private final EntityManager em;
    private final JdbcTemplate db;
    private final GlPostingService periods;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;

    public record Allocation(String accountCode,UUID currencyId,FinancialAuxiliaryValidationPort.Ref auxiliary,
            String sourceEntryId,int sourceRow,String sourceSnapshot,UUID actualOriginalCurrencyId,
            BigDecimal amountOriginal,BigDecimal exchangeRate) {
        public Allocation(String accountCode,UUID currencyId,FinancialAuxiliaryValidationPort.Ref auxiliary,
                String sourceEntryId,int sourceRow,String sourceSnapshot) {
            this(accountCode,currencyId,auxiliary,sourceEntryId,sourceRow,sourceSnapshot,null,null,null);
        }
    }
    public record Entry(UUID styleId,int direction,BigDecimal amount,String summary,Allocation allocation) {
        public Entry(UUID styleId,int direction,BigDecimal amount,String summary){this(styleId,direction,amount,summary,null);}
    }
    public record Posted(UUID voucherId,List<UUID> entryIds) { }

    @Transactional(propagation=Propagation.MANDATORY)
    public Posted post(String voucherNo,LocalDate voucherDate,String sourceType,UUID sourceId,
            String sourceDocumentType,String remark,List<Entry> entries,UUID actor) {
        bindActor(actor);lock(voucherDate);validateEntries(entries);lockStyles(entries.stream().map(Entry::styleId).toList());
        if(entries.isEmpty())return new Posted(null,List.of());
        return insert(voucherNo,voucherDate,sourceType,sourceId,sourceDocumentType,remark,entries,actor,null,null);
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public Posted reverse(UUID originalVoucherId,String voucherNo,LocalDate voucherDate,String sourceType,
            UUID sourceId,String sourceDocumentType,String reason,UUID actor) {
        bindActor(actor);lock(voucherDate);
        if(originalVoucherId==null)throw invalid("缺少原凭证编号");
        var originals=db.queryForList("SELECT status,is_deleted,reversed_by_voucher_id FROM gl_vouchers WHERE id=? FOR UPDATE",originalVoucherId);
        if(originals.size()!=1||Boolean.TRUE.equals(originals.getFirst().get("is_deleted"))
                ||((Number)originals.getFirst().get("status")).intValue()!=1
                ||originals.getFirst().get("reversed_by_voucher_id")!=null)throw conflict("原凭证已变化或已有红冲，请先核对原结果");
        var rows=db.queryForList("SELECT id,style_id,direction,amount,summary FROM gl_entries WHERE voucher_id=? AND NOT is_deleted ORDER BY line_no,id FOR SHARE",originalVoucherId);
        if(rows.isEmpty())throw invalid("原凭证没有有效分录，不能红冲");
        List<Entry> entries=rows.stream().map(r->new Entry((UUID)r.get("style_id"),-((Number)r.get("direction")).intValue(),
                (BigDecimal)r.get("amount"),"红冲："+Objects.toString(r.get("summary"),reason))).toList();
        validateEntries(entries);lockStyles(entries.stream().map(Entry::styleId).toList());
        var result=insert(voucherNo,voucherDate,sourceType,sourceId,sourceDocumentType,reason,entries,actor,
                originalVoucherId,rows.stream().map(r->(UUID)r.get("id")).toList());
        if(db.update("UPDATE gl_vouchers SET status=-1,reversed_by_voucher_id=?,updated_at=now(),updated_by=? WHERE id=? AND status=1 AND reversed_by_voucher_id IS NULL",result.voucherId(),actor,originalVoucherId)!=1)
            throw conflict("原凭证状态已变化，本次红冲未保存");
        return result;
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public void lockStyles(Collection<UUID> styles){
        for(UUID style:styles.stream().filter(Objects::nonNull).distinct().sorted().toList())
            db.query("SELECT fn_finance_gl_settlement_lock_style(?)",rs->{},style);
    }
    private void bindActor(UUID actor){
        if(actor==null||!actor.equals(current.requireId()))throw new ApiException(ErrorCode.FORBIDDEN,"会计操作人与当前授权身份不一致");
        tx.bind();
    }
    private void lock(LocalDate date){
        if(date==null)throw invalid("请填写凭证日期");
        PaymentStyleHierarchyLock.lock(em);periods.lockAutoProjectionPeriod(date);
    }
    private Posted insert(String voucherNo,LocalDate date,String sourceType,UUID sourceId,String documentType,
            String remark,List<Entry> entries,UUID actor,UUID reversalOf,List<UUID> originalEntries){
        if(voucherNo==null||voucherNo.isBlank()||sourceType==null||sourceType.isBlank()||sourceId==null
                ||documentType==null||documentType.isBlank())throw invalid("凭证缺少原业务来源身份");
        String period=YearMonth.from(date).toString(),ref=documentType+":"+sourceId;
        UUID voucher=UUID.randomUUID();
        db.update("""
                INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,remark,
                  source_ref,idempotency_key,reversal_of_voucher_id,status,created_by,updated_by)
                VALUES(?,?,?,?,'AUTO',?,?,?,?,?,0,?,?)
                """,voucher,voucherNo,period,date,sourceType,remark,ref,sourceType+"|"+ref+"|"+period,reversalOf,actor,actor);
        List<UUID> ids=new ArrayList<>(entries.size());
        for(int i=0;i<entries.size();i++){
            Entry entry=entries.get(i);UUID id=UUID.randomUUID();ids.add(id);
            db.update("""
                    INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period,
                      source_doc_type,source_doc_id,source_bill_no,summary,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,id,voucher,i+1,entry.styleId(),entry.direction(),entry.amount(),date,period,documentType,sourceId,voucherNo,entry.summary(),actor,actor);
            if(entry.allocation()!=null){
                var a=entry.allocation();var auxiliary=a.auxiliary();
                UUID originalCurrency=a.actualOriginalCurrencyId();BigDecimal original=a.amountOriginal(),rate=a.exchangeRate();
                if(original==null&&originalCurrency==null&&rate==null) {
                    Boolean base=a.currencyId()==null?false:db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=? AND NOT is_deleted",Boolean.class,a.currencyId());
                    if(Boolean.TRUE.equals(base)){originalCurrency=a.currencyId();original=FinancialExactAmount.require(entry.amount(),"本位币原额");rate=BigDecimal.ONE;}
                } else {
                    if(original==null||originalCurrency==null)throw invalid("原币金额和真实原币单位须一起填写");
                    FinancialExactAmount.require(original,"原币金额");
                    if(original.signum()==0||original.signum()!=entry.amount().signum())throw invalid("原币金额须非零且与本币原始红字方向一致");
                    if(rate!=null){FinancialExactAmount.require(rate,"来源汇率");if(rate.signum()<=0)throw invalid("来源汇率须大于零");}
                }
                db.update("""
                    INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,
                      auxiliary_id,currency_id,original_currency_id,amount_local,amount_original,exchange_rate,
                      auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,
                      source_snapshot,created_by)
                    VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?)
                    """,id,a.accountCode(),a.accountCode(),auxiliary==null?null:auxiliary.auxiliaryId(),a.currencyId(),originalCurrency,
                        entry.amount(),original,rate,auxiliary==null?null:auxiliary.role(),auxiliary==null?null:auxiliary.partyId(),
                        auxiliary==null?null:auxiliary.sourceSystem(),auxiliary==null?null:auxiliary.sourceCode(),auxiliary==null?null:auxiliary.sourceName(),
                        a.sourceEntryId(),a.sourceRow(),a.sourceSnapshot(),actor);
            }
            if(originalEntries!=null)db.update("""
                    INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,
                      source_account_name,source_account_path_name,auxiliary_id,currency_id,original_currency_id,
                      amount_local,amount_original,exchange_rate,auxiliary_role,party_id_snapshot,source_system,
                      source_code,source_name,source_entry_id,source_row,source_snapshot,created_by)
                    SELECT ?,allocation_no,account_code,source_account_code,source_account_name,source_account_path_name,
                      auxiliary_id,currency_id,original_currency_id,amount_local,amount_original,exchange_rate,auxiliary_role,
                      party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,source_snapshot,?
                    FROM finance_gl_entry_allocations WHERE entry_id=?
                    """,id,actor,originalEntries.get(i));
        }
        if(db.update("UPDATE gl_vouchers SET status=1,updated_at=now(),updated_by=? WHERE id=? AND status=0",actor,voucher)!=1)
            throw conflict("凭证草稿未完成入账，本次未保存");
        return new Posted(voucher,List.copyOf(ids));
    }

    public static void validateEntries(List<Entry> entries){
        if(entries==null)throw invalid("请填写凭证分录");
        BigDecimal debit=BigDecimal.ZERO,credit=BigDecimal.ZERO;
        for(var entry:entries){
            if(entry==null||entry.styleId()==null||(entry.direction()!=1&&entry.direction()!=-1)
                    ||entry.amount()==null||entry.amount().signum()==0)throw invalid("凭证科目、方向或金额无效");
            FinancialExactAmount.book(entry.amount(),"凭证金额");
            if(entry.direction()==1)debit=debit.add(entry.amount());else credit=credit.add(entry.amount());
        }
        FinancialExactAmount.book(debit,"借方合计");FinancialExactAmount.book(credit,"贷方合计");
        if(debit.compareTo(credit)!=0)throw invalid("凭证借贷不平，请核对原项目及其金额；本次未保存");
    }
    private static ApiException invalid(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
    private static ApiException conflict(String text){return new ApiException(ErrorCode.CONFLICT,text);}
}
