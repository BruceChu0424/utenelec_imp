package com.uten.imp.features.finance.other_income;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class FinanceOtherIncomeUnapprovalAdapter implements DocumentUnapprovalPort {
    private final FinanceOtherIncomeService service;
    @Override public String family() { return "financeOtherIncome"; }
    @Override public String permission() { return "finance_other_income"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.FIN_OTHER_INCOME; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("finance_other_incomes",null,
        List.of("bill_date","account_id","counterpart_account_id","currency_id","exchange_rate","amount_original","amount_local","receipt_method_id","receipt_method_legacy_id","operator_id","operator_name","maker_id","remark"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("finance_other_income_items","income_id",
        List.of("bill_date","income_style_id","department_id","counterpart_account_id","counterpart_name","qty","price","amount_original","amount_local","summary","line_no","remark"),false,true); }
}
