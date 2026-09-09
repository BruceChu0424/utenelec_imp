package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanInboundAllocationReadPort.AllocationView;
import com.uten.imp.features.master.warehouse.WarehouseScopeService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** Executes the real projection algorithm over native-query fixture rows.
 * This tests read-only budgeting, not posting or database provenance guards. */
class PreplanInboundAllocationProjectionBudgetTest {
    private static final UUID RECEIPT = id(1), ITEM = id(2), OTHER_ITEM = id(3);
    private static final UUID ORDER_ITEM = id(10), OTHER_ORDER_ITEM = id(11);
    private static final UUID SOURCE_A = id(20), SOURCE_B = id(21), GOODS = id(30);
    private static final UUID ACTUAL_WAREHOUSE = id(40), OTHER_ACTUAL_WAREHOUSE = id(41);
    private static final UUID PLANNED_WAREHOUSE = id(42);
    private static final UUID MATERIAL_A = id(50), MATERIAL_B = id(51), MATERIAL_SHARED = id(52);

    @Test
    void splitPassesCannotReuseThePartialOrderSourceBudget() {
        // A requires 20, but this merged order bought only A10+B10.
        var whole = fixture(List.<Object[]>of(slice(100, ITEM, ORDER_ITEM, "20", ACTUAL_WAREHOUSE)), false);
        var split = fixture(List.of(slice(100, ITEM, ORDER_ITEM, "10", ACTUAL_WAREHOUSE),
                slice(101, ITEM, ORDER_ITEM, "10", ACTUAL_WAREHOUSE)), false);
        assertThat(totals(whole.preview(id(100)))).isEqualTo(expected("10", "10", "0", "0"));
        assertThat(totals(split.preview(id(100), id(101)))).isEqualTo(expected("10", "10", "0", "0"));
        whole.assertReadOnly();
        split.assertReadOnly();
    }

    @Test
    void multipleReceiptItemsShareTheOrderSourceBudgetAndKeepActualWarehouses() {
        var fixture = fixture(List.of(slice(100, ITEM, ORDER_ITEM, "10", ACTUAL_WAREHOUSE),
                slice(101, OTHER_ITEM, ORDER_ITEM, "10", OTHER_ACTUAL_WAREHOUSE)), false);
        var forward = fixture.preview(id(100), id(101));
        var reverseInput = fixture.preview(id(101), id(100));
        assertThat(totals(forward)).isEqualTo(expected("10", "10", "0", "0"));
        assertThat(reverseInput).isEqualTo(forward);
        assertThat(forward.get(id(100))).singleElement().satisfies(row -> {
            assertThat(row.analysisMaterialId()).isEqualTo(MATERIAL_A);
            assertThat(row.actualWarehouseId()).isEqualTo(ACTUAL_WAREHOUSE);
            assertThat(row.targetWarehouseId()).isEqualTo(PLANNED_WAREHOUSE);
            assertThat(row.warehouseMatches()).isTrue();
        });
        assertThat(forward.get(id(101))).singleElement().satisfies(row -> {
            assertThat(row.analysisMaterialId()).isEqualTo(MATERIAL_B);
            assertThat(row.actualWarehouseId()).isEqualTo(OTHER_ACTUAL_WAREHOUSE);
        });
        fixture.assertReadOnly();
    }

    @Test
    void exactAndSharedClaimModesHaveSeparateBudgetsAndExcessStaysPublic() {
        var whole = fixture(List.<Object[]>of(slice(100, ITEM, ORDER_ITEM, "24", ACTUAL_WAREHOUSE)), true);
        var split = fixture(List.of(slice(100, ITEM, ORDER_ITEM, "10", ACTUAL_WAREHOUSE),
                slice(101, OTHER_ITEM, ORDER_ITEM, "10", OTHER_ACTUAL_WAREHOUSE),
                slice(102, OTHER_ITEM, ORDER_ITEM, "4", OTHER_ACTUAL_WAREHOUSE)), true);
        var expected = expected("10", "10", "3", "1");
        assertThat(totals(whole.preview(id(100)))).isEqualTo(expected);
        assertThat(totals(split.preview(id(102), id(100), id(101)))).isEqualTo(expected);
        whole.assertReadOnly();
        split.assertReadOnly();
    }

    @Test
    void distinctOrderItemsDoNotConsumeEachOthersBudget() {
        var fixture = new Fixture(List.of(slice(100, ITEM, ORDER_ITEM, "5", ACTUAL_WAREHOUSE),
                slice(101, OTHER_ITEM, OTHER_ORDER_ITEM, "5", OTHER_ACTUAL_WAREHOUSE)),
                List.of(anchor(ITEM, ORDER_ITEM, SOURCE_A, 1, "5", "0"),
                        anchor(OTHER_ITEM, OTHER_ORDER_ITEM, SOURCE_A, 1, "5", "0")),
                List.<Object[]>of(candidate(SOURCE_A, MATERIAL_A, "SUPPLY", "20")));
        assertThat(totals(fixture.preview(id(100), id(101)))).isEqualTo(expected("10", "0", "0", "0"));
        fixture.assertReadOnly();
    }

