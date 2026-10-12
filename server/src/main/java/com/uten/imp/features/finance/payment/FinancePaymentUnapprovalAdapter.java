package com.uten.imp.features.finance.payment;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class FinancePaymentUnapprovalAdapter implements DocumentUnapprovalPort {
    private final FinancePaymentService service;
    @Override public String family() { return "financePayment"; }
    @Override public String permission() { return "finance_payment"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.FIN_PAYMENT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("finance_payments",null,
        List.of("bill_date","supplier_id","account_id","counterpart_account_id","currency_id","exchange_rate","amount_original","amount_local","amount_authority_version","account_currency_id","account_exchange_rate","account_amount","account_amount_local","bank_fee_account_amount","bank_fee_local","bank_reference","bank_booked_at","gl_account_style_id","gl_ap_style_id","gl_fx_style_id","gl_bank_fee_style_id","payment_method_id","payment_method_legacy_id","invoice_no","operator_name","operator_id","maker_id","source_remark","remark","create_request_hash"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("finance_payment_lines","payment_id",
        List.of("bill_date","applied_ledger_id","applied_bill_no","supplier_id","line_no","amount_original","amount_local",
            "cash_rate","recognition_rate","applied_amount_local","exchange_diff","bank_basis_before_original","bank_basis_before_local",
            "bank_basis_after_original","bank_basis_after_local","remark"),true,true); }
}
