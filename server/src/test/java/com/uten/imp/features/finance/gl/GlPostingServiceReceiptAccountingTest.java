package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GlPostingServiceReceiptAccountingTest {

    @Test
    void arPostingFailsClosedBeforeDeleteWhenCoreStylesAreUnavailable() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            return queryReturning(sql.contains("FROM finance_expenses expense")
                    && sql.contains("expense.gl_status=2") ? 0L : 1L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .generate("2026-08"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("系统过账角色")
                .hasMessageContaining("科目 UUID");
        assertThat(sqlStatements).hasSize(4);
        assertThat(sqlStatements.getFirst())
                .contains("pg_advisory_xact_lock")
                .contains("hashtextextended");
        assertThat(sqlStatements.getLast())
                .contains("WITH required_role(role_key)")
                .contains("'AR_CONTROL'")
                .contains("'SALES_REVENUE'")
                .contains("system_posting_style_id(required.role_key)");
    }

    @Test
    void receiptPostingFailsClosedWhenRequiredAccountingStyleIsUnavailable() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            return queryReturning(sql.contains("WITH required_role(role_key)") ? 1L : 0L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .generate("2026-08"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("系统过账角色")
                .hasMessageContaining("科目 UUID");
        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("WITH required_role(role_key)")
                .contains("FROM finance_receipts receipt")
                .contains("'AR_CONTROL'")
                .contains("'BANK_FEE_EXPENSE'")
                .contains("'FX_GAIN_LOSS'"));
        assertThat(sqlStatements).hasSize(4);
        assertThat(sqlStatements.stream().noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers")
                || sql.contains("INSERT INTO gl_vouchers"))).isTrue();
    }

    @Test
    void receiptPostingUsesCarryingArReductionAndBalancesCashFeesAndFx() {
        EntityManager em = mock(EntityManager.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        Query query = mock(Query.class);
        List<String> sqlStatements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });

        new GlPostingService(em, tx).generate("2026-08");

        String arEntries = sqlStatements.stream()
                .filter(sql -> sql.contains("INSERT INTO gl_entries"))
                .filter(sql -> sql.contains("v.source_type = 'AR_POST'"))
                .findFirst()
                .orElseThrow();
        assertThat(arEntries)
                .contains("system_posting_style_id('AR_CONTROL')")
                .contains("system_posting_style_id('SALES_REVENUE')")
                .doesNotContain("path='");
        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("FROM ar_ap_ledger ledger")
                .contains("system_posting_style_id('AR_CONTROL')")
                .contains("system_posting_style_id('SALES_REVENUE')"));

        String receiptEntries = sqlStatements.stream()
                .filter(sql -> sql.contains("INSERT INTO gl_entries"))
                .filter(sql -> sql.contains("finance_receipt_lines"))
                .filter(sql -> sql.contains("收款汇兑损益"))
                .findFirst()
                .orElseThrow();

        assertThat(receiptEntries)
                .contains("SELECT v.id, 1, acct.style_id, 1, t.amount_local")
                .contains("style.id=account_style_id(t.account_id)")
                .contains("style.status='使用'")
                .contains("system_posting_style_id('AR_CONTROL')")
                .contains("SUM(i.applied_amount_local)")
                .contains("COALESCE(i.is_deleted,false)=false")
                .contains("SELECT v.id, 3, fee.id, 1, t.bank_fee")
                .contains("SELECT v.id, 4, t.other_fee_style_id, 1, t.other_fee")
                .contains("SUM(i.exchange_diff)")
                .contains("CASE WHEN x.diff>0 THEN -1 ELSE 1 END")
                .contains("ABS(x.diff)")
                .contains("system_posting_style_id('BANK_FEE_EXPENSE')")
                .contains("system_posting_style_id('FX_GAIN_LOSS')")
                .contains("t.status=1")
                .contains("COALESCE(t.is_deleted,false)=false")
                .doesNotContain("THEN (SELECT COALESCE(SUM(i.amount_local),0)");

        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("FROM finance_receipts receipt")
                .contains("NOT EXISTS")
                .contains("style.id=account_style_id(receipt.account_id)")
                .contains("system_posting_style_id('AR_CONTROL')")
                .contains("system_posting_style_id('BANK_FEE_EXPENSE')")
                .contains("system_posting_style_id('FX_GAIN_LOSS')")
                .contains("style.id=receipt.other_fee_style_id"));
        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("invalid_voucher")
                .contains("HAVING COUNT(entry.id)<2")
                .contains("SUM(entry.direction*entry.amount)"));

        // Example produced by the service settlement test:
        // cash 30 USD * 7.2 = 216; fee 2 USD * 7.2 = 14.4;
        // carrying AR reduction 32 USD * 7.0 = 224; FX gain = 6.4.
        BigDecimal cashDebit = new BigDecimal("216.0000");
        BigDecimal feeDebit = new BigDecimal("14.4000");
        BigDecimal arCredit = new BigDecimal("224.0000");
        BigDecimal exchangeDiff = cashDebit.add(feeDebit).subtract(arCredit);
        BigDecimal fxDebit = exchangeDiff.signum() < 0 ? exchangeDiff.abs() : BigDecimal.ZERO;
        BigDecimal fxCredit = exchangeDiff.signum() > 0 ? exchangeDiff : BigDecimal.ZERO;

        assertThat(cashDebit.add(feeDebit).add(fxDebit))
                .isEqualByComparingTo(arCredit.add(fxCredit));
        assertThat(exchangeDiff).isEqualByComparingTo("6.4000");
    }

    private static Query queryReturning(long result) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(result);
        return query;
    }
}
