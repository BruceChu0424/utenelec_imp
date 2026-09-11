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

class StockQueryCostVisibilityTest {

    private final StockBalanceRepository balanceRepo = mock(StockBalanceRepository.class);
    private final StockMovementRepository movementRepo = mock(StockMovementRepository.class);
    private final EntityManager entityManager = mock(EntityManager.class);

    @Test
    void viewerWithoutCostPermissionGetsNullBalanceAndMovementAmounts() {
        StockBalance balance = balance();
        StockMovement movement = movement();
        when(balanceRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockBalance>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(balance)));
        when(movementRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockMovement>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(movement)));

        StockQueryService service = service(false);
        var balanceRow = service.balances(null, null, 1, 20, null, null)
                .getItems().getFirst();
        var movementRow = service.movements(
                        null, null, null, null, null, 1, 20, null, null)
                .getItems().getFirst();

        assertNull(balanceRow.getAmountLocal());
        assertTrue(balanceRow.isCostMasked());
        assertEquals(balance.getWeight(), balanceRow.getWeight());
        assertNull(movementRow.getAmountLocal());
        assertEquals(movement.getUnitId(), movementRow.getUnitId());
        assertEquals(movement.getUnitRate(), movementRow.getUnitRate());
        assertEquals(movement.getWeight(), movementRow.getWeight());
        assertTrue(movementRow.isCostMasked());
    }

    @Test
    void viewerWithCostPermissionKeepsBalanceAndMovementAmounts() {
        StockBalance balance = balance();
        StockMovement movement = movement();
        when(balanceRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockBalance>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(balance)));
        when(movementRepo.findAll(
                org.mockito.ArgumentMatchers.<Specification<StockMovement>>any(),
                any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(movement)));

        StockQueryService service = service(true);
        var balanceRow = service.balances(null, null, 1, 20, null, null)
                .getItems().getFirst();
        var movementRow = service.movements(
                        null, null, null, null, null, 1, 20, null, null)
                .getItems().getFirst();

        assertEquals(balance.getAmountLocal(), balanceRow.getAmountLocal());
        assertFalse(balanceRow.isCostMasked());
        assertEquals(movement.getAmountLocal(), movementRow.getAmountLocal());
        assertEquals(movement.getWeight(), movementRow.getWeight());
        assertFalse(movementRow.isCostMasked());
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
        when(dataQuery.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "五金", "M1", "C1", "螺丝", "S1",
                "银色", "件", "外购", new BigDecimal("2.5"), new BigDecimal("10"),
                new BigDecimal("999.99"), new BigDecimal("3"), "MAT-001", "五金件", "A-01",
                new BigDecimal("4"), new BigDecimal("2")
        }));
        when(countQuery.getSingleResult()).thenReturn(1L);

        var row = service(false).instantInventory(
                        null, null, true, null, 1, 20, null, null)
                .getItems().getFirst();

        assertNull(row.getCostAmount());
        assertTrue(row.isCostMasked());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // 列表 + 计数 + 两条服务端合计（ReportTotalsCalculator 按分组维度各发一条）。
        // 合计把列表 SQL 整个包进 FROM (...) t，所以脱敏投影必须在**所有**四条里都成立：
        // 少脱一条，无成本权限的人就能从表尾合计里看到金额。
        verify(entityManager, times(4)).createNativeQuery(sql.capture());
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
        when(dataQuery.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "五金", "M1", "C1", "螺丝", "S1",
                "银色", "件", "外购", new BigDecimal("2.5"), new BigDecimal("10"),
                new BigDecimal("123.45"), new BigDecimal("3"), "MAT-001", "五金件", "A-01",
                new BigDecimal("4"), new BigDecimal("2")
        }));
        when(countQuery.getSingleResult()).thenReturn(1L);

        var row = service(true).instantInventory(
                        null, null, true, null, 1, 20, null, null)
                .getItems().getFirst();

        assertEquals(new BigDecimal("123.45"), row.getCostAmount());
        assertFalse(row.isCostMasked());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // 同上：列表 + 计数 + 两条服务端合计，成本口径（台账聚合而非主档单价×数量）四条一致。
        verify(entityManager, times(4)).createNativeQuery(sql.capture());
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
        return new StockQueryService(balanceRepo, movementRepo, entityManager, masker);
    }

    private static StockBalance balance() {
        StockBalance balance = new StockBalance();
        balance.setId(UUID.randomUUID());
        balance.setWarehouseId(UUID.randomUUID());
        balance.setGoodsId(UUID.randomUUID());
        balance.setQty(new BigDecimal("10"));
        balance.setAmountLocal(new BigDecimal("123.45"));
        balance.setWeight(new BigDecimal("2.5"));
        balance.setLastMovementDate(OffsetDateTime.now());
        return balance;
    }

    private static StockMovement movement() {
        StockMovement movement = new StockMovement();
        movement.setId(UUID.randomUUID());
        movement.setTransactionDate(OffsetDateTime.now());
        movement.setMovementType((short) 1);
        movement.setSourceDocType("PURCHASE_RECEIPT");
        movement.setSourceDocId(UUID.randomUUID());
        movement.setGoodsId(UUID.randomUUID());
        movement.setWarehouseId(UUID.randomUUID());
        movement.setDirection((short) 1);
        movement.setQty(new BigDecimal("10"));
        movement.setUnitId(UUID.randomUUID());
        movement.setUnitRate(new BigDecimal("2.500000"));
        movement.setWeight(new BigDecimal("7.2500"));
        movement.setAmountLocal(new BigDecimal("123.45"));
        return movement;
    }
}
