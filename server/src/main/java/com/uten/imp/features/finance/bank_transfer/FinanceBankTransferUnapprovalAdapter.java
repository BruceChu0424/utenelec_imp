package com.uten.imp.features.finance.bank_transfer;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class FinanceBankTransferUnapprovalAdapter implements DocumentUnapprovalPort {
    private final FinanceBankTransferService service;
    @Override public String family() { return "financeBankTransfer"; }
    @Override public String permission() { return "finance_bank_transfer"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.FIN_BANK_TRANSFER; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("finance_bank_transfers",null,
        List.of("bill_date","out_account_id","currency_id","exchange_rate","amount_original","amount_local","invoice_no","operator_id","maker_id","remark"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("finance_bank_transfer_lines","transfer_id",
        List.of("bill_date","in_account_id","occur_date","amount_original","amount_local","line_no","summary"),false,true); }
}
