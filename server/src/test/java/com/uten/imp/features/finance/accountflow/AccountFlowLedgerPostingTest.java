package com.uten.imp.features.finance.accountflow;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** ADR-112 / dup-backend-split-04: 七类资金单据共用的过账入口, 币种与状态规则只写一次。 */
class AccountFlowLedgerPostingTest {

    private static final UUID ACCOUNT = UUID.randomUUID();
    private static final UUID BASE = UUID.randomUUID();
    private static final UUID USD = UUID.randomUUID();
    private static final OffsetDateTime BOOKED = OffsetDateTime.parse("2026-09-23T00:00:00Z");

    @Test
    void baseAccountRecordsTheLocalAmountForBothBalanceAndFlow() {
        Harness h = harness(BASE, true);
        var posted = h.ledger.post(AccountPosting.out("PAYMENT", UUID.randomUUID(), "CF-1", ACCOUNT)
                .rule(AccountPosting.CurrencyRule.BASE_OR_DOCUMENT_CURRENCY, USD)
                .amounts(new BigDecimal("30"), new BigDecimal("216.0000"))
                .bookedAt(BOOKED));

        assertThat(posted.accountAmount()).isEqualByComparingTo("216");
        verify(h.update).setParameter("balanceDelta", new BigDecimal("-216.0000"));
        verify(h.update).setParameter("totalDelta", new BigDecimal("216.0000"));
        verify(h.insert).setParameter("outAmount", new BigDecimal("216.0000"));
        verify(h.insert).setParameter("inAmount", BigDecimal.ZERO);
        verify(h.insert).setParameter("amountLocal", new BigDecimal("216.0000"));
        verify(h.insert).setParameter("currencyId", BASE);
        assertThat(h.sql).anySatisfy(sql -> assertThat(sql).contains("payments_total = COALESCE(payments_total, 0)"));
    }

    @Test
    void sameCurrencyForeignAccountRecordsTheOriginalAmount() {
        Harness h = harness(USD, false);
        h.ledger.post(AccountPosting.in("RECEIPT", UUID.randomUUID(), "XS-1", ACCOUNT)
                .rule(AccountPosting.CurrencyRule.BASE_OR_DOCUMENT_CURRENCY, USD)
                .amounts(new BigDecimal("30"), new BigDecimal("216"))
                .bookedAt(BOOKED));

        // 金额原样入账, 只补齐 4 位显示位数。
        verify(h.update).setParameter("balanceDelta", new BigDecimal("30.0000"));
        verify(h.insert).setParameter("inAmount", new BigDecimal("30.0000"));
        verify(h.insert).setParameter("amountLocal", new BigDecimal("216.0000"));
        assertThat(h.sql).anySatisfy(sql -> assertThat(sql).contains("receipts_total = COALESCE(receipts_total, 0)"));
    }

    @Test
    void thirdCurrencyAndNonBaseBaseOnlyAccountsFailBeforeAnyWrite() {
        Harness third = harness(UUID.randomUUID(), false);
        assertThatThrownBy(() -> third.ledger.post(AccountPosting.in("RECEIPT", UUID.randomUUID(), "XS-1", ACCOUNT)
                .rule(AccountPosting.CurrencyRule.BASE_OR_DOCUMENT_CURRENCY, USD)
                .amounts(BigDecimal.ONE, BigDecimal.ONE).bookedAt(BOOKED)))
                .isInstanceOf(ApiException.class).hasMessageContaining("第三币种");
        verify(third.update, never()).executeUpdate();

        Harness foreign = harness(USD, false);
        assertThatThrownBy(() -> foreign.ledger.post(AccountPosting.out("EXPENSE", UUID.randomUUID(), "FY-1", ACCOUNT)
                .rule(AccountPosting.CurrencyRule.BASE_ONLY, USD)
                .amounts(BigDecimal.ONE, BigDecimal.ONE).bookedAt(BOOKED).label("费用付款账户")))
                .isInstanceOf(ApiException.class).hasMessageContaining("费用付款账户必须是启用的本位币账户");
        verify(foreign.insert, never()).executeUpdate();

        Harness frozen = harness(BASE, true);
        assertThatThrownBy(() -> frozen.ledger.post(AccountPosting.in("RECEIPT", UUID.randomUUID(), "XS-1", ACCOUNT)
                .rule(AccountPosting.CurrencyRule.ACCOUNT_CURRENCY, USD)
                .amounts(BigDecimal.ONE, BigDecimal.ONE).bookedAt(BOOKED).label("收款账户")))
                .isInstanceOf(ApiException.class).hasMessageContaining("收款账户或其币种已变化");
    }

