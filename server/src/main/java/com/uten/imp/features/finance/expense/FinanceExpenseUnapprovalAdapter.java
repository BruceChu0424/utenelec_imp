package com.uten.imp.features.finance.expense;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class FinanceExpenseUnapprovalAdapter implements DocumentUnapprovalPort {
    private final FinanceExpenseService service;
    @Override public String family() { return "financeExpense"; }
    @Override public String permission() { return "finance_expense"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.FIN_EXPENSE; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("finance_expenses",null,
        List.of("bill_date","account_id","counterpart_account_id","currency_id","exchange_rate","amount_original","amount_local","payment_method_id","payment_method_legacy_id","operator_id","maker_id","remark"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("finance_expense_items","expense_id",
        List.of("bill_date","expense_style_id","department_id","counterpart_account_id","counterpart_name","qty","price","amount_original","amount_local","summary","line_no","remark"),false,true); }
}
