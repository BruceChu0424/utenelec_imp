package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceApplicationExpensePort;
import com.uten.imp.common.finance.AccountingExpensePurpose;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.*;
import java.util.*;

/** Read and delegate within the owning claim feature. No duplicated pricing, invoice or cash posting. */
@Component @RequiredArgsConstructor
public class ExpenseApplicationSourceAdapter implements FinanceApplicationExpensePort {
    private final JdbcTemplate db;private final ObjectMapper json;private final ObjectProvider<ExpenseClaimService> claims;
    @Override public Source source(UUID id,boolean lock){
        var rows=db.queryForList("SELECT id,claim_no,applicant_id,applicant_name_snapshot,applicant_department_id,title,status,created_at,total_amount,remark FROM expense_claims WHERE id=? AND NOT is_deleted"+(lock?" FOR UPDATE":""),id);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"原报销申请不存在");var h=rows.getFirst();
        var currencies=db.queryForList("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);if(currencies.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"原报销本位币尚未核对");
        var facts=new LinkedHashMap<String,Object>();for(String key:List.of("id","claim_no","applicant_id","applicant_name_snapshot","applicant_department_id","title","remark"))facts.put(key,h.get(key));facts.put("amountOriginal",((BigDecimal)h.get("total_amount")).toPlainString());
        facts.put("items",db.queryForList("SELECT id,line_no,category,expense_date,description,amount::text FROM expense_claim_items WHERE claim_id=? ORDER BY line_no,id",id));
        // The native snapshot builder includes original invoices and custom columns, and excludes reviewer/lifecycle marks.
        facts.put("submittedFacts",claims.getObject().applicationBusinessSnapshot(id));
        String fingerprint;try{fingerprint=ImmutableDocumentStore.digest(json.writeValueAsBytes(facts));}catch(Exception e){throw new IllegalStateException("原报销事实无法校验",e);}
        return new Source(id,h.get("claim_no").toString(),(UUID)h.get("applicant_id"),h.get("applicant_name_snapshot").toString(),(UUID)h.get("applicant_department_id"),h.get("title").toString(),h.get("status").toString(),((Timestamp)h.get("created_at")).toInstant(),currencies.getFirst(),(BigDecimal)h.get("total_amount"),fingerprint,facts);
    }
    @Override public void submit(UUID id){claims.getObject().submit(id);}
    @Override public void withdraw(UUID id){claims.getObject().withdraw(id);}
    @Override public void verifyInvoice(UUID claimId,UUID invoiceId,Long version,String result,String remark){claims.getObject().verifyInvoice(claimId,invoiceId,new com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceVerifyRequest(version,result,remark));}
    @Override public Map<String,Object> detail(UUID claimId){return json.convertValue(claims.getObject().detail(claimId),new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});}
    @Override public void decideFromApplication(UUID id,boolean approved,String reason){claims.getObject().decideFromFinancialApplication(id,approved,reason);}
    @Override public UUID pay(UUID id,UUID account,UUID style,LocalDate date,AccountingExpensePurpose purpose){return claims.getObject().pay(id,new ExpenseClaimPaymentRequest(account,style,date,null,purpose.name())).financeExpenseId();}
    @Override public void paymentReversed(UUID id,UUID financeExpense,String reason){claims.getObject().paymentReversedFromFinancialApplication(id,financeExpense,reason);}
}
