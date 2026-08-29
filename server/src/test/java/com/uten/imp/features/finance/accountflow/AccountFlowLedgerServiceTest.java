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
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AccountFlowLedgerServiceTest {

    @Test
    void appendsStableMirroredReversalsWithoutMutatingOriginalPostings() {
        EntityManager em = mock(EntityManager.class);
        Query advisory = query();
        Query locked = query();
        Query insertIncomingReversal = query();
        Query insertOutgoingReversal = query();
        UUID sourceId = UUID.randomUUID();
        UUID incomingPostingId = UUID.randomUUID();
        UUID outgoingPostingId = UUID.randomUUID();
        UUID incomingAccountId = UUID.randomUUID();
        UUID outgoingAccountId = UUID.randomUUID();
        OffsetDateTime reversalAt = OffsetDateTime.parse("2026-08-28T10:15:30+08:00");
        List<String> sql = new ArrayList<>();
        AtomicInteger inserts = new AtomicInteger();

        when(advisory.getSingleResult()).thenReturn(1L);
        when(locked.getResultList()).thenReturn(List.of(
                row(incomingPostingId, "YC-1", incomingAccountId,
                        "100.0000", "0", "POSTING", null),
                row(outgoingPostingId, "YC-1", outgoingAccountId,
                        "0", "100.0000", "POSTING", null)));
        when(insertIncomingReversal.executeUpdate()).thenReturn(1);
        when(insertOutgoingReversal.executeUpdate()).thenReturn(1);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            sql.add(statement);
            if (statement.contains("pg_advisory_xact_lock")) return advisory;
            if (statement.contains("FROM finance_reconciliations")) return locked;
            if (statement.contains("INSERT INTO finance_reconciliations")) {
                return inserts.getAndIncrement() == 0
                        ? insertIncomingReversal : insertOutgoingReversal;
            }
            throw new AssertionError("unexpected SQL: " + statement);
        });

        int reversed = new AccountFlowLedgerService(em).reverse(
                "BANK_TRANSFER", sourceId, reversalAt, "银行转账红冲");

        assertThat(reversed).isEqualTo(2);
        assertThat(sql).anySatisfy(statement -> assertThat(statement)
                .contains("ORDER BY reconciliation.account_id NULLS LAST")
                .contains("reconciliation.id")
                .contains("FOR UPDATE"));
        assertThat(sql).noneMatch(statement ->
                statement.contains("DELETE FROM finance_reconciliations")
                        || statement.contains("UPDATE finance_reconciliations"));

        verify(insertIncomingReversal).setParameter(
                "reversalOfId", incomingPostingId);
        verify(insertIncomingReversal).setParameter(
                "inAmount", BigDecimal.ZERO);
        verify(insertIncomingReversal).setParameter(
                "outAmount", new BigDecimal("100.0000"));
        verify(insertOutgoingReversal).setParameter(
                "reversalOfId", outgoingPostingId);
        verify(insertOutgoingReversal).setParameter(
                "inAmount", new BigDecimal("100.0000"));
        verify(insertOutgoingReversal).setParameter(
                "outAmount", BigDecimal.ZERO);
        verify(insertIncomingReversal).setParameter("reversalAt", reversalAt);
        verify(insertOutgoingReversal).setParameter("reversalAt", reversalAt);
        verify(insertIncomingReversal).setParameter(
                "amountLocal", new BigDecimal("100.0000"));
        verify(insertOutgoingReversal).setParameter(
                "amountLocal", new BigDecimal("100.0000"));
    }

    @Test
    void rejectsMissingPosting() {
        Fixture fixture = fixture(List.of());

        assertThatThrownBy(() -> fixture.service().reverse(
                "PAYMENT", UUID.randomUUID(), OffsetDateTime.now(), "付款红冲"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("原始入账缺失");
        verify(fixture.insert(), never()).executeUpdate();
    }

    @Test
    void rejectsAnAlreadyReversedSourceBeforeWritingAnotherRow() {
        UUID postingId = UUID.randomUUID();
        UUID accountId = UUID.randomUUID();
        Fixture fixture = fixture(List.<Object[]>of(
                row(postingId, "CF-1", accountId,
                        "0", "30.0000", "POSTING", null),
                row(UUID.randomUUID(), "CF-1", accountId,
                        "30.0000", "0", "REVERSAL", postingId)));

        assertThatThrownBy(() -> fixture.service().reverse(
                "PAYMENT", UUID.randomUUID(), OffsetDateTime.now(), "付款红冲"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("已经存在反向分录");
        verify(fixture.insert(), never()).executeUpdate();
    }

    @Test
    void rejectsDuplicatePostingAccountsAndAmbiguousMoneyShapes() {
        UUID accountId = UUID.randomUUID();
        Fixture duplicate = fixture(List.<Object[]>of(
                row(UUID.randomUUID(), "CF-1", accountId,
                        "0", "10.0000", "POSTING", null),
                row(UUID.randomUUID(), "CF-1", accountId,
                        "0", "20.0000", "POSTING", null)));
        Fixture ambiguous = fixture(List.<Object[]>of(
                row(UUID.randomUUID(), "CF-2", UUID.randomUUID(),
                        "10.0000", "20.0000", "POSTING", null)));

        assertThatThrownBy(() -> duplicate.service().reverse(
                "PAYMENT", UUID.randomUUID(), OffsetDateTime.now(), "付款红冲"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("账户缺失或重复");
        assertThatThrownBy(() -> ambiguous.service().reverse(
                "PAYMENT", UUID.randomUUID(), OffsetDateTime.now(), "付款红冲"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("必须且只能有一个正向金额");
    }

    private static Fixture fixture(List<Object[]> rows) {
        EntityManager em = mock(EntityManager.class);
        Query advisory = query();
        Query locked = query();
        Query insert = query();
        when(advisory.getSingleResult()).thenReturn(1L);
        when(locked.getResultList()).thenReturn(rows);
        when(insert.executeUpdate()).thenReturn(1);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            if (statement.contains("pg_advisory_xact_lock")) return advisory;
            if (statement.contains("FROM finance_reconciliations")) return locked;
            if (statement.contains("INSERT INTO finance_reconciliations")) return insert;
            throw new AssertionError("unexpected SQL: " + statement);
        });
        return new Fixture(new AccountFlowLedgerService(em), insert);
    }

    private static Object[] row(
            UUID id,
            String billNo,
            UUID accountId,
            String inAmount,
            String outAmount,
            String entryKind,
            UUID reversalOfId) {
        return new Object[]{
                id, billNo, accountId, "CHK", "对方单位",
                new BigDecimal(inAmount), new BigDecimal(outAmount),
                "来源", "备注", 21, UUID.randomUUID(),
                new BigDecimal(inAmount).add(new BigDecimal(outAmount)),
                entryKind, reversalOfId
        };
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }

    private record Fixture(AccountFlowLedgerService service, Query insert) {
    }
}
