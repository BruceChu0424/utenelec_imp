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
        keeperOf(OWN);
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(page(row(GOODS, "10", OTHER)));
        when(reservations.warehouseEffectiveReservedBase(any(), any(), nullable(UUID.class))).thenReturn(new BigDecimal("12"));
        when(balances.warehouseAvailableBase(any(), any(), nullable(UUID.class))).thenReturn(BigDecimal.ZERO);
    }

    @Test void returnsRealWarehouseQuantitiesWithoutCostOrProductionFacts() {
        var result = tool.execute(Map.of("keyword", "MAT-01"));
        String reply = result.get("reply").toString();
        String detail = result.get("detailReply").toString();
        assertTrue(reply.contains("原料仓：现有 10 件，可用 0 件"));
        assertTrue(detail.contains("预留 12 件，待检 3 件，待入库 4 件"));
        assertTrue(detail.contains("还不能领用"));
        for (String text : List.of(reply, detail)) {
            assertFalse(text.contains("SECRET"));
            assertFalse(text.contains("98765"));
            assertFalse(text.contains("来源"));
            assertFalse(text.contains("权限"));
            assertFalse(text.contains("出库闸门"));
        }
        assertFalse(reply.contains("待检"));
        assertFalse(reply.contains("查询时间"));
        verify(reservations).warehouseEffectiveReservedBase(OWN, GOODS, null);
        verify(balances).warehouseAvailableBase(OWN, GOODS, null);
        verify(stock, times(2)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), eq("name"), eq("asc"));
    }

    @Test void twentyLongLabelsRemainWithinChatBoundWithoutRoundingRealQuantities() {
        var bounded = mock(InventoryAiChatQueryService.class);
        when(bounded.available()).thenReturn(true);
        var rows = new java.util.ArrayList<InventoryAiChatQueryService.Row>();
        BigDecimal exact = new BigDecimal("99999999999999.1234");
        for (int goods = 0; goods < 5; goods++) {
            UUID id = UUID.randomUUID();
            for (int warehouse = 0; warehouse < 4; warehouse++) {
                rows.add(new InventoryAiChatQueryService.Row(id, null, OWN, UUID.randomUUID(),
                        "C".repeat(120), "货".repeat(120), "色".repeat(120), "单".repeat(120), "仓".repeat(120),
                        exact, exact, exact, exact, exact, false));
            }
        }
        when(bounded.read(any())).thenReturn(new InventoryAiChatQueryService.Facts(List.of(), rows, ""));
        var result = new InventoryAiChatTool(bounded, new ObjectMapper()).execute(Map.of("keyword", "MAT"));
        for (String field : List.of("reply", "detailReply")) {
            String text = result.get(field).toString();
            assertTrue(text.length() <= 16000, "A permitted bounded query must not fail the chat reply length contract");
            assertTrue(text.contains(exact.toPlainString()));
            assertTrue(text.contains("…"));
        }
        assertEquals(5, result.get("reply").toString().split("现有 ", -1).length - 1);
        assertEquals(20, result.get("detailReply").toString().split("现有 ", -1).length - 1);
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
        // ADR-149: 没登记负责人的人(其他人)的「没人负责的仓」只是任务兜底, 不是 AI 查库存的授权。
        other();
        String reply = tool.execute(Map.of("keyword", "MAT")).get("reply").toString();
        assertTrue(reply.contains("还没设置你的负责仓库"));
        assertFalse(reply.contains("现有 0"));
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void explicitForeignWarehouseIsDeniedBeforeAnyInventoryRead() {
        assertThrows(ApiException.class, () -> tool.execute(Map.of("keyword", "MAT", "warehouseId", OTHER.toString())));
        verifyNoInteractions(stock, balances, reservations);
        verify(scopes).access();
        verify(scopes, never()).current(any());
    }

    @Test void parentSelectionIntersectsAssignmentsInsteadOfOpeningSiblingWarehouse() {
        tool.execute(Map.of("keyword", "MAT", "warehouseId", PARENT.toString()));
        verify(stock, times(2)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), any(), any());
        verify(balances, never()).warehouseAvailableBase(eq(OTHER), any(), any());
    }

    @Test void supervisorReadsEveryWarehouseFromTheSameResolution() {
        when(scopes.access()).thenReturn(new WarehouseTaskScopePort.WarehouseAccess(WarehouseTaskScopePort.Role.SUPERVISOR,
                List.of(PARENT), WarehouseTaskScopePort.WarehouseTaskScope.ALL, true));
        tool.execute(Map.of("keyword", "MAT"));
        verify(balances).warehouseAvailableBase(OWN, GOODS, null);
        verify(balances).warehouseAvailableBase(OTHER, GOODS, null);
    }

    @Test void superAdminReadsActualWarehousesWithoutKeeperAssignment() {
        actor(true, Set.of());
        tool.execute(Map.of("keyword", "MAT"));
        verify(balances).warehouseAvailableBase(OWN, GOODS, null);
        verify(balances).warehouseAvailableBase(OTHER, GOODS, null);
        verifyNoInteractions(scopes);
    }

    @Test void unknownWarehouseDoesNotBroadenTheQuery() {
        assertThrows(ApiException.class, () -> tool.execute(Map.of("keyword", "MAT", "warehouseId", UUID.randomUUID().toString())));
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void naturalWarehouseNameOrBusinessCodeNarrowsWithoutInventingInternalUuid() {
        tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", "原料仓"));
        tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", " w1 "));
        tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", "原料"));
        verify(stock, times(6)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), any(), any());
        verify(balances, never()).warehouseAvailableBase(eq(OTHER), any(), any());
    }

    @Test void missingOrUnauthorizedWarehouseNameNeverFallsBackToAllAssignedWarehouses() {
        for (String name : List.of("其他仓", "不存在的仓库")) {
            String reply = tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", name)).get("reply").toString();
            assertTrue(reply.contains("没找到这个仓库"));
            assertFalse(reply.contains("现有 "));
        }
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void ambiguousAuthorizedWarehouseNamesRequireReadableCodeAndNeverReadQuantities() {
        keeperOf(PARENT, OWN, OTHER);
        when(references.warehouses()).thenReturn(List.of(
                new WarehouseReference(PARENT, "P", "主仓", null, false, false, false),
                new WarehouseReference(OWN, "W1", "原料仓", PARENT, true, false, false),
                new WarehouseReference(OTHER, "W2", "原料仓", PARENT, true, false, false)));
        String reply = tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", "原料仓")).get("reply").toString();
        assertTrue(reply.contains("同名仓库"));
        assertTrue(reply.contains("W1 · 原料仓"));
        assertTrue(reply.contains("W2 · 原料仓"));
        verifyNoInteractions(stock, balances, reservations);
        tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", "W1"));
        verify(stock, times(2)).instantInventoryRowsInWarehouseScope(any(), eq(Set.of(OWN)), anyInt(), anyInt(), any(), any());
    }

    @Test void warehouseSelectorsAreMutuallyExclusiveAndNameIsBoundedPlainText() {
        for (Map<String, Object> arguments : List.of(
                Map.<String, Object>of("keyword", "MAT", "warehouseId", OWN.toString(), "warehouseKeyword", "W1"),
                Map.<String, Object>of("keyword", "MAT", "warehouseKeyword", " "),
                Map.<String, Object>of("keyword", "MAT", "warehouseKeyword", "a".repeat(81)),
                Map.<String, Object>of("keyword", "MAT", "warehouseKeyword", "a\nb"))) {
            assertThrows(ApiException.class, () -> tool.execute(arguments));
        }
        verifyNoInteractions(stock, balances, reservations, references);
    }

    @Test @SuppressWarnings("unchecked") void namedWarehouseHistoryRechecksTheOriginalSelectionAndItsScope() {
        var response = tool.execute(Map.of("keyword", "MAT", "warehouseKeyword", "原料仓"));
        var evidence = (Map<String, Object>) response.get("_toolEvidence");
        assertDoesNotThrow(() -> tool.authorizeResultRead(evidence));
        when(references.warehouses()).thenReturn(List.of(
                new WarehouseReference(OWN, "W1", "已改名", PARENT, true, false, false),
                new WarehouseReference(OTHER, "W2", "原料仓", PARENT, true, false, false)));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
        clearInvocations(stock, balances, reservations);
        other();
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
        verifyNoInteractions(stock, balances, reservations);
    }

    @Test void negativePhysicalBalancesRemainNegative() {
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(page(row(GOODS, "-3", OTHER)));
        assertTrue(tool.execute(Map.of("keyword", "MAT")).get("reply").toString().contains("现有 -3"));
    }

    @Test void ambiguousGoodsAskForNarrowingWithoutCallingQuantityGate() {
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(new PageResponse<>(List.of(row(GOODS, "10", OTHER)), 1, 6, 30, 5));
        assertTrue(tool.execute(Map.of("keyword", "螺丝")).get("reply").toString().contains("匹配的货品较多"));
        verifyNoInteractions(balances, reservations);
    }

    @Test void missingGoodsAreNotReportedAsZero() {
        when(stock.instantInventoryRowsInWarehouseScope(any(), anySet(), anyInt(), anyInt(), any(), any()))
                .thenReturn(new PageResponse<>(List.of(), 1, 6, 0, 0));
        assertTrue(tool.execute(Map.of("keyword", "不存在")).get("reply").toString().contains("没找到不代表库存为 0"));
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
        other();
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
        when(references.warehouses()).thenReturn(List.of(new WarehouseReference(OWN, "W1", "移交后的仓", PARENT, true, false, false)));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    /** ADR-146: 不良品仓行现存照报、可用恒为 0、预留照实报 0(不良品仓上不能有预留, 全局预留也不摊到它上面)。 */
    @Test void defectiveWarehouseRowsShowZeroUsableAndZeroReserved() {
        when(references.warehouses()).thenReturn(List.of(
                new WarehouseReference(PARENT, "P", "主仓", null, false, false, false),
                new WarehouseReference(OWN, "C0401", "成品不良品仓", PARENT, true, false, true)));
        var result = tool.execute(Map.of("keyword", "MAT-01"));
        assertTrue(result.get("reply").toString().contains("(不良品仓, 不计入可用)"));
        String detail = result.get("detailReply").toString();
        assertTrue(detail.contains("预留 0 件"), detail);
        assertFalse(detail.contains("预留 12 件"), detail);
        verify(reservations, never()).warehouseEffectiveReservedBase(eq(OWN), any(), nullable(UUID.class));
        verify(balances, never()).warehouseAvailableBase(eq(OWN), any(), nullable(UUID.class));
    }

    @Test void historyRejectsMissingAndForgedSourceEvidence() {
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(null));
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(Map.of()));
        var evidence = new java.util.HashMap<>(evidence());
        evidence.put("source", "finance/cost");
        assertThrows(ApiException.class, () -> tool.authorizeResultRead(evidence));
    }

    @Test void missingWarehouseNameNeverExposesAnInternalIdentifier() {
        when(references.warehouses()).thenReturn(List.of(new WarehouseReference(OWN, "W1", null, null, true, false, false)));
        var result = tool.execute(Map.of("keyword", "MAT"));
        for (String field : List.of("reply", "detailReply")) {
            assertTrue(result.get(field).toString().contains("未命名仓库"));
            assertFalse(result.get(field).toString().contains(OWN.toString()));
        }
    }

    @SuppressWarnings("unchecked") private Map<String, Object> evidence() {
        return (Map<String, Object>) tool.execute(Map.of("keyword", "MAT")).get("_toolEvidence");
    }
    /** 子仓负责人: 默认范围 = 自己负责的仓(含下级), 不含未定仓。 */
    private void keeperOf(UUID... scope) {
        when(scopes.access()).thenReturn(new WarehouseTaskScopePort.WarehouseAccess(WarehouseTaskScopePort.Role.KEEPER,
                List.of(scope[0]), new WarehouseTaskScopePort.WarehouseTaskScope(true, List.of(scope), false), true));
    }

    /** 其他人: 只看没人负责的仓的任务(这里全公司还没登记, 等于全部), 但不是 AI 查库存的授权。 */
    private void other() {
        when(scopes.access()).thenReturn(new WarehouseTaskScopePort.WarehouseAccess(WarehouseTaskScopePort.Role.OTHER,
                List.of(), WarehouseTaskScopePort.WarehouseTaskScope.ALL, true));
    }

    private void actor(boolean admin, Set<String> permissions) {
        when(access.requireChat()).thenReturn(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "actor",
                permissions, false, true, admin));
    }
    private static List<WarehouseReference> warehouses() {
        return List.of(new WarehouseReference(PARENT, "P", "主仓", null, false, false, false),
                new WarehouseReference(OWN, "W1", "原料仓", PARENT, true, false, false),
                new WarehouseReference(OTHER, "W2", "其他仓", PARENT, true, false, false));
    }
    private static PageResponse<InstantInventoryRow> page(InstantInventoryRow row) {
        return new PageResponse<>(List.of(row), 1, 6, 1, 1);
    }
    private static InstantInventoryRow row(UUID goods, String qty, UUID owningWarehouse) {
        return new InstantInventoryRow(goods, null, "分类", "M1", "SECRET_CUSTOMER_MODEL", "螺丝", "规格",
                null, "件", "SECRET_REMARK", BigDecimal.ONE, new BigDecimal(qty), new BigDecimal("98765"),
                new BigDecimal("98765"), "MAT-01", "系列", "库位", new BigDecimal("3"), new BigDecimal("4"),
                false, false, BigDecimal.ONE, "GREEN", false, owningWarehouse, "SECRET_OWNING_WAREHOUSE",
                BigDecimal.ZERO);
    }
}
