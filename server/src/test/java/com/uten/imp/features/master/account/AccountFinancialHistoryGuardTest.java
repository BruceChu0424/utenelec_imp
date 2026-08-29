package com.uten.imp.features.master.account;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AccountFinancialHistoryGuardTest {

    private AccountRepository repository;
    private EntityManager em;
    private Query flowCount;
    private Query documentCount;
    private Query adjustmentItemCount;
    private Query styleLookup;
    private Query hierarchyLock;
    private AccountService service;
    private Account account;

    @BeforeEach
    void setUp() {
        repository = mock(AccountRepository.class);
        em = mock(EntityManager.class);
        flowCount = query(0L);
        documentCount = query(1L);
        adjustmentItemCount = query(0L);
        styleLookup = mock(Query.class);
        hierarchyLock = query(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("PAYMENT_STYLE_HIERARCHY")) return hierarchyLock;
            if (sql.contains("FROM payment_styles")) return styleLookup;
            if (sql.contains("account_balance_adjustment_items")) return adjustmentItemCount;
            return sql.contains("SUM(fact_count)") ? documentCount : flowCount;
        });
        service = new AccountService(
                repository,
                mock(TxSessionVars.class),
                em,
                mock(MasterCodeService.class));

        account = new Account();
        account.setId(UUID.randomUUID());
        account.setName("美元账户");
        account.setStatus("使用");
        account.setCurrencyId(UUID.randomUUID());
        account.setInitBalance(BigDecimal.ZERO);
        account.setReceiptsTotal(BigDecimal.ZERO);
        account.setPaymentsTotal(BigDecimal.ZERO);
        when(repository.findById(account.getId())).thenReturn(Optional.of(account));
    }

    @Test
    void approvedFinancialDocumentPreventsAccountDeactivation() {
        authenticate("account:edit", "account:status");
        AccountSaveRequest request = unchangedRequest();
        request.setStatus("停用");

        assertThatThrownBy(() -> service.update(account.getId(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("已审核资金单据")
                .hasMessageContaining("不能停用");
        verify(repository, never()).save(account);
    }

    @Test
    void reversedFinancialDocumentStillFreezesHistoricalCurrency() {
        authenticate("account:edit");
        AccountSaveRequest request = unchangedRequest();
        request.setCurrencyId(UUID.randomUUID());

        assertThatThrownBy(() -> service.update(account.getId(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("币别不可修改");
        verify(repository, never()).save(account);
    }

    @Test
    void historicalFinancialFactFreezesOpeningBalanceEvenForBalanceAdjuster() {
        authenticate("account:edit", "account:balance:adjust");
        AccountSaveRequest request = unchangedRequest();
        request.setInitBalance(BigDecimal.ONE);

        assertThatThrownBy(() -> service.update(account.getId(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("期初余额不可修改");
        verify(repository, never()).save(account);
    }

    @Test
    void historicalFinancialFactFreezesAccountPostingStyle() {
        authenticate("account:edit");
        AccountSaveRequest request = unchangedRequest();
        request.setStyleId(UUID.randomUUID());

        assertThatThrownBy(() -> service.update(account.getId(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("会计科目不可修改");
        verify(repository, never()).save(account);
    }

    @Test
    void zeroDeltaVerificationFreezesHistoricalFieldsButDoesNotBlockDeactivation() {
        authenticate("account:edit", "account:status");
        when(documentCount.getSingleResult()).thenReturn(0L);
        when(adjustmentItemCount.getSingleResult()).thenReturn(1L);

        AccountSaveRequest currencyChange = unchangedRequest();
        currencyChange.setCurrencyId(UUID.randomUUID());
        assertThatThrownBy(() -> service.update(account.getId(), currencyChange))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("币别不可修改");

        AccountSaveRequest deactivate = unchangedRequest();
        deactivate.setStatus("禁用");
        service.update(account.getId(), deactivate);
        verify(repository).save(account);
    }

    @Test
    void disabledAccountCannotReactivateWithDisabledOrNonPostableCurrentStyle() {
        authenticate("account:edit", "account:status");
        account.setStatus("禁用");
        account.setStyleId(UUID.randomUUID());
        AccountSaveRequest request = unchangedRequest();
        request.setStatus("使用");
        when(styleLookup.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(styleLookup);
        when(styleLookup.getResultList()).thenReturn(List.of());

        assertThatThrownBy(() -> service.update(account.getId(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("会计科目不存在、已禁用")
                .hasMessageContaining("叶节点");
        verify(repository, never()).save(account);
        verify(hierarchyLock).getSingleResult();
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    private static void authenticate(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", permissions));
    }

    private AccountSaveRequest unchangedRequest() {
        AccountSaveRequest request = new AccountSaveRequest();
        request.setName(account.getName());
        request.setAccountType(AccountService.TYPE_BANK);
        request.setCurrencyId(account.getCurrencyId());
        request.setInitBalance(account.getInitBalance());
        request.setStatus(account.getStatus());
        return request;
    }

    private static Query query(long result) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(result);
        return query;
    }
}
