package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GlPostingServicePaymentAccountingTest {

    @Test
    void paymentPostingFailsClosedBeforeDeleteWhenARequiredStyleIsUnavailable() {
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

        assertThat(sqlStatements).hasSize(4);
        assertThat(sqlStatements.getLast())
                .contains("WITH required_role(role_key)")
                .contains("FROM finance_payments payment")
                .contains("'AP_CONTROL'")
                .contains("'FX_GAIN_LOSS'")
                .contains("system_posting_style_id(required.role_key)");
        assertThat(sqlStatements).noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers"));
    }

    @Test
    void historicalPaymentAmountsBlockRegenerationBeforeExistingVouchersAreDeleted() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            return queryReturning(sql.contains("amount_authority_version NOT IN(1,2)") ? 2L : 0L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .generate("2026-08"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("2 张历史付款")
                .hasMessageContaining("禁止重生成总账凭证");

        // Customer-advance and legacy V0 receipt-GL reconciliation are separate
        // preflights before payment authority; neither may delete vouchers.
        assertThat(sqlStatements).hasSize(9);
        assertThat(sqlStatements.getLast())
                .contains("FROM finance_payments payment")
                .contains("payment.amount_authority_version NOT IN(1,2)");
        assertThat(sqlStatements).noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers"));
    }

    @Test
    void paymentPostingSeparatesBookReductionCashAndFxAndStaysBalanced() {
        EntityManager em = mock(EntityManager.class);
        Query query = queryReturning(0L);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });

        new GlPostingService(em, mock(TxSessionVars.class)).generate("2026-08");

        String paymentEntries = sqlStatements.stream()
                .filter(sql -> sql.contains("INSERT INTO gl_entries"))
                .filter(sql -> sql.contains("finance_payment_lines"))
                .filter(sql -> sql.contains("付款汇兑损益"))
                .findFirst()
                .orElseThrow();
        assertThat(paymentEntries)
                .contains("line.amount_local-COALESCE(line.exchange_diff,0)")
                .contains("t.amount_authority_version=1")
                .contains("SELECT v.id, 2, acct.style_id, -1, t.amount_local")
                .contains("SUM(line.exchange_diff)")
                .contains("CASE WHEN x.diff>0 THEN 1 ELSE -1 END")
                .contains("ABS(x.diff)")
                .contains("style.id=account_style_id(t.account_id)")
                .contains("system_posting_style_id('AP_CONTROL')")
                .contains("system_posting_style_id('FX_GAIN_LOSS')")
                .contains("COALESCE(line.is_deleted,false)=false");

        BigDecimal cashLocal = new BigDecimal("216.0000");
        BigDecimal appliedLocal = new BigDecimal("210.0000");
        BigDecimal exchangeDiff = cashLocal.subtract(appliedLocal);
        assertThat(appliedLocal.add(exchangeDiff)).isEqualByComparingTo(cashLocal);
        assertThat(exchangeDiff).isEqualByComparingTo("6.0000");
    }

    @Test
    void paymentReverseProjectionUsesThePeriodLockBeforeDeletingItsAutoVoucher() {
        EntityManager em = mock(EntityManager.class);
        Query query = queryReturning(0L);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });
        UUID paymentId = UUID.randomUUID();

        new GlPostingService(em, mock(TxSessionVars.class)).removePaymentDoc(
                paymentId, "CF-LOCK-1",
                com.uten.imp.common.time.BusinessTime.today());

        assertThat(sqlStatements).hasSize(3);
        assertThat(sqlStatements.getFirst()).contains("pg_advisory_xact_lock");
        assertThat(sqlStatements.get(1))
                .contains("FROM gl_vouchers voucher")
                .contains("NOT EXISTS")
                .contains("entry.source_doc_id=:sourceDocId");
        assertThat(sqlStatements.getLast())
                .contains("DELETE FROM gl_vouchers voucher")
                .contains("voucher.source_type=:sourceType")
                .contains("voucher.source_doc_id=:sourceDocId")
                .contains("entry.source_doc_id=:sourceDocId");
        verify(query).setParameter("key", "uten:gl:auto-period:"
                + java.time.YearMonth.from(com.uten.imp.common.time.BusinessTime.today()));
        verify(query, org.mockito.Mockito.times(2)).setParameter("sourceType", "PAYMENT");
        verify(query, org.mockito.Mockito.times(2)).setParameter("entrySourceType", "PAYMENT");
        verify(query, org.mockito.Mockito.times(2)).setParameter("sourceDocId", paymentId);
    }

    @Test
    void mixedDocumentEntriesFailClosedBeforeTheExactProjectionDelete() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            return queryReturning(sql.contains(
                    "entry.source_doc_id IS DISTINCT FROM :sourceDocId") ? 1L : 0L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .removeAutoProjection(
                        "PAYMENT", UUID.randomUUID(), "CF-MIXED-1",
                        com.uten.imp.common.time.BusinessTime.today()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("归属不一致")
                .hasMessageContaining("禁止物理删除");

        assertThat(sqlStatements).hasSize(2);
        assertThat(sqlStatements.getFirst()).contains("pg_advisory_xact_lock");
        assertThat(sqlStatements.getLast())
                .contains("NOT EXISTS")
                .contains("OR EXISTS")
                .contains("entry.source_doc_type IS DISTINCT FROM :entrySourceType")
                .contains("entry.source_doc_id IS DISTINCT FROM :sourceDocId")
                .contains("entry.period IS DISTINCT FROM :period");
        assertThat(sqlStatements).noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers"));
    }

    @Test
    void confirmedExpenseBlocksRegenerationBeforeAnyVoucherDelete() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            return queryReturning(sql.contains("FROM finance_expenses expense")
                    && sql.contains("expense.gl_status=2") ? 1L : 0L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .generate("2026-08"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("已财务确认")
                .hasMessageContaining("禁止物理删除");

        assertThat(sqlStatements).hasSize(3);
        assertThat(sqlStatements.getFirst()).contains("pg_advisory_xact_lock");
        assertThat(sqlStatements.getLast())
                .contains("expense.status=1")
                .contains("expense.gl_status=2")
                .contains("COALESCE(expense.is_deleted,false)=false");
        assertThat(sqlStatements).noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers"));
    }

    @Test
    void expenseConfirmationRejectsAProjectionThatIsNotExactAndBalanced() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return queryReturning(0L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .requireConfirmableExpenseVoucher(
                        UUID.randomUUID(), UUID.randomUUID(), "YF-26080001",
                        LocalDate.of(2026, 8, 9)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("归属不符")
                .hasMessageContaining("借贷不平");

        assertThat(sqlStatements).hasSize(2);
        assertThat(sqlStatements.getFirst()).contains("pg_advisory_xact_lock");
        assertThat(sqlStatements.getLast())
                .contains("voucher.source_type='EXPENSE'")
                .contains("voucher.source_doc_id=:expenseId")
                .contains("entry.source_doc_id IS DISTINCT FROM :expenseId")
                .contains("entry.period IS DISTINCT FROM :period")
                .contains("entry.direction=1")
                .contains("entry.direction=-1")
                .contains("SUM(entry.direction * entry.amount)");
    }

    private static Query queryReturning(long result) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(result);
        return query;
    }
}
