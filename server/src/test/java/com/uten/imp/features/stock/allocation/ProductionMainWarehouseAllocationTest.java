package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionMainWarehouseAllocationTest {
    private final UUID demand = UUID.randomUUID();
    private final UUID goods = UUID.randomUUID();
    private final UUID mainWarehouse = new UUID(0, 99);
    private final UUID warehouseA = new UUID(0, 1), warehouseB = new UUID(0, 2);
    private final Map<UUID, BigDecimal> stock = new HashMap<>();
    private final Map<UUID, BigDecimal> reserved = new HashMap<>();
    private final Map<UUID, BigDecimal> safety = new HashMap<>();
    private final List<Map<String, Object>> writes = new ArrayList<>();

    @Test
    void oneDemandSplitsAcrossActualLeavesWithoutOverReserving() {
        stock.put(warehouseA, new BigDecimal("4"));
        stock.put(warehouseB, new BigDecimal("8"));
        var result = service().allocateWithinMainWarehouse(List.of(request("10")), List.of());
        assertThat(result).extracting(ProductionMaterialAllocationFacade.AllocationResult::warehouseId)
                .containsExactly(warehouseA, warehouseB);
        assertThat(result).extracting(ProductionMaterialAllocationFacade.AllocationResult::allocatedQty)
                .containsExactly(new BigDecimal("4"), new BigDecimal("6"));
        assertThat(reserved.get(warehouseB)).isEqualByComparingTo("6");
        assertThat(writes).hasSize(2);
    }

    @Test
    void formalizingAnOwnedLotUsesItsActualLeafBeforeOtherPublicStock() {
        stock.put(warehouseA, new BigDecimal("20"));
        stock.put(warehouseB, new BigDecimal("6"));
        var result = service().allocateWithinMainWarehouse(List.of(request("10")),
                List.of(new ProductionMaterialAllocationFacade.AllocationPreference(
                        demand, warehouseB, new BigDecimal("6"))));
        assertThat(result).extracting(ProductionMaterialAllocationFacade.AllocationResult::warehouseId)
                .containsExactly(warehouseB, warehouseA);
        assertThat(result).extracting(ProductionMaterialAllocationFacade.AllocationResult::allocatedQty)
                .containsExactly(new BigDecimal("6"), new BigDecimal("4"));
    }

    @Test
    void ownedAndPublicStockInTheSameLeafCreateOneReservation() {
        stock.put(warehouseA, new BigDecimal("10"));
        var result = service().allocateWithinMainWarehouse(List.of(request("10")),
                List.of(new ProductionMaterialAllocationFacade.AllocationPreference(
                        demand, warehouseA, new BigDecimal("5"))));
        assertThat(result).hasSize(1);
        assertThat(result.getFirst().allocatedQty()).isEqualByComparingTo("10");
        assertThat(result.getFirst().warehouseId()).isEqualTo(warehouseA);
        assertThat(writes).hasSize(1);
    }

    @Test
    void publicStockCannotConsumeCapacityNeededForAnotherLeafsOwnedLot() {
        stock.put(warehouseA, new BigDecimal("20"));
        stock.put(warehouseB, new BigDecimal("6"));
        var result = service().allocateWithinMainWarehouse(List.of(request("10")),
                List.of(new ProductionMaterialAllocationFacade.AllocationPreference(
                                demand, warehouseA, new BigDecimal("4")),
                        new ProductionMaterialAllocationFacade.AllocationPreference(
                                demand, warehouseB, new BigDecimal("6"))));
        assertThat(result).extracting(ProductionMaterialAllocationFacade.AllocationResult::allocatedQty)
                .containsExactly(new BigDecimal("4"), new BigDecimal("6"));
        assertThat(reserved.get(warehouseA)).isEqualByComparingTo("4");
    }

    @Test
    void anOwnedLotOutsideTheAuthorizedMainWarehouseIsRejectedBeforeWriting() {
        assertThatThrownBy(() -> service().allocateWithinMainWarehouse(List.of(request("10")),
                List.of(new ProductionMaterialAllocationFacade.AllocationPreference(
                        demand, UUID.randomUUID(), BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("主仓范围");
        assertThat(writes).isEmpty();
    }

    @Test
    void anotherLeafsPublicStockCanSupplyWhileAnOwnedSafetyLotStaysProtected() {
        stock.put(warehouseA, new BigDecimal("5"));
        reserved.put(warehouseA, new BigDecimal("5"));
        stock.put(warehouseB, new BigDecimal("10"));
        safety.put(warehouseA, new BigDecimal("5"));
        safety.put(warehouseB, new BigDecimal("5"));
        var result = service().allocateWithinMainWarehouse(List.of(request("5")), List.of());
        assertThat(result).singleElement().satisfies(value -> {
            assertThat(value.warehouseId()).isEqualTo(warehouseB);
            assertThat(value.allocatedQty()).isEqualByComparingTo("5");
        });
        assertThat(reserved.get(warehouseA)).isEqualByComparingTo("5");
    }

    @Test
    void thirtyPlusSeventyKeepsTwentyOnceAndReplaysWithoutNewReservations() {
        stock.put(warehouseA, new BigDecimal("30")); stock.put(warehouseB, new BigDecimal("70"));
        safety.put(warehouseA, new BigDecimal("20")); safety.put(warehouseB, new BigDecimal("20"));
        var service = service(); var request = request("80");
        var result = service.allocateWithinMainWarehouse(List.of(request), List.of());
        assertThat(result).extracting(ProductionMaterialAllocationFacade.AllocationResult::allocatedQty)
                .containsExactly(new BigDecimal("30"), new BigDecimal("50"));
        assertThat(service.allocateWithinMainWarehouse(List.of(request), List.of()))
                .allMatch(ProductionMaterialAllocationFacade.AllocationResult::replayed);
        assertThat(writes).hasSize(2);
        assertThat(reserved.values().stream().reduce(BigDecimal.ZERO, BigDecimal::add)).isEqualByComparingTo("80");
    }

    @Test
    void explicitlySelectedLeafCanUseBufferKeptInItsSiblingWithoutTakingSiblingStock() {
        stock.put(warehouseA, new BigDecimal("30")); stock.put(warehouseB, new BigDecimal("70"));
        safety.put(warehouseA, new BigDecimal("20")); safety.put(warehouseB, new BigDecimal("20"));
        assertThat(service().allocate(List.of(request("30")))).singleElement().satisfies(value -> {
            assertThat(value.warehouseId()).isEqualTo(warehouseA);
            assertThat(value.allocatedQty()).isEqualByComparingTo("30");
        });
        assertThat(reserved.getOrDefault(warehouseB, BigDecimal.ZERO)).isZero();
    }

    @Test
    void publicAllocationCannotSpendAnotherDemandsPreparedOwnedSlice() {
        stock.put(warehouseB, new BigDecimal("100"));
        safety.put(warehouseA, new BigDecimal("20")); safety.put(warehouseB, new BigDecimal("20"));
        UUID first=new UUID(0,10),second=new UUID(0,20),packageId=UUID.randomUUID(),actor=UUID.randomUUID();
        var requests=List.of(new ProductionMaterialAllocationFacade.AllocationRequest(packageId,first,goods,null,
                        warehouseA,new BigDecimal("60"),"first-public",actor),
                new ProductionMaterialAllocationFacade.AllocationRequest(packageId,second,goods,null,
                        warehouseA,new BigDecimal("60"),"second-owned",actor));
        var result=service().allocateWithinMainWarehouse(requests,List.of(
                new ProductionMaterialAllocationFacade.AllocationPreference(second,warehouseB,new BigDecimal("60"))));
        assertThat(result.stream().filter(row->row.demandId().equals(first)).map(
                ProductionMaterialAllocationFacade.AllocationResult::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add))
                .isEqualByComparingTo("20");
        assertThat(result.stream().filter(row->row.demandId().equals(second)).map(
                ProductionMaterialAllocationFacade.AllocationResult::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add))
                .isEqualByComparingTo("60");
    }

    private ProductionMaterialAllocationFacade.AllocationRequest request(String quantity) {
        return new ProductionMaterialAllocationFacade.AllocationRequest(UUID.randomUUID(), demand,
                goods, null, warehouseA, new BigDecimal(quantity),
                "test-main-warehouse-allocation", UUID.randomUUID());
    }

    private ProductionMaterialAllocationFacade service() {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Map<String, Object> parameters = new HashMap<>();
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> {
                parameters.put(binding.getArgument(0), binding.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("SELECT id,fn_warehouse_main_id(id)"))
                    return List.of(new Object[]{warehouseA, mainWarehouse}, new Object[]{warehouseB, mainWarehouse});
                if (sql.contains("SELECT warehouse.id,fn_warehouse_main_id"))
                    return List.of(new Object[]{warehouseA, mainWarehouse}, new Object[]{warehouseB, mainWarehouse});
                if (sql.contains("SELECT id\n") && sql.contains("production_material_demands")) return parameters.get("ids");
                if (sql.contains("idempotency_key,requires_qualified_origin")) {
                    return writes.stream().map(write -> new Object[]{write.get("id"), write.get("demandId"),
                            write.get("supplyId"), write.get("qty"), write.get("goodsId"), write.get("colorId"),
                            write.get("warehouseId"), write.get("key"), false}).toList();
                }
                if (sql.contains("SELECT balance.id,balance.warehouse_id")) {
                    return List.of(warehouseA, warehouseB).stream().map(warehouse -> new Object[]{warehouse, warehouse,
                            goods, null, stock.getOrDefault(warehouse, BigDecimal.ZERO),
                            reserved.getOrDefault(warehouse, BigDecimal.ZERO), safety.getOrDefault(warehouse, BigDecimal.ZERO), mainWarehouse}).toList();
                }
                throw new AssertionError(sql);
            });
            when(query.getSingleResult()).thenAnswer(ignored -> reserved.getOrDefault(
                    parameters.get("warehouseId"), BigDecimal.ZERO));
            when(query.executeUpdate()).thenAnswer(ignored -> {
                writes.add(new HashMap<>(parameters));
                reserved.merge((UUID) parameters.get("warehouseId"),
                        (BigDecimal) parameters.get("qty"), BigDecimal::add);
                return 1;
            });
            return query;
        });
        return new ProductionMaterialAllocationFacade(em,
                mock(InventoryMutationLock.class), mock(TxSessionVars.class));
    }
}
