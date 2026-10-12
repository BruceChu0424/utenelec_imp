package com.uten.imp.features.finance.receipt;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class FinanceReceiptUnapprovalAdapter implements DocumentUnapprovalPort {
    private final FinanceReceiptService service;
    @Override public String family() { return "financeReceipt"; }
    @Override public String permission() { return "finance_receipt"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.FIN_RECEIPT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("finance_receipts",null,
        List.of("bill_date","client_id","receipt_kind","sales_order_id","account_id","counterpart_account_id","currency_id","exchange_rate","amount_original","amount_local","bank_fee","other_fee","other_fee_style_id","receipt_method_id","receipt_method_legacy_id","invoice_no","operator_id","maker_id","source_remark","remark","settlement_authority_version","create_request_hash","settlement_channel","settlement_agent_supplier_id","settlement_agent_name_snapshot","settlement_rate_quote_direction","exchange_rate_source","exchange_rate_effective_at","bank_booked_at","bank_reference","agent_statement_no","account_currency_id","account_exchange_rate","account_exchange_rate_source","account_amount","account_amount_local","bank_fee_account_amount","other_fee_account_amount","fee_settlement_mode","fee_bearer","fee_payment_account_id","fee_account_currency_id","fee_account_exchange_rate","gl_account_style_id","gl_counter_style_id","gl_bank_fee_style_id","gl_fx_style_id","gl_fee_payment_style_id"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("finance_receipt_lines","receipt_id",
        List.of("bill_date","applied_ledger_id","applied_bill_no","client_id","currency_id","exchange_rate","line_no","amount_original","amount_local",
            "write_off_amount","write_off_local","applied_amount_local","exchange_diff","bank_basis_before_original","bank_basis_before_local",
            "bank_basis_after_original","bank_basis_after_local","remark"),true,true); }
}
