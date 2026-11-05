package com.uten.imp.testsupport;

import com.uten.imp.application.port.NativeFinancialPostingAccountPort;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

/** Completes the original native approval callback after a raw source fixture. */
public final class NativeArApApprovalFixture {
    private NativeArApApprovalFixture() { }
    public static void capture(JdbcTemplate jdbc,TxSessionVars transactionIdentity,
            NativeFinancialPostingAccountPort accounts,UUID ledger) {
        transactionIdentity.bind();
        String original=jdbc.queryForObject("SELECT to_jsonb(l)::text FROM ar_ap_ledger l WHERE id=?",String.class,ledger);
        UUID currency=jdbc.queryForObject("SELECT currency_id FROM ar_ap_ledger WHERE id=?",UUID.class,ledger);
        accounts.captureArAp(ledger);
        var frozen=accounts.frozenArAp(ledger);
        assertThat(frozen).as("the original source approval owns its actual account correspondence").isNotNull();
        assertThat(frozen.styleId()).isNotNull();
        assertThat(frozen.originalCurrencyId()).isEqualTo(currency);
        assertThat(jdbc.queryForObject("SELECT evidence_kind FROM finance_native_debt_accounts WHERE ledger_id=?",String.class,ledger)).isEqualTo("NATIVE_APPROVAL");
        assertThat(jdbc.queryForObject("SELECT to_jsonb(l)::text FROM ar_ap_ledger l WHERE id=?",String.class,ledger)).isEqualTo(original);
    }
}
