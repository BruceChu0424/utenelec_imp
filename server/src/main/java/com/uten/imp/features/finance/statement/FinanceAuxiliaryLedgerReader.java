package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.gl.FinancialLedgerReadScope;
import com.uten.imp.security.CurrentAuthorityGuard;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;

/** Shared by original statement footers and material processing-fee attribution. No second amount ledger. */
@Service @RequiredArgsConstructor
public class FinanceAuxiliaryLedgerReader implements FinanceAuxiliaryLedgerReadPort {
    private final EntityManager em;
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final FinanceDocumentAccessPolicy access;
    private final FinancialAuxiliaryValidationPort auxiliary;
    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Balance read(Scope scope) {
        CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);
        if(scope==null||scope.accountCode()==null||scope.auxiliaryId()==null||scope.accountingCurrencyId()==null||scope.dateFrom()==null||scope.dateTo()==null||scope.dateFrom().isAfter(scope.dateTo()))throw invalid("账载余额须明确科目、辅助对象、会计币别和完整期间");
        var ref=auxiliary.inspectHistorical(new FinancialAuxiliaryValidationPort.Selection(scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId()));
        if(ref==null||ref.partyId()==null)throw invalid("请先对应真实往来辅助对象，不能按同名汇总");
        var opening=FinancialLedgerReadScope.asOf(em,scope.dateFrom().minusDays(1));var period=FinancialLedgerReadScope.range(em,scope.dateFrom(),scope.dateTo());var closing=FinancialLedgerReadScope.asOf(em,scope.dateTo());
        var missing=FinanceAuxiliaryCompleteness.read(db,scope.accountCode(),scope.accountingCurrencyId(),scope.dateFrom(),scope.dateTo());
        int zeroProof=db.queryForObject("SELECT count(*) FROM finance_gl_auxiliary_opening_evidence WHERE account_code=? AND auxiliary_id=? AND currency_id=? AND effective_from<=? AND opening_debit=0 AND opening_credit=0",Integer.class,scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId(),scope.dateFrom());
        var originalZero=scope.originalCurrencyId()==null?List.<Map<String,Object>>of():db.queryForList("SELECT id,effective_from,original_currency_id,opening_original,source_sha256 FROM finance_gl_auxiliary_opening_evidence WHERE account_code=? AND auxiliary_id=? AND currency_id=? AND effective_from<=? AND original_currency_id=? AND opening_original=0 ORDER BY effective_from,id",scope.accountCode(),scope.auxiliaryId(),scope.accountingCurrencyId(),scope.dateFrom(),scope.originalCurrencyId());
        BigDecimal[] local=zeros(),original=zeros();long[] count={0},originalCount={0};boolean[] unknownOriginal={false,false};
        java.security.MessageDigest digest,originalDigest;
        try{digest=java.security.MessageDigest.getInstance("SHA-256");digest.update("GL-AUX-V3\n".getBytes(java.nio.charset.StandardCharsets.UTF_8));digest.update(json.writeValueAsBytes(List.of(scope,opening.complete(),period.complete(),closing.complete(),zeroProof,missing)));}
        catch(Exception error){throw new IllegalStateException("账载来源摘要生成失败",error);}
        try{originalDigest=java.security.MessageDigest.getInstance("SHA-256");originalDigest.update("GL-AUX-ORIGINAL-V1\n".getBytes(java.nio.charset.StandardCharsets.UTF_8));originalDigest.update(json.writeValueAsBytes(List.of(scope,opening.complete(),period.complete(),closing.complete(),missing)));for(var proof:originalZero){var stable=new TreeMap<String,String>();proof.forEach((key,value)->stable.put(key,value==null?null:value.toString()));originalDigest.update(json.writeValueAsBytes(stable));}}
        catch(Exception error){throw new IllegalStateException("原币账载来源摘要生成失败",error);}
        // Consume JDBC rows once. A long-running auxiliary never retains its entire ledger in server memory.
        db.query("""
            SELECT entry.id,entry.entry_date,entry.direction,entry.voucher_id,entry.amount AS entry_amount,
              true AS booked,voucher.reversal_of_voucher_id,allocation.allocation_no,
              allocation.amount_local,allocation.amount_original,allocation.original_currency_id,
              allocation.auxiliary_role,allocation.party_id_snapshot,allocation.source_snapshot
            FROM finance_gl_entry_allocations allocation JOIN gl_entries entry ON entry.id=allocation.entry_id
            JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
            WHERE allocation.account_code=? AND allocation.auxiliary_id=? AND allocation.currency_id=? AND entry.entry_date<=?
              AND NOT entry.is_deleted AND fn_finance_gl_voucher_is_booked(voucher.id)
            ORDER BY entry.entry_date,entry.id,allocation.allocation_no
            """,statement->{statement.setObject(1,scope.accountCode());statement.setObject(2,scope.auxiliaryId());statement.setObject(3,scope.accountingCurrencyId());statement.setObject(4,scope.dateTo());statement.setFetchSize(1000);},
            (org.springframework.jdbc.core.RowCallbackHandler) row->{
                count[0]++;
                if(!Objects.equals(row.getObject("party_id_snapshot"),ref.partyId())||!Objects.equals(row.getString("auxiliary_role"),ref.role()))throw invalid("原已记账辅助快照与当前真实对象不一致，请先核对原对应关系");
                var date=row.getDate("entry_date").toLocalDate();boolean prior=date.isBefore(scope.dateFrom());int direction=row.getInt("direction");
                add(local,row.getBigDecimal("amount_local"),direction,prior);
                Object originalUnit=row.getObject("original_currency_id");BigDecimal amount=row.getBigDecimal("amount_original");
                boolean matchesOriginal=scope.originalCurrencyId()!=null&&Objects.equals(originalUnit,scope.originalCurrencyId());
                if(matchesOriginal){originalCount[0]++;if(amount!=null)add(original,amount,direction,prior);else unknownOriginal[prior?0:1]=true;}
                else if(scope.originalCurrencyId()!=null&&originalUnit==null)unknownOriginal[prior?0:1]=true;
                // Later reversal does not change an earlier period's booked
                // fact. Its actual dated reversing entry changes only periods
                // that include it, not the original document's old fingerprint.
                var fact=new TreeMap<String,Object>();for(String key:List.of("id","entry_date","direction","voucher_id","entry_amount","booked","reversal_of_voucher_id","allocation_no","amount_local","amount_original","original_currency_id","auxiliary_role","party_id_snapshot","source_snapshot")){Object value=row.getObject(key);fact.put(key,value==null?null:value instanceof BigDecimal number?number.toPlainString():value.toString());}
                try{digest.update((byte)'\n');digest.update(json.writeValueAsBytes(fact));if(matchesOriginal||scope.originalCurrencyId()!=null&&originalUnit==null){var selected=new TreeMap<>(fact);selected.remove("entry_amount");originalDigest.update((byte)'\n');originalDigest.update(json.writeValueAsBytes(selected));}}catch(Exception error){throw new IllegalStateException("账载来源摘要生成失败",error);}
            });
        boolean evidence=count[0]>0||zeroProof>0,originalEvidence=(originalCount[0]>0||!originalZero.isEmpty())&&scope.originalCurrencyId()!=null;
        String fingerprint=HexFormat.of().formatHex(digest.digest());
        String basis="同一已记账GL分配；借方为正，贷方为负；本币与真实原币分别读取，不按外币科目名称/汇率反推。"+closing.basis();
        if(!missing.closingComplete())basis+="；所选科目有"+missing.opening()+"笔期初来源、"+missing.movement()+"笔本期来源尚未完整分配真实辅助对象，不能把已分配部分作为完整往来余额";
        boolean openingKnown=opening.complete()&&missing.openingComplete(),periodKnown=period.complete()&&missing.movementComplete(),closingKnown=closing.complete()&&missing.closingComplete();
        return new Balance(scope,amounts(local,evidence,openingKnown,periodKnown,closingKnown),amounts(original,originalEvidence,openingKnown&&!unknownOriginal[0],periodKnown&&!unknownOriginal[1],closingKnown&&!unknownOriginal[0]&&!unknownOriginal[1]),count[0],fingerprint,basis,HexFormat.of().formatHex(originalDigest.digest()));
    }
    private static BigDecimal[] zeros(){return new BigDecimal[]{BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO};}
    private static void add(BigDecimal[] amounts,BigDecimal value,int direction,boolean prior){if(prior)amounts[0]=amounts[0].add(value.multiply(BigDecimal.valueOf(direction)));else if(direction>0)amounts[1]=amounts[1].add(value);else amounts[2]=amounts[2].add(value);}
    private static Amounts amounts(BigDecimal[] values,boolean evidence,boolean opening,boolean period,boolean closing){return new Amounts(evidence&&opening?values[0]:null,evidence&&period?values[1]:null,evidence&&period?values[2]:null,evidence&&closing?values[0].add(values[1]).subtract(values[2]):null,evidence&&opening&&period&&closing);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