    @Test
    void inactiveAccountIsRejectedByTheSingleLockQuery() {
        Harness h = harness(BASE, true);
        when(h.lock.getResultList()).thenReturn(List.of());
        assertThatThrownBy(() -> h.ledger.post(AccountPosting.in("INCOME", UUID.randomUUID(), "SR-1", ACCOUNT)
                .amounts(BigDecimal.ONE, BigDecimal.ONE).bookedAt(BOOKED).label("其它收入收款账户")))
                .isInstanceOf(ApiException.class).hasMessageContaining("其它收入收款账户不存在、已停用或币种已停用");
        assertThat(h.sql).anySatisfy(sql -> assertThat(sql)
                .contains("account.status = '使用'").contains("currency.status = '使用'")
                .contains("FOR UPDATE OF account"));
    }

    @Test
    void adjustmentUsesTheAdjustmentTotalAndSignedFlow() {
        Harness h = harness(BASE, true);
        UUID actor = UUID.randomUUID();
        h.ledger.post(AccountPosting.adjustment("BALANCE_ADJUSTMENT", UUID.randomUUID(), "JZ-1", ACCOUNT)
                .amounts(new BigDecimal("-12.5"), new BigDecimal("-12.5")).bookedAt(BOOKED).actor(actor));

        verify(h.update).setParameter("balanceDelta", new BigDecimal("-12.5000"));
        verify(h.update).setParameter("totalDelta", new BigDecimal("-12.5000"));
        verify(h.update).setParameter("actor", actor);
        verify(h.insert).setParameter("outAmount", new BigDecimal("12.5000"));
        verify(h.insert).setParameter("amountLocal", new BigDecimal("12.5000"));
        verify(h.insert).setParameter("entryKind", "ADJUSTMENT");
        assertThat(h.sql).anySatisfy(sql -> assertThat(sql).contains("balance_adjustments_total"));
    }

    @Test
    void nonPositivePostingIsRejected() {
        Harness h = harness(BASE, true);
        assertThatThrownBy(() -> h.ledger.post(AccountPosting.out("EXPENSE", UUID.randomUUID(), "FY-1", ACCOUNT)
                .amounts(BigDecimal.ZERO, BigDecimal.ZERO).bookedAt(BOOKED)))
                .isInstanceOf(ApiException.class).hasMessageContaining("必须大于 0");
    }

    private static Harness harness(UUID currency, boolean base) {
        EntityManager em = mock(EntityManager.class);
        Query lock = query();
        Query update = query();
        Query insert = query();
        when(lock.getResultList()).thenReturn(List.<Object[]>of(new Object[]{ACCOUNT, currency, base, null}));
        when(update.executeUpdate()).thenReturn(1);
        when(insert.executeUpdate()).thenReturn(1);
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            sql.add(statement);
            if (statement.contains("FROM accounts account")) return lock;
            if (statement.contains("UPDATE accounts")) return update;
            if (statement.contains("INSERT INTO finance_reconciliations")) return insert;
            throw new AssertionError("unexpected SQL: " + statement);
        });
        return new Harness(new AccountFlowLedgerService(em), lock, update, insert, sql);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }

    private record Harness(AccountFlowLedgerService ledger, Query lock, Query update, Query insert, List<String> sql) {
    }
}
