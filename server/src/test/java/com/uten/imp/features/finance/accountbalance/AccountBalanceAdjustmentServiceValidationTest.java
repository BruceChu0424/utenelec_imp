package com.uten.imp.features.finance.accountbalance;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchRequest;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentItemRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;

class AccountBalanceAdjustmentServiceValidationTest {

    @Test
    void rejectsNonCurrentEffectiveDateBeforeAnyDatabaseWrite() {
        EntityManager em = mock(EntityManager.class);
        Query query = query();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        AccountBalanceAdjustmentService service = service(em);
        var request = request(
                BusinessTime.today().minusDays(1),
                List.of(item(UUID.randomUUID(), "0", "1")));

        assertThatThrownBy(() -> service.adjust(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("必须是上海业务今日");
    }

    @Test
    void rejectsDuplicateAccountsBeforeLocksOrWrites() {
        EntityManager em = mock(EntityManager.class);
        AccountBalanceAdjustmentService service = service(em);
        UUID accountId = UUID.randomUUID();
        var request = request(
                BusinessTime.today(),
                List.of(item(accountId, "0", "1"), item(accountId, "0", "2")));

        assertThatThrownBy(() -> service.adjust(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("同一账户不能")
                .hasMessageContaining("重复");
        verifyNoInteractions(em);
    }

    @Test
    void rejectsActiveAccountWithoutExplicitCurrency() {
        UUID accountId = UUID.randomUUID();
        AccountBalanceAdjustmentService service = configuredService(
                accountId,
                lockedRow(accountId, null, "ACCOUNT", "0"),
                List.of());

        assertThatThrownBy(() -> service.adjust(request(
                BusinessTime.today(), List.of(item(accountId, "0", "1")))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未设置币种")
                .hasMessageContaining("禁止猜测");
    }

    @Test
    void rejectsNonPostableAccountStyleBeforeWritingBalance() {
        UUID accountId = UUID.randomUUID();
        AccountBalanceAdjustmentService service = configuredService(
                accountId,
                lockedRow(accountId, UUID.randomUUID(), "EXPENSE", "0"),
                List.of());

        assertThatThrownBy(() -> service.adjust(request(
                BusinessTime.today(), List.of(item(accountId, "0", "1")))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("账户类叶子科目");
    }

    @Test
    void rejectsStaleExpectedBalanceForWholeBatch() {
        UUID accountId = UUID.randomUUID();
        AccountBalanceAdjustmentService service = configuredService(
                accountId,
                lockedRow(accountId, UUID.randomUUID(), "ACCOUNT", "5"),
                List.of());

        assertThatThrownBy(() -> service.adjust(request(
                BusinessTime.today(), List.of(item(accountId, "0", "1")))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("页面显示 0")
                .hasMessageContaining("当前实际 5");
    }

    @Test
    void reusedIdempotencyKeyWithDifferentHashIsRejected() {
        UUID accountId = UUID.randomUUID();
        AccountBalanceAdjustmentService service = configuredService(
                accountId,
                lockedRow(accountId, UUID.randomUUID(), "ACCOUNT", "0"),
                List.<Object[]>of(new Object[]{UUID.randomUUID(), "different-request-hash"}));

        assertThatThrownBy(() -> service.adjust(request(
                BusinessTime.today(), List.of(item(accountId, "0", "1")))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("幂等键已用于另一笔");
    }

    @Test
    void requestFingerprintLengthPrefixesFreeTextAndItemFields() {
        UUID accountId = UUID.randomUUID();
        var first = new AccountBalanceAdjustmentBatchRequest(
                "SELECTED", BusinessTime.today(), "核对|原因:一",
                "account-balance-hash-1", List.of(item(accountId, "1", "23")));
        var second = new AccountBalanceAdjustmentBatchRequest(
                "SELECTED", BusinessTime.today(), "核对|原因",
                "account-balance-hash-2", List.of(item(accountId, "12", "3")));

        org.assertj.core.api.Assertions.assertThat(
                        AccountBalanceAdjustmentService.requestFingerprint(first))
                .isNotEqualTo(AccountBalanceAdjustmentService.requestFingerprint(second));
    }

    @Test
    void rejectsDeltaOrConvertedLocalAmountOutsideNumericBoundary() {
        assertThatThrownBy(() -> AccountBalanceAdjustmentService.exactMoney(
                new BigDecimal("199999999999999.9998")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("14 位整数");
    }

    @Test
    void baseCurrencyUsesIdentityWithoutAReferenceRate() {
        var evidence = AccountBalanceAdjustmentService.resolveLocalAmountEvidence(
                true, "ZH000001",
                new BigDecimal("5.0000"), null);

        assertThat(evidence.localDelta()).isEqualByComparingTo("5.0000");
        assertThat(evidence.exchangeRateSnapshot()).isEqualByComparingTo("1.000000");
        assertThat(evidence.basis()).isEqualTo("BASE_CURRENCY_IDENTITY");
    }

    @Test
    void unchangedForeignAccountNeedsNoRateOrLocalAmount() {
        var evidence = AccountBalanceAdjustmentService.resolveLocalAmountEvidence(
                false, "ZH000002",
                new BigDecimal("0.0000"), null);

        assertThat(evidence.localDelta()).isEqualByComparingTo("0.0000");
        assertThat(evidence.exchangeRateSnapshot()).isNull();
        assertThat(evidence.basis()).isEqualTo("NO_CHANGE");
    }

    @Test
    void changedForeignAccountRequiresExplicitSameDirectionLocalAmount() {
        assertThatThrownBy(() -> AccountBalanceAdjustmentService.resolveLocalAmountEvidence(
                false, "ZH000002",
                new BigDecimal("10.0000"), null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("本位币调账额");

        assertThatThrownBy(() -> AccountBalanceAdjustmentService.resolveLocalAmountEvidence(
                false, "ZH000002",
                new BigDecimal("10.0000"), new BigDecimal("-70.0000")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("方向必须一致");

        var evidence = AccountBalanceAdjustmentService.resolveLocalAmountEvidence(
                false, "ZH000002",
                new BigDecimal("10.0000"), new BigDecimal("70.0000"));
        assertThat(evidence.localDelta()).isEqualByComparingTo("70.0000");
        assertThat(evidence.exchangeRateSnapshot()).isNull();
        assertThat(evidence.basis()).isEqualTo("FINANCE_EXPLICIT_LOCAL");
    }

    @Test
    void requestFingerprintIncludesExplicitLocalAmount() {
        UUID accountId = UUID.randomUUID();
        var first = request(BusinessTime.today(), List.of(
                new AccountBalanceAdjustmentItemRequest(
                        accountId, BigDecimal.ZERO, BigDecimal.TEN,
                        new BigDecimal("70.0000"))));
        var second = request(BusinessTime.today(), List.of(
                new AccountBalanceAdjustmentItemRequest(
                        accountId, BigDecimal.ZERO, BigDecimal.TEN,
                        new BigDecimal("71.0000"))));

        assertThat(AccountBalanceAdjustmentService.requestFingerprint(first))
                .isNotEqualTo(AccountBalanceAdjustmentService.requestFingerprint(second));
    }

    private static AccountBalanceAdjustmentService service(EntityManager em) {
        return new AccountBalanceAdjustmentService(
                em,
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(DocNumberService.class),
                mock(GlPostingService.class));
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static AccountBalanceAdjustmentService configuredService(
            UUID accountId, Object[] accountRow, List<Object[]> existingRows) {
        EntityManager em = mock(EntityManager.class);
        Query advisory = query();
        Query existing = query();
        Query clearing = query();
        Query active = query();
        Query accounts = query();
        when(existing.getResultList()).thenReturn((List) existingRows);
        when(clearing.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        when(active.getResultList()).thenReturn(List.of(accountId));
        when(accounts.getResultList()).thenReturn(List.<Object[]>of(accountRow));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("WHERE idempotency_key=:key")) return existing;
            if (sql.contains("FROM system_posting_style_roles")) return clearing;
            if (sql.contains("SELECT id FROM accounts")) return active;
            if (sql.contains("SELECT account.id")) return accounts;
            return advisory;
        });
        GlPostingService gl = mock(GlPostingService.class);
        return new AccountBalanceAdjustmentService(
                em,
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(DocNumberService.class),
                gl);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);
        when(query.getResultList()).thenReturn(List.of());
        return query;
    }

    private static Object[] lockedRow(
            UUID accountId, UUID currencyId, String styleCategory, String balance) {
        UUID styleId = UUID.randomUUID();
        return new Object[]{
                accountId, "ZH000001", "测试账户", currencyId,
                currencyId == null ? null : "CNY",
                currencyId == null ? null : "人民币",
                currencyId != null,
                currencyId == null ? null : "使用",
                false,
                new BigDecimal(balance),
                styleId,
                styleCategory,
                "使用",
                false,
                false
        };
    }

    private static AccountBalanceAdjustmentBatchRequest request(
            java.time.LocalDate date, List<AccountBalanceAdjustmentItemRequest> items) {
        return new AccountBalanceAdjustmentBatchRequest(
                "SELECTED", date, "上线核对", "account-balance-test-1", items);
    }

    private static AccountBalanceAdjustmentItemRequest item(
            UUID accountId, String expected, String target) {
        return new AccountBalanceAdjustmentItemRequest(
                accountId, new BigDecimal(expected), new BigDecimal(target), null);
    }
}
