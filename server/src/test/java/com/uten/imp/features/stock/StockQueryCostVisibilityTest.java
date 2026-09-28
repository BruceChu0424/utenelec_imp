package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 库存查询的成本脱敏 (goods:cost:view): 余额金额、即时库存台账金额 (含合计与 facet 的每一条 SQL)。
 * 货品出入库流水的金额与往来方脱敏见 ledger.StockLedgerRowMaskingTest。
 */
class StockQueryCostVisibilityTest {

    private final StockBalanceRepository balanceRepo = mock(StockBalanceRepository.class);
    private final EntityManager entityManager = mock(EntityManager.class);

    @Test
    void viewerWithoutCostPermissionGetsNullBalanceAmounts() {
        StockBalance balance = balance();
        when(balanceRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockBalance>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(balance)));

        var balanceRow = service(false).balances(null, null, 1, 20, null, null)
                .getItems().getFirst();

        assertNull(balanceRow.getAmountLocal());
        assertTrue(balanceRow.isCostMasked());
        assertEquals(balance.getWeight(), balanceRow.getWeight());
        assertTrue(balanceRow.isWeightEstimated());
    }

    @Test
    void viewerWithCostPermissionKeepsBalanceAmounts() {
        StockBalance balance = balance();
        when(balanceRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockBalance>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(balance)));

        var balanceRow = service(true).balances(null, null, 1, 20, null, null)
                .getItems().getFirst();

        assertEquals(balance.getAmountLocal(), balanceRow.getAmountLocal());
        assertFalse(balanceRow.isCostMasked());
    }

    @Test
    void viewerWithoutCostPermissionCannotSortInstantInventoryByCost() {
        ApiException error = assertThrows(
                ApiException.class,
                () -> service(false).instantInventory(
                        null, null, true, null, 1, 20, "costAmount", "desc"));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verifyNoInteractions(entityManager);
    }

    @Test
    void viewerWithoutCostPermissionDoesNotProjectOrMapInstantInventoryCost() {
        Query dataQuery = mock(Query.class);
        Query countQuery = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(dataQuery, countQuery);
        when(dataQuery.setParameter(anyString(), any())).thenReturn(dataQuery);
        when(countQuery.setParameter(anyString(), any())).thenReturn(countQuery);
        when(dataQuery.getResultList()).thenReturn(Collections.singletonList(instantRow(new BigDecimal("999.99"))));
        when(countQuery.getSingleResult()).thenReturn(1L);

        var row = service(false).instantInventory(
                        null, null, true, null, 1, 20, null, null)
                .getItems().getFirst();

        assertNull(row.getCostAmount());
        assertTrue(row.isCostMasked());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // 列表 + 计数 + 两条服务端合计（ReportTotalsCalculator 按分组维度各发一条）
        // + V587/V590 归属仓库 facet 两桶（有值桶 + 空归属计数）+ 2026-09-16 起的
        // 颜色/物料系列/单位三列 facet 桶 = 9 条。
        // 合计与 facet 都把列表 SQL 整个包进 FROM (...) t，所以脱敏投影必须在
        // **所有**条里都成立：少脱一条，无成本权限的人就能从表尾合计里看到金额。
        verify(entityManager, times(9)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().stream().noneMatch(value -> value.contains("g.c_total")));
        assertTrue(sql.getAllValues().stream().allMatch(value -> value.contains("CAST(NULL AS NUMERIC)")));
    }

    @Test
    void viewerWithCostPermissionGetsAggregatedLedgerAmountInsteadOfMasterCostTimesQty() {
        Query dataQuery = mock(Query.class);
        Query countQuery = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(dataQuery, countQuery);
        when(dataQuery.setParameter(anyString(), any())).thenReturn(dataQuery);
        when(countQuery.setParameter(anyString(), any())).thenReturn(countQuery);
        when(dataQuery.getResultList()).thenReturn(Collections.singletonList(instantRow(new BigDecimal("123.45"))));
        when(countQuery.getSingleResult()).thenReturn(1L);

        var row = service(true).instantInventory(
                        null, null, true, null, 1, 20, null, null)
                .getItems().getFirst();

        assertEquals(new BigDecimal("123.45"), row.getCostAmount());
        assertFalse(row.isCostMasked());
        // 重量扩展列(ADR-135)追加在投影末尾, 按位置映射。
        assertTrue(row.isWeightEstimated());
        assertFalse(row.isWeightUnknown());
        assertEquals(new BigDecimal("0.002500000000"), row.getUnitWeightKg());
        assertEquals("YELLOW", row.getWeightTier());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // 同上：列表 + 计数 + 两条合计 + 归属 facet 两桶 + 颜色/系列/单位三列 facet
        // 共 9 条，成本口径（台账聚合而非主档单价×数量）全部一致。
        verify(entityManager, times(9)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().stream()
                .allMatch(value -> value.contains("SUM(u.amount_local) AS amount_local")));
        assertTrue(sql.getAllValues().stream()
                .allMatch(value -> value.contains("b.amount_local")));
        assertTrue(sql.getAllValues().stream()
                .allMatch(value -> value.contains("COALESCE(base.amount_local, 0)")));
        assertTrue(sql.getAllValues().stream()
                .noneMatch(value -> value.contains("g.c_total")));
    }

    private StockQueryService service(boolean canViewCost) {
        StockCostMasker masker = mock(StockCostMasker.class);
        when(masker.canView()).thenReturn(canViewCost);
        return new StockQueryService(balanceRepo, entityManager, masker);
    }

    /** 即时库存 SELECT 的一行 (前 19 列为原口径, 其后 5 列为 ADR-135 重量扩展)。 */
    private static Object[] instantRow(BigDecimal costAmount) {
        return new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "五金", "M1", "C1", "螺丝", "S1",
                "银色", "件", "外购", new BigDecimal("2.5"), new BigDecimal("10"),
                costAmount, new BigDecimal("3"), "MAT-001", "五金件", "A-01",
                new BigDecimal("4"), new BigDecimal("2"),
                Boolean.TRUE, 0, 1, new BigDecimal("0.002500000000"), "YELLOW"
        };
    }

    private static StockBalance balance() {
        StockBalance balance = new StockBalance();
        balance.setId(UUID.randomUUID());
        balance.setWarehouseId(UUID.randomUUID());
        balance.setGoodsId(UUID.randomUUID());
        balance.setQty(new BigDecimal("10"));
        balance.setAmountLocal(new BigDecimal("123.45"));
        balance.setWeight(new BigDecimal("2.5"));
        balance.setWeightEstimated(true);
        balance.setLastMovementDate(OffsetDateTime.now());
        return balance;
    }
}
