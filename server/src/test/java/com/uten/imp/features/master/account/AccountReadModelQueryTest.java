package com.uten.imp.features.master.account;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.account.dto.AccountFacets;
import com.uten.imp.features.master.account.dto.AccountSummary;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AccountReadModelQueryTest {

    @Test
    void summaryTotalsOnlyActiveBalancesAndOmitsDisabledOnlyCurrencyBuckets() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        UUID cny = UUID.randomUUID();
        UUID usd = UUID.randomUUID();
        List<Object[]> rows = List.of(
                new Object[]{cny, "CNY", "人民币", 2L, 1L,
                        new BigDecimal("100.0000"), 0L, 0L},
                new Object[]{usd, "USD", "美元", 1L, 0L,
                        BigDecimal.ZERO.setScale(4), 0L, 0L});
        when(query.getResultList()).thenReturn(rows);

        AccountSummary summary = service(em).summary();

        assertThat(summary.totalAccounts()).isEqualTo(3);
        assertThat(summary.activeAccounts()).isEqualTo(1);
        assertThat(summary.disabledAccounts()).isEqualTo(2);
        assertThat(summary.currencies()).singleElement().satisfies(currency -> {
            assertThat(currency.currencyId()).isEqualTo(cny);
            assertThat(currency.balanceTotal()).isEqualByComparingTo("100.0000");
            assertThat(currency.activeAccountCount()).isEqualTo(1);
        });
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("SUM(account.balance_current)")
                .contains("FILTER (WHERE account.status='使用')");
    }

    @Test
    void facetsUseOneAccountAggregationQueryPlusCurrencyLabels() {
        EntityManager em = mock(EntityManager.class);
        Query facetQuery = mock(Query.class);
        Query currencyQuery = mock(Query.class);
        UUID cny = UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            return sql.contains("WITH expanded") ? facetQuery : currencyQuery;
        });
        when(facetQuery.setParameter("facetLimit", 50)).thenReturn(facetQuery);
        List<Object[]> facetRows = List.of(
                new Object[]{"accountType", "BANK", 2L, 1L},
                new Object[]{"currencyId", cny.toString(), 2L, 1L},
                new Object[]{"status", "使用", 1L, 1L},
                new Object[]{"status", "禁用", 1L, 2L},
                new Object[]{"currencyId", null, 1L, 2147483647L});
        when(facetQuery.getResultList()).thenReturn(facetRows);
        List<Object[]> currencyRows = List.<Object[]>of(
                new Object[]{cny, "CNY", "人民币"});
        when(currencyQuery.getResultList()).thenReturn(currencyRows);

        AccountFacets facets = service(em).facets();

        assertThat(facets.getAccountType()).singleElement().satisfies(bucket -> {
            assertThat(bucket.getValue()).isEqualTo("BANK");
            assertThat(bucket.getLabel()).isEqualTo("银行账户");
        });
        assertThat(facets.getCurrencyId()).singleElement()
                .satisfies(bucket -> assertThat(bucket.getLabel()).isEqualTo("CNY · 人民币"));
        assertThat(facets.getNullCounts()).containsEntry("currencyId", 1L);
        verify(em, org.mockito.Mockito.times(2)).createNativeQuery(anyString());
    }

    private static AccountService service(EntityManager em) {
        return new AccountService(
                mock(AccountRepository.class),
                mock(TxSessionVars.class),
                em,
                mock(MasterCodeService.class));
    }
}
