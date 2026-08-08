package com.uten.imp.features.master.account;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
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
    private Query flowCount;
    private Query documentCount;
    private AccountService service;
    private Account account;

    @BeforeEach
    void setUp() {
        repository = mock(AccountRepository.class);
        EntityManager em = mock(EntityManager.class);
        flowCount = query(0L);
        documentCount = query(1L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
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
        AccountSaveRequest request = unchangedRequest();
        request.setCurrencyId(UUID.randomUUID());

        assertThatThrownBy(() -> service.update(account.getId(), request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("币别不可修改");
        verify(repository, never()).save(account);
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
