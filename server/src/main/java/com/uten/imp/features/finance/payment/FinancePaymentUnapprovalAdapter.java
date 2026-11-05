package com.uten.imp.features.finance.payment;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class FinancePaymentUnapprovalAdapter implements DocumentUnapprovalPort {
    private final FinancePaymentService service;
    @PersistenceContext private EntityManager em;
    @Override public String family() { return "financePayment"; }
    @Override public String permission() { return "finance_payment"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.FIN_PAYMENT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("finance_payments",null,
        List.of("bill_date","supplier_id","account_id","counterpart_account_id","currency_id","exchange_rate","amount_original","amount_local","account_currency_id","account_exchange_rate","account_amount","account_amount_local","bank_fee_account_amount","bank_fee_local","bank_reference","bank_booked_at","gl_account_style_id","gl_ap_style_id","gl_fx_style_id","gl_bank_fee_style_id","payment_method_id","payment_method_legacy_id","invoice_no","operator_name","operator_id","maker_id","source_remark","remark","create_request_hash"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("finance_payment_lines","payment_id",
        List.of("bill_date","applied_ledger_id","applied_bill_no","supplier_id","line_no","amount_original","amount_local",
            "cash_rate","recognition_rate","applied_amount_local","exchange_diff","bank_basis_before_original","bank_basis_before_local",
            "bank_basis_after_original","bank_basis_after_local","remark"),true,true); }

    @Override public void afterDraftCreated(UUID originalId,UUID draftId) {
        // Match normal native creation: the header starts at authority 0 while
        // its AP lines are assembled. The real line sources must exist before
        // the v2 guard can distinguish AP settlement from supplier advances.
        int changed=em.createNativeQuery("""
            UPDATE finance_payments draft SET amount_authority_version=source.amount_authority_version
            FROM finance_payments source
            WHERE draft.id=:draft AND source.id=:original AND draft.status=0 AND source.status=-1
              AND NOT draft.is_deleted AND NOT source.is_deleted AND draft.amount_authority_version=0
              AND (draft.supplier_id,draft.account_id,draft.currency_id,draft.exchange_rate,
                   draft.amount_original,draft.amount_local,draft.account_currency_id,draft.account_exchange_rate,
                   draft.account_amount,draft.account_amount_local,draft.bank_fee_account_amount,draft.bank_fee_local,
                   draft.bank_reference,draft.bank_booked_at,draft.gl_account_style_id,draft.gl_ap_style_id,
                   draft.gl_fx_style_id,draft.gl_bank_fee_style_id)
                  IS NOT DISTINCT FROM
                  (source.supplier_id,source.account_id,source.currency_id,source.exchange_rate,
                   source.amount_original,source.amount_local,source.account_currency_id,source.account_exchange_rate,
                   source.account_amount,source.account_amount_local,source.bank_fee_account_amount,source.bank_fee_local,
                   source.bank_reference,source.bank_booked_at,source.gl_account_style_id,source.gl_ap_style_id,
                   source.gl_fx_style_id,source.gl_bank_fee_style_id)
            """).setParameter("draft",draftId).setParameter("original",originalId).executeUpdate();
        if(changed!=1)throw new ApiException(ErrorCode.CONFLICT,"反审付款草稿的银行事实与原来源不一致，本次未生成草稿");
    }
}