    private static Fixture fixture(List<Object[]> slices, boolean shared) {
        List<Object[]> anchors = new ArrayList<>();
        slices.stream().map(row -> (UUID) row[1]).distinct().sorted().forEach(receiptItem -> {
            anchors.add(anchor(receiptItem, ORDER_ITEM, SOURCE_A, 1, "10", shared ? "3" : "0"));
            anchors.add(anchor(receiptItem, ORDER_ITEM, SOURCE_B, 2, "10", "0"));
        });
        List<Object[]> candidates = new ArrayList<>();
        candidates.add(candidate(SOURCE_A, MATERIAL_A, "SUPPLY", "20"));
        if (shared) candidates.add(candidate(SOURCE_A, MATERIAL_SHARED, "SHARED_FUTURE_CLAIM", "20"));
        candidates.add(candidate(SOURCE_B, MATERIAL_B, "SUPPLY", "10"));
        return new Fixture(slices, anchors, candidates);
    }

    private static class Fixture {
        final EntityManager em = mock(EntityManager.class);
        final WarehouseScopeService warehouses = mock(WarehouseScopeService.class);
        final List<Query> queries = new ArrayList<>();
        final PreplanInboundAllocationProjectionService service;
        int calls;
        Fixture(List<Object[]> slices, List<Object[]> anchors, List<Object[]> candidates) {
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                String sql = invocation.getArgument(0);
                List<Object[]> rows;
                if (sql.contains("SELECT event.id,inspection.receipt_item_id")) {
                    assertThat(sql).contains("ORDER BY event.occurred_at,event.id");
                    rows = slices.stream().sorted(Comparator.comparing(row -> (UUID) row[0])).toList();
                } else if (sql.contains("SELECT receipt_item.id,order_item.id")) {
                    rows = anchors;
                } else if (sql.contains("FROM preplan_supply_action_allocations allocation")) {
                    rows = candidates;
                } else if (sql.contains("FROM production_material_supply_pegs peg")) {
                    rows = List.of();
                } else {
                    throw new AssertionError("Unexpected query: " + sql);
                }
                Query query = mock(Query.class, RETURNS_SELF);
                doReturn(rows).when(query).getResultList();
                queries.add(query);
                return query;
            });
            service = new PreplanInboundAllocationProjectionService(em, warehouses);
        }
        Map<UUID, List<AllocationView>> preview(UUID... events) {
            calls++;
            return service.expectedForPassEvents("PURCHASE", RECEIPT, List.of(events));
        }
        void assertReadOnly() {
            verify(em, times(calls * 4)).createNativeQuery(anyString());
            queries.forEach(query -> verify(query, never()).executeUpdate());
            verifyNoInteractions(warehouses);
        }
    }

    private static Map<String, BigDecimal> totals(Map<UUID, List<AllocationView>> result) {
        Map<String, BigDecimal> totals = expected("0", "0", "0", "0");
        result.values().stream().flatMap(Collection::stream).forEach(row -> {
            String key = row.analysisMaterialId() == null ? "PUBLIC" : row.analysisMaterialId().toString();
            totals.merge(key, row.qty(), BigDecimal::add);
        });
        return totals;
    }
    private static Map<String, BigDecimal> expected(String a, String b, String shared, String publicQty) {
        var result = new LinkedHashMap<String, BigDecimal>();
        result.put(MATERIAL_A.toString(), new BigDecimal(a));
        result.put(MATERIAL_B.toString(), new BigDecimal(b));
        result.put(MATERIAL_SHARED.toString(), new BigDecimal(shared));
        result.put("PUBLIC", new BigDecimal(publicQty));
        return result;
    }
    private static Object[] slice(int event, UUID receiptItem, UUID orderItem, String qty, UUID warehouse) {
        return new Object[]{id(event), receiptItem, warehouse, "实际仓", GOODS, null, new BigDecimal(qty), orderItem};
    }
    private static Object[] anchor(UUID receiptItem, UUID orderItem, UUID external, int line, String exact, String shared) {
        return new Object[]{receiptItem, orderItem, external, line, new BigDecimal(exact), new BigDecimal(shared)};
    }
    private static Object[] candidate(UUID external, UUID material, String mode, String headroom) {
        return new Object[]{external, id((int) material.getLeastSignificantBits()+1000), id((int) material.getLeastSignificantBits()+2000),
                mode, PLANNED_WAREHOUSE, "原计划仓", PLANNED_WAREHOUSE, id(500), material, GOODS, null,
                new BigDecimal(headroom), "P", "目标产品", "来源分析", null, null, null, null, null, null, null, null};
    }
    private static UUID id(int value) { return new UUID(0, value); }
}
