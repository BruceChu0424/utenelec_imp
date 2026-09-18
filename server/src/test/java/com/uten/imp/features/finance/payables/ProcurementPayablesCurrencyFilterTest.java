package com.uten.imp.features.finance.payables;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 应付工作台「币种」表头筛选（2026-09-16）：currencyId 按 ar_ap_ledger.currency_id
 * 等值（命名参数绑定），计数/列表/汇总共用同一 Filter。
 */
class ProcurementPayablesCurrencyFilterTest {

    private final EntityManager em = mock(EntityManager.class);

    @Test
    void currencyIdBindsAsNamedParameterOnLedgerColumn() {
        // 每个 native query 一个 mock：COUNT 回数字、汇总回 10 列零值行
        // （summary 把结果强转 Object[]），参数绑定统一记录进 boundParams。
        List<String> boundParams = new java.util.ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenAnswer(setInvocation -> {
                boundParams.add(setInvocation.getArgument(0, String.class));
                return query;
            });
            when(query.getResultList()).thenReturn(List.of());
            when(query.getSingleResult()).thenAnswer(single ->
                    sql.startsWith("SELECT COUNT(*)")
                            ? 0L
                            : new Object[]{0, 0, 0, 0, 0, 0, 0, 0, 0, 0});
            return query;
        });

        UUID currencyId = UUID.randomUUID();
        new ProcurementPayablesService(
                em, mock(SupplierPayableHoldGuard.class))
                .list(null, null, null, null, currencyId,
                        null, null, null, null, null, 1, 30, null, null);

        // ①数据/计数/汇总查询带 currency 等值子句（列名硬编码；超耗案件计数不按
        // 币种过滤，属既有口径，不在断言范围）。
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.atLeast(3)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("FROM ar_ap_ledger ledger")
                .contains("ledger.currency_id = :currencyId"));
        assertThat(sql.getAllValues()).filteredOn(statement ->
                        statement.startsWith("SELECT COUNT(*)") && statement.contains("ar_ap_ledger"))
                .isNotEmpty()
                .allSatisfy(statement -> assertThat(statement)
                        .contains("ledger.currency_id = :currencyId"));
        // ②值经命名参数绑定（数据 + 计数 + 汇总三处）。
        assertThat(boundParams.stream()
                .filter("currencyId"::equals).count()).isGreaterThanOrEqualTo(3);
    }
}
