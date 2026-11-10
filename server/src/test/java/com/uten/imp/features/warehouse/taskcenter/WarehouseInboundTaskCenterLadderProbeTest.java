package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Page;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doCallRealMethod;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production warehouse INBOUND task center list
 * ({@code WarehouseInboundTaskCenterQueryService.list}, the complete-read path behind
 * /warehouse/tasks 入库组) through the shared progressive ladder exactly as the client's
 * fetchPageSized batches do, with a fully permissive superadmin-shaped reader. The SQL is
 * a multi-source UNION ALL computing COUNT in the same statement per batch; the printed
 * rows/batches/total_ms/first_batch_ms show whether the ladder clears the 3 s migration
 * bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class WarehouseInboundTaskCenterLadderProbeTest {

    @Test
    void inboundTaskCenterCompleteLadderTiming() throws Exception {
        try (Connection connection = DriverManager.getConnection(System.getenv("UTEN_DB_URL"),
                System.getenv("UTEN_DB_USER"), System.getenv("UTEN_DB_PASSWORD"))) {
            connection.setAutoCommit(false);
            connection.setReadOnly(true);
            try (var statement = connection.createStatement()) {
                statement.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY");
                statement.execute("SET LOCAL statement_timeout = '180s'");
                statement.execute("SET LOCAL lock_timeout = '2s'");
                statement.execute("SET LOCAL jit = off");
            }
            var named = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            UUID actor = UUID.randomUUID();
            AuthUser user = new AuthUser(actor, actor, "ladder-probe",
                    Set.of("warehouse_inbound:view", "warehouse_purchase_receipt_history:view",
                            "warehouse_subcontract_receipt_history:view", "warehouse_iqc_stock_in:view",
                            "warehouse_iqc_return:view", "stock_doc:view", "workshop_material:view"),
                    false, true, false);
            SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(user));
            when(current.employeeId()).thenReturn(Optional.of(actor));
            StockDocAccessPolicy stockAccess = mock(StockDocAccessPolicy.class);
            when(stockAccess.hasAuthority(anyString())).thenReturn(true);
            when(stockAccess.scope()).thenReturn(new OwnerScope(true, Set.of()));
            when(stockAccess.nativeReadScope(anyString(), anyString(),
                    any(com.uten.imp.security.OwnerVisibility.OwnerScope.class)))
                    .thenReturn(new NativeReadScope("1=1", null, Set.of()));
            ProductionStockTaskAccessPolicy productionAccess = mock(ProductionStockTaskAccessPolicy.class);
            when(productionAccess.canAccessWarehouseTasks()).thenReturn(true);
            WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
            doCallRealMethod().when(scopes).withQueryScopeCache(any());
            doCallRealMethod().when(scopes).currentForRead(any());
            when(scopes.current(any())).thenReturn(WarehouseTaskScope.ALL);
            var materialScopes = mock(com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope.class);
            when(materialScopes.readPredicate(anyString(), any(MapSqlParameterSource.class))).thenReturn("1=1");
            when(materialScopes.readRequisitionWarehouseFilter(any(), any(MapSqlParameterSource.class)))
                    .thenReturn("");
            when(materialScopes.readRequisitionPhysicalWarehouseFilter(any(), any(MapSqlParameterSource.class),
                    anyString(), anyString())).thenReturn("");
            var service = new WarehouseInboundTaskCenterQueryService(named,
                    new com.fasterxml.jackson.databind.ObjectMapper().findAndRegisterModules(),
                    current, scopes, stockAccess, productionAccess, materialScopes);

            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            long start = System.nanoTime(), firstBatchMs = -1;
            long seen = 0, total = -1;
            int batches = 0;
            while (true) {
                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                long b0 = System.nanoTime();
                Page result = service.list(new Filter(null, null, null, null, null, null, null, page, size),
                        seen == 0);
                long b1 = System.nanoTime();
                if (seen == 0) {
                    total = result.total();
                    firstBatchMs = (b1 - b0) / 1_000_000;
                    assertThat(total).isGreaterThanOrEqualTo(0);
                } else {
                    assertThat(result.total()).isEqualTo(total);
                }
                seen += result.items().size();
                batches++;
                if (seen >= total) break;
            }
            assertThat(seen).isEqualTo(total);
            System.out.printf(java.util.Locale.ROOT,
                    "LADDER_PROBE warehouse_inbound rows=%d batches=%d total_ms=%d first_batch_ms=%d%n",
                    total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs);
            connection.rollback();
        }
    }
}
