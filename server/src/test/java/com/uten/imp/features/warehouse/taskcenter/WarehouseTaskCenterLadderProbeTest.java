package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Page;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doCallRealMethod;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production warehouse OUTBOUND task center list
 * ({@code WarehouseOutboundTaskCenterQueryService.list}, the complete-read path behind
 * /warehouse/tasks 出库组) through the shared progressive ladder exactly as the client's
 * fetchPageSized batches do, with a fully permissive superadmin-shaped reader. The SQL is
 * a multi-source UNION ALL whose single statement also computes COUNT per batch; the
 * printed rows/batches/total_ms/first_batch_ms show whether the ladder clears the 3 s
 * migration bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class WarehouseOutboundTaskCenterLadderProbeTest {

    private static final class Counter {
        final AtomicInteger statements = new AtomicInteger();
        long nanos;
    }

    private static Query query(NamedParameterJdbcTemplate named, String sql, Counter counter) {
        Map<String, Object> parameters = new LinkedHashMap<>();
        return mock(Query.class, call -> {
            String method = call.getMethod().getName();
            if (method.equals("setParameter")) { parameters.put(call.getArgument(0), call.getArgument(1)); return call.getMock(); }
            if (method.equals("getResultList") || method.equals("getSingleResult")) {
                counter.statements.incrementAndGet();
                long start = System.nanoTime();
                try {
                    if (method.equals("getSingleResult")) return named.queryForObject(sql, parameters, Object.class);
                    return named.query(sql, parameters, (rs, row) -> {
                        if (rs.getMetaData().getColumnCount() == 1) return rs.getObject(1);
                        Object[] values = new Object[rs.getMetaData().getColumnCount()];
                        for (int column = 0; column < values.length; column++) values[column] = rs.getObject(column + 1);
                        return values;
                    });
                } finally { counter.nanos += System.nanoTime() - start; }
            }
            if (call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }

    @Test
    void outboundTaskCenterCompleteLadderTiming() throws Exception {
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
            var counter = new Counter();
            EntityManager em = mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(call -> query(named, call.getArgument(0), counter));
            UUID actor = UUID.randomUUID();
            AuthUser user = new AuthUser(actor, actor, "ladder-probe",
                    Set.of("warehouse_sales_outbound:view", "subcontract_outbound:view",
                            "warehouse_subcontract_outbound_history:view", "stock_doc:view", "workshop_material:view"),
                    false, true, false);
            StockDocAccessPolicy access = mock(StockDocAccessPolicy.class);
            when(access.hasAuthority(anyString())).thenReturn(true);
            when(access.scope()).thenReturn(new OwnerScope(true, Set.of()));
            when(access.nativeReadScope(anyString(), anyString(),
                    any(com.uten.imp.security.OwnerVisibility.OwnerScope.class)))
                    .thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1", null, Set.of()));
            SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(user));
            when(current.employeeId()).thenReturn(Optional.of(actor));
            WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
            doCallRealMethod().when(scopes).withQueryScopeCache(any());
            doCallRealMethod().when(scopes).currentForRead(any());
            when(scopes.current(any())).thenReturn(WarehouseTaskScope.ALL);
            ProductionStockTaskAccessPolicy tasks = mock(ProductionStockTaskAccessPolicy.class);
            when(tasks.canAccessWarehouseTasks()).thenReturn(true);
            when(tasks.canBrowseWarehouseTasks()).thenReturn(true);
            var materialScopes = mock(com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope.class);
            when(materialScopes.readPredicate(anyString(), any(org.springframework.jdbc.core.namedparam.MapSqlParameterSource.class)))
                    .thenReturn("1=1");
            when(materialScopes.readRequisitionWarehouseFilter(any(), any(org.springframework.jdbc.core.namedparam.MapSqlParameterSource.class)))
                    .thenReturn("");
            when(materialScopes.readRequisitionPhysicalWarehouseFilter(any(),
                    any(org.springframework.jdbc.core.namedparam.MapSqlParameterSource.class), anyString(), anyString()))
                    .thenReturn("");
            var service = new WarehouseOutboundTaskCenterQueryService(em, access, current, scopes, tasks,
                    mock(com.uten.imp.audit.AuditDetailViewRecorder.class), materialScopes,
                    new com.fasterxml.jackson.databind.ObjectMapper());

            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            long start = System.nanoTime(), firstBatchMs = -1;
            long seen = 0, total = -1;
            int batches = 0, statements = 0;
            while (true) {
                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                int before = counter.statements.get();
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
                statements += counter.statements.get() - before;
                batches++;
                if (seen >= total) break;
            }
            assertThat(seen).isEqualTo(total);
            System.out.printf(java.util.Locale.ROOT,
                    "LADDER_PROBE warehouse_outbound rows=%d batches=%d total_ms=%d first_batch_ms=%d statements=%d%n",
                    total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs, statements);
            connection.rollback();
        }
    }
}
