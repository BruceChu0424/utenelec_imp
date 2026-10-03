package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseInventoryReferencePort;
import com.uten.imp.application.port.WarehouseInventoryReferencePort.WarehouseReference;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class InventoryAiChatToolTest {
    private static final UUID GOODS = UUID.randomUUID();
    private static final UUID OWN = UUID.randomUUID();
    private static final UUID OTHER = UUID.randomUUID();
    private static final UUID PARENT = UUID.randomUUID();
    private final StockQueryService stock = mock(StockQueryService.class);
    private final StockBalanceRepository balances = mock(StockBalanceRepository.class);
    private final StockReservationRepository reservations = mock(StockReservationRepository.class);
    private final WarehouseInventoryReferencePort references = mock(WarehouseInventoryReferencePort.class);
    private final WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final InventoryAiChatQueryService query = new InventoryAiChatQueryService(
            stock, balances, reservations, references, scopes, access);
    private final InventoryAiChatTool tool = new InventoryAiChatTool(query, new ObjectMapper());

    @BeforeEach void setup() {
        actor(false, Set.of("ai:use", "stock:view"));
        when(access.hasDomain("WAREHOUSE")).thenReturn(true);
        when(references.warehouses()).thenReturn(warehouses());
        when(references.assignedWarehouseRoots()).thenReturn(Set.of(OWN));
        when(scopes.resolve("MINE", null)).thenReturn(new WarehouseTaskScopePort.WarehouseTaskScope(true, List.of(OWN), true));
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(page(row(GOODS, "10", OTHER)));
        when(reservations.warehouseEffectiveReservedBase(any(), any(), nullable(UUID.class))).thenReturn(new BigDecimal("12"));
        when(balances.warehouseAvailableBase(any(), any(), nullable(UUID.class))).thenReturn(BigDecimal.ZERO);
    }

    @Test void returnsRealWarehouseQuantitiesWithoutCostOrProductionFacts() {
        String reply = tool.execute(Map.of("keyword", "MAT-01")).get("reply").toString();
        assertTrue(reply.contains("仓库：原料仓"));
        assertTrue(reply.contains("账面库存 10，有效预留占用 12，出库可动量 0，待检 3，待入库 4"));
        assertTrue(reply.contains("单位：件"));
        assertTrue(reply.contains("查询时间"));
        assertTrue(reply.contains("不能相加"));
        assertFalse(reply.contains("SECRET"));
        assertFalse(reply.contains("98765"));
        verify(reservations).warehouseEffectiveReservedBase(OWN, GOODS, null);
        verify(balances).warehouseAvailableBase(OWN, GOODS, null);
        verify(stock, times(2)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), eq("name"), eq("asc"));
    }

    @Test void functionalPermissionCannotBypassDepartmentMembership() {
        when(access.hasDomain("WAREHOUSE")).thenReturn(false);
        assertFalse(tool.available());
        assertThrows(ApiException.class, () -> tool.execute(Map.of("keyword", "MAT")));
        verifyNoInteractions(stock, balances, reservations, references, scopes);
    }

    @Test void departmentWithoutStockViewCannotQuery() {
        actor(false, Set.of("ai:use"));
        assertThrows(ApiException.class, () -> tool.execute(Map.of("keyword", "MAT")));
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void missingAssignmentsDoNotBecomeAllWarehousesOrZeroStock() {
        when(references.assignedWarehouseRoots()).thenReturn(Set.of());
        when(scopes.resolve("MINE", null)).thenReturn(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
        String reply = tool.execute(Map.of("keyword", "MAT")).get("reply").toString();
        assertTrue(reply.contains("尚未分配"));
        assertTrue(reply.contains("不表示库存为零"));
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void explicitForeignWarehouseIsDeniedBeforeAnyInventoryRead() {
        assertThrows(ApiException.class, () -> tool.execute(Map.of("keyword", "MAT", "warehouseId", OTHER.toString())));
        verifyNoInteractions(stock, balances, reservations);
        verify(scopes).resolve("MINE", null);
        verify(scopes, never()).resolve(anyString(), eq(OTHER));
    }

    @Test void parentSelectionIntersectsAssignmentsInsteadOfOpeningSiblingWarehouse() {
        tool.execute(Map.of("keyword", "MAT", "warehouseId", PARENT.toString()));
        verify(stock, times(2)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), any(), any());
        verify(balances, never()).warehouseAvailableBase(eq(OTHER), any(), any());
    }

    @Test void mineScopeStillRestrictsExplicitKeeperSubtree() {
        when(references.assignedWarehouseRoots()).thenReturn(Set.of(PARENT));
        tool.execute(Map.of("keyword", "MAT"));
        verify(stock, times(2)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), any(), any());
    }

    @Test void superAdminReadsActualWarehousesWithoutKeeperAssignment() {
        actor(true, Set.of());
        tool.execute(Map.of("keyword", "MAT"));
        verify(balances).warehouseAvailableBase(OWN, GOODS, null);
        verify(balances).warehouseAvailableBase(OTHER, GOODS, null);
        verifyNoInteractions(scopes);
        verify(references, never()).assignedWarehouseRoots();
    }

    @Test void unknownWarehouseDoesNotBroadenTheQuery() {
        assertThrows(ApiException.class, () -> tool.execute(Map.of("keyword", "MAT", "warehouseId", UUID.randomUUID().toString())));
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void negativePhysicalBalancesRemainNegative() {
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(page(row(GOODS, "-3", OTHER)));
        assertTrue(tool.execute(Map.of("keyword", "MAT")).get("reply").toString().contains("账面库存 -3"));
    }

    @Test void ambiguousGoodsAskForNarrowingWithoutCallingQuantityGate() {
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(new PageResponse<>(List.of(row(GOODS, "10", OTHER)), 1, 6, 30, 5));
        assertTrue(tool.execute(Map.of("keyword", "螺丝")).get("reply").toString().contains("超过 5 种"));
        verifyNoInteractions(balances, reservations);
    }

    @Test void missingGoodsAreNotReportedAsZero() {
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(new PageResponse<>(List.of(), 1, 6, 0, 0));
        assertTrue(tool.execute(Map.of("keyword", "不存在")).get("reply").toString().contains("未找到不等于库存为零"));
        verifyNoInteractions(balances, reservations);
    }

    @Test void invalidArgumentsCannotInjectAnotherScopeOrArbitrarySql() {
        for (Map<String, Object> arguments : List.of(Map.<String, Object>of("keyword", "MAT", "sql", "SELECT * FROM users"),
                Map.<String, Object>of("keyword", "MAT", "department", "FINANCE"),
                Map.<String, Object>of("keyword", " "), Map.<String, Object>of("keyword", "a\nb"),
                Map.<String, Object>of("keyword", "MAT", "warehouseId", "1-1-1-1-1"))) {
            assertThrows(ApiException.class, () -> tool.execute(arguments));
        }
        verifyNoInteractions(stock, balances, reservations, references);
    }

    @Test void historyRevalidatesScopeBeforeReturningOldQuantities() {
        var evidence = evidence();
        assertDoesNotThrow(() -> tool.authorizeResultRead(evidence));
        when(references.assignedWarehouseRoots()).thenReturn(Set.of());
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    @Test void historyRejectsChangedQuantityEvenWhenFunctionalPermissionsStayTheSame() {
        var evidence = evidence();
        when(reservations.warehouseEffectiveReservedBase(any(), any(), nullable(UUID.class))).thenReturn(BigDecimal.ONE);
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    @Test void historyRejectsGoodsReassignmentOrSameNameReplacement() {
        var evidence = evidence();
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(page(row(GOODS, "10", OWN)));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(page(row(UUID.randomUUID(), "10", OTHER)));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    @Test void historyRejectsWarehouseRenameEvenWithSameQuantities() {
        var evidence = evidence();
        when(references.warehouses()).thenReturn(List.of(new WarehouseReference(OWN, "W1", "移交后的仓", PARENT, true, false)));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    @Test void historyRejectsMissingAndForgedSourceEvidence() {
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(null));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(Map.of()));
        var evidence = new java.util.HashMap<>(evidence());
        evidence.put("source", "finance/cost");
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    @SuppressWarnings("unchecked") private Map<String, Object> evidence() {
        return (Map<String, Object>) tool.execute(Map.of("keyword", "MAT")).get("_toolEvidence");
    }
    private void actor(boolean admin, Set<String> permissions) {
        when(access.requireChat()).thenReturn(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "actor",
                permissions, false, true, admin));
    }
    private static List<WarehouseReference> warehouses() {
        return List.of(new WarehouseReference(PARENT, "P", "主仓", null, false, false),
                new WarehouseReference(OWN, "W1", "原料仓", PARENT, true, false),
                new WarehouseReference(OTHER, "W2", "其他仓", PARENT, true, false));
    }
    private static PageResponse<InstantInventoryRow> page(InstantInventoryRow row) {
        return new PageResponse<>(List.of(row), 1, 6, 1, 1);
    }
    private static InstantInventoryRow row(UUID goods, String qty, UUID owningWarehouse) {
        return new InstantInventoryRow(goods, null, "分类", "M1", "SECRET_CUSTOMER_MODEL", "螺丝", "规格",
                null, "件", "SECRET_REMARK", BigDecimal.ONE, new BigDecimal(qty), new BigDecimal("98765"),
                new BigDecimal("98765"), "MAT-01", "系列", "库位", new BigDecimal("3"), new BigDecimal("4"),
                false, false, BigDecimal.ONE, "GREEN", false, owningWarehouse, "SECRET_OWNING_WAREHOUSE");
    }
}
