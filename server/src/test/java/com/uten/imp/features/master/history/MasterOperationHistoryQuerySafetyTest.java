package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.warehouse.WarehouseMasterRules;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class MasterOperationHistoryQuerySafetyTest {
    private final EntityManager em = mock(EntityManager.class);
    private final ObjectMapper json = new ObjectMapper();
    private final WarehouseMasterRules warehouses = mock(WarehouseMasterRules.class);
    private final MasterOperationHistoryService service =
            new MasterOperationHistoryService(em, json, null, null, null, null, warehouses);

    @Test
    void completeSnapshotStatementsCoverExactlyTheAuthoritativeDomainTables() {
        Map<?, ?> domains = Objects.requireNonNull((Map<?, ?>) ReflectionTestUtils.getField(MasterOperationHistoryService.class, "DOMAINS"));
        Map<?, ?> statements = Objects.requireNonNull((Map<?, ?>) ReflectionTestUtils.getField(MasterOperationHistoryService.class, "SNAPSHOT_SQL"));
        Set<Object> tables = new HashSet<>();
        for (Object domain : domains.values()) {
            Set<?> allowed = Objects.requireNonNull(ReflectionTestUtils.invokeMethod(domain, "tables"));
            tables.addAll(allowed);
        }
        assertThat(statements.keySet()).isEqualTo(tables);
    }

    @Test
    void sqlShapedRelationNamesAreRejectedBeforeAnyDatabaseAccess() {
        for (String name : List.of("colors; SELECT pg_sleep(1)--", "colors'::regclass,t)--", "unknown")) {
            assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(service, "snapshot", name, UUID.randomUUID()))
                    .isInstanceOf(ApiException.class).hasMessageContaining("不支持的资料表");
        }
        verifyNoInteractions(em);
    }

    @Test
    void absentUndoTargetsStillEnforceBaseCurrencyAndWarehouseRetirementGuards() throws Exception {
        UUID currencyId = UUID.randomUUID();
        JsonNode currency = json.createObjectNode().put("is_base_currency", true).put("status", "使用");
        Object currencyRow = row("currencies", currencyId, null, currency, currency);
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(service, "validateTargets", List.of(currencyRow), true))
                .isInstanceOf(ApiException.class).hasMessageContaining("本位币必须保持启用");

        UUID warehouseId = UUID.randomUUID();
        JsonNode warehouse = json.createObjectNode().put("status", "使用");
        when(warehouses.retirementBlockers(List.of(warehouseId))).thenReturn(Map.of(warehouseId, List.of("库存")));
        Object warehouseRow = row("warehouses", warehouseId, null, warehouse, warehouse);
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(service, "validateTargets", List.of(warehouseRow), true))
                .isInstanceOf(ApiException.class).hasMessageContaining("该仓库仍有库存");
        verifyNoInteractions(em);
    }

    private static Object row(String table, UUID id, JsonNode before, JsonNode after, JsonNode expected) throws Exception {
        Class<?> type = Class.forName(MasterOperationHistoryService.class.getName() + "$Row");
        var constructor = type.getDeclaredConstructor(String.class, UUID.class, JsonNode.class, JsonNode.class, JsonNode.class);
        constructor.setAccessible(true);
        return constructor.newInstance(table, id, before, after, expected);
    }
}
