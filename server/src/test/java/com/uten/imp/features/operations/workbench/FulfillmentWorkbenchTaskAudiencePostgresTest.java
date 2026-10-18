package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Executes the task count SQL against PostgreSQL, including the decision-only branch and owner filtering. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentWorkbenchTaskAudiencePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static NamedParameterJdbcTemplate named;
    private final UUID own = UUID.randomUUID(), handover = UUID.randomUUID(), readOnly = UUID.randomUUID();

    @BeforeAll
    static void start() {
        POSTGRES.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        named = new NamedParameterJdbcTemplate(jdbc);
        jdbc.execute("CREATE TABLE purchase_orders (id uuid PRIMARY KEY, maker_id uuid, is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE subcontract_orders (id uuid PRIMARY KEY, maker_id uuid, is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE v_procurement_decomposition_tasks (department text, action_doc_type text, action_doc_id uuid, action_item_id uuid, task_status text, open_qty numeric)");
        jdbc.execute("CREATE TABLE subcontract_short_delivery_cases (order_id uuid, owner_employee_id uuid, status text, severity text, expected_complete_by date)");
        jdbc.execute("CREATE TABLE subcontract_application_items (id uuid PRIMARY KEY, goods_id uuid, is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE FUNCTION fn_subcontract_draw_edges(goods uuid) RETURNS TABLE(id uuid) LANGUAGE SQL AS 'SELECT goods'");
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @BeforeEach
    void clear() {
        jdbc.execute("TRUNCATE purchase_orders, subcontract_orders, v_procurement_decomposition_tasks, subcontract_short_delivery_cases, subcontract_application_items");
    }

    @Test
    void decisionOnlyUserGetsOnlyWritableCasesWithoutInvalidEmptyInClause() {
        for (UUID owner : List.of(own, handover, readOnly)) {
            UUID order = order("SUBCONTRACT", owner, "FINANCE_APPROVED");
            jdbc.update("INSERT INTO subcontract_short_delivery_cases VALUES (?, ?, 'PENDING_OWNER', 'BELOW_FLOOR', NULL)", order, owner);
        }
        var access = access();
        when(access.canDecideSubcontractShortDelivery()).thenReturn(true);

        var counts = service(access).pendingTaskCounts("SUBCONTRACT", WarehouseTaskScope.ALL);

        assertEquals(new FulfillmentWorkbenchQueryService.PendingTaskCounts(2, 0, 0, 2), counts);
    }

    @Test
    void reworkAndInProgressExcludeReadOnlyOwnersWhileRequestsRemainAnAuthorizedPublicPool() {
        for (String department : List.of("PURCHASE", "SUBCONTRACT")) {
            UUID first = order(department, own, "FINANCE_REJECTED");
            // A second goods line must not create a second task for the same rejected order.
            jdbc.update("INSERT INTO v_procurement_decomposition_tasks VALUES (?, ?, ?, ?, 'FINANCE_REJECTED', 1)",
                    department, department + "_ORDER", first, UUID.randomUUID());
            order(department, handover, "FINANCE_REJECTED");
            order(department, readOnly, "FINANCE_REJECTED");
            order(department, null, "FINANCE_REJECTED");
            UUID application = UUID.randomUUID(), item = UUID.randomUUID();
            jdbc.update("INSERT INTO subcontract_application_items VALUES (?, ?, false)", item, UUID.randomUUID());
            jdbc.update("INSERT INTO v_procurement_decomposition_tasks VALUES (?, ?, ?, ?, 'WAITING_ORDER', 1)",
                    department, department.equals("SUBCONTRACT") ? "SUBCONTRACT_APPLICATION" : "PURCHASE_REQUEST", application, item);
            var access = access();
            when(access.documentAccess(department, "ORDER")).thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));
            when(access.canCreatePurchaseOrder()).thenReturn(true);
            when(access.canCreateSubcontractOrder()).thenReturn(true);
            var service = service(access);

            assertEquals(new FulfillmentWorkbenchQueryService.PendingTaskCounts(3, 1, 2, 0),
                    service.pendingTaskCounts(department, WarehouseTaskScope.ALL));
            assertEquals(2, service.countInProgress(department));
        }
    }

    private UUID order(String department, UUID owner, String status) {
        UUID order = UUID.randomUUID();
        jdbc.update("INSERT INTO " + department.toLowerCase() + "_orders VALUES (?, ?, false)", order, owner);
        jdbc.update("INSERT INTO v_procurement_decomposition_tasks VALUES (?, ?, ?, ?, ?, 1)",
                department, department + "_ORDER", order, UUID.randomUUID(), status);
        return order;
    }

    private FulfillmentWorkbenchAccessPolicy access() {
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.orderTaskScope(anyString(), anyString(), anyString())).thenAnswer(call ->
                new NativeReadScope(call.getArgument(1) + " IN (:" + call.getArgument(2) + ")",
                        call.getArgument(2), Set.of(own, handover)));
        return access;
    }

    private static FulfillmentWorkbenchQueryService service(FulfillmentWorkbenchAccessPolicy access) {
        var em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            Map<String, Object> params = new HashMap<>();
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> {
                params.put(binding.getArgument(0), binding.getArgument(1));
                return query;
            });
            when(query.getSingleResult()).thenAnswer(read -> named.queryForObject(sql, params, (rs, index) -> {
                int columns = rs.getMetaData().getColumnCount();
                if (columns == 1) return rs.getLong(1);
                Object[] values = new Object[columns];
                for (int column = 0; column < columns; column++) values[column] = rs.getLong(column + 1);
                return values;
            }));
            return query;
        });
        return new FulfillmentWorkbenchQueryService(em, access);
    }
}
