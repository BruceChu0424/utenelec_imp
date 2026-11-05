package com.uten.imp.application.port;
import com.uten.imp.common.finance.AccountingExpensePurpose;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;

/** Original reimbursement facts and actions; the application domain does not calculate another claim. */
public interface FinanceApplicationExpensePort {
    void verifyInvoice(UUID claimId,UUID invoiceId,Long expectedVersion,String result,String remark);
    java.util.Map<String,Object> detail(UUID claimId);
    /** For an already-authorized application view; denied native rows are absent, not a failed enclosing command. */
    Optional<Map<String,Object>> optionalDetail(UUID claimId);
    record Source(UUID id,String billNo,UUID applicantId,String applicantName,UUID departmentId,String title,String status,
            Instant createdAt,UUID currencyId,BigDecimal amount,String fingerprint,Map<String,Object> facts) { }
    Source source(UUID id,boolean forUpdate);
    void submit(UUID id);
    void withdraw(UUID id);
    void decideFromApplication(UUID id,boolean approved,String reason);
    UUID pay(UUID id,UUID accountId,UUID styleId,LocalDate date,AccountingExpensePurpose purpose);
    void paymentReversed(UUID id,UUID financeExpenseId,String reason);
}
