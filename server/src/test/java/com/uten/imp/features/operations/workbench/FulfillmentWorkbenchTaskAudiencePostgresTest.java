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
import org.testcontainers.postgresql.PostgreSQLContainer;

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
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static NamedParameterJdbcTemplate named;
    private final UUID own = UUID.randomUUID(), handover = UUID.randomUUID(), readOnly = UUID.randomUUID();

    @BeforeAll
    static void start() {
        POSTGRES.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        named = new NamedParameterJdbcTemplate(jdbc);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(jdbc,
                "purchase_orders","subcontract_orders","purchase_requests","subcontract_applications",
                "production_plans","v_procurement_decomposition_tasks","subcontract_short_delivery_cases",
                "subcontract_application_items","purchase_request_items");
        // Preserve this query oracle's actual parent identities/FKs. The catalog
        // projection deliberately does not bring unrelated business write guards.
        jdbc.execute("ALTER TABLE v_procurement_decomposition_tasks ADD FOREIGN KEY(plan_id) REFERENCES production_plans(id)");
        jdbc.execute("ALTER TABLE subcontract_application_items ALTER COLUMN application_id SET NOT NULL, ADD FOREIGN KEY(application_id) REFERENCES subcontract_applications(id)");
        jdbc.execute("ALTER TABLE purchase_request_items ALTER COLUMN request_id SET NOT NULL, ADD FOREIGN KEY(request_id) REFERENCES purchase_requests(id)");
        jdbc.execute("CREATE FUNCTION fn_subcontract_draw_edges(goods uuid) RETURNS TABLE(id uuid) LANGUAGE SQL AS 'SELECT goods WHERE goods IS NOT NULL'");
        com.uten.imp.support.MigratedProjectionSchema.installImportedDocumentPolicy(jdbc,
                "purchase_orders", "subcontract_orders", "purchase_requests", "subcontract_applications",
                "subcontract_application_items", "purchase_request_items", "production_plans");
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @BeforeEach
    void clear() {
        jdbc.execute("TRUNCATE purchase_orders, subcontract_orders, purchase_requests, subcontract_applications, production_plans, v_procurement_decomposition_tasks, subcontract_short_delivery_cases, subcontract_application_items, purchase_request_items");
    }

    @Test
    void decisionOnlyUserGetsOnlyWritableCasesWithoutInvalidEmptyInClause() {
        for (UUID owner : List.of(own, handover, readOnly)) {
            UUID order = order("SUBCONTRACT", owner, "FINANCE_APPROVED");
            shortCases(order, owner);
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
            // The list shows both goods lines, so both must contribute to the order's task badges.
            jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES (?, ?, ?, ?, 'FINANCE_REJECTED', 1)",
                    department, department + "_ORDER", first, UUID.randomUUID());
            order(department, handover, "FINANCE_REJECTED");
            order(department, readOnly, "FINANCE_REJECTED");
            order(department, null, "FINANCE_REJECTED");
            UUID application = UUID.randomUUID(), item = UUID.randomUUID();
            applicationHeader(department, application);
            applicationItem(department, application, item, UUID.randomUUID());
            jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES (?, ?, ?, ?, 'WAITING_ORDER', 1)",
                    department, department.equals("SUBCONTRACT") ? "SUBCONTRACT_APPLICATION" : "PURCHASE_REQUEST", application, item);
            var access = access();
            when(access.documentAccess(department, "ORDER")).thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));
            when(access.canCreatePurchaseOrder()).thenReturn(true);
            when(access.canCreateSubcontractOrder()).thenReturn(true);
            var service = service(access);

            assertEquals(new FulfillmentWorkbenchQueryService.PendingTaskCounts(4, 1, 3, 0),
                    service.pendingTaskCounts(department, WarehouseTaskScope.ALL));
            assertEquals(3, service.countInProgress(department));
        }
    }

    @Test
    void twoApplicationItemsCountAsTwoPendingTasksAndViewOnlyUsersStillHaveNone() {
        for (String department : List.of("PURCHASE", "SUBCONTRACT")) {
            UUID application = UUID.randomUUID();
            applicationHeader(department, application);
            for (int index = 0; index < 2; index++) {
                UUID item = UUID.randomUUID();
                applicationItem(department, application, item, UUID.randomUUID());
                jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES (?, ?, ?, ?, 'WAITING_ORDER', 1)",
                        department, department.equals("SUBCONTRACT") ? "SUBCONTRACT_APPLICATION" : "PURCHASE_REQUEST", application, item);
            }
            jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES (?, ?, ?, ?, 'WAITING_ORDER', 0)",
                    department, department.equals("SUBCONTRACT") ? "SUBCONTRACT_APPLICATION" : "PURCHASE_REQUEST", application, UUID.randomUUID());
            if (department.equals("SUBCONTRACT")) {
                UUID missingBomItem = UUID.randomUUID();
                applicationItem(department, application, missingBomItem, null);
                jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES ('SUBCONTRACT', 'SUBCONTRACT_APPLICATION', ?, ?, 'WAITING_ORDER', 1)",
                        application, missingBomItem);
            }
            var access = access();
            when(access.canCreatePurchaseOrder()).thenReturn(true);
            when(access.canCreateSubcontractOrder()).thenReturn(true);

            assertEquals(new FulfillmentWorkbenchQueryService.PendingTaskCounts(2, 2, 0, 0),
                    service(access).pendingTaskCounts(department, WarehouseTaskScope.ALL));
            assertEquals(FulfillmentWorkbenchQueryService.PendingTaskCounts.NONE,
                    service(access()).pendingTaskCounts(department, WarehouseTaskScope.ALL));
        }
    }

    @Test
    void decisionOnlyCountKeepsAffectedItemRowsWithoutCountingOtherGoodsOfTheSameOrder() {
        UUID order = order("SUBCONTRACT", own, "FINANCE_APPROVED");
        jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES ('SUBCONTRACT', 'SUBCONTRACT_ORDER', ?, ?, 'FINANCE_APPROVED', 1)",
                order, UUID.randomUUID());
        shortCases(order, own);
        jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES ('SUBCONTRACT', 'SUBCONTRACT_ORDER', ?, ?, 'FINANCE_APPROVED', 1)",
                order, UUID.randomUUID());
        var access = access();
        when(access.canDecideSubcontractShortDelivery()).thenReturn(true);

        assertEquals(new FulfillmentWorkbenchQueryService.PendingTaskCounts(2, 0, 0, 2),
                service(access).pendingTaskCounts("SUBCONTRACT", WarehouseTaskScope.ALL));
    }

    @Test
    void inProgressCountsEachItemAcrossFinanceStagesAndKeepsFulfilledRowsUntilTheOrderCloses() {
        for (String department : List.of("PURCHASE", "SUBCONTRACT")) {
            for (String stage : FulfillmentWorkbenchQueryService.IN_PROGRESS_STATUSES) {
                UUID order = order(department, own, stage);
                jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES (?, ?, ?, ?, ?, 0)",
                        department, department + "_ORDER", order, UUID.randomUUID(), stage);
            }
            order(department, readOnly, "FINANCE_APPROVED");
            UUID deleted = order(department, own, "FINANCE_APPROVED");
            jdbc.update("UPDATE " + department.toLowerCase() + "_orders SET is_deleted = true WHERE id = ?", deleted);
            var access = access();
            when(access.documentAccess(department, "ORDER")).thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));

            assertEquals(6, service(access).countInProgress(department));
        }
    }

    @Test
    void importedOrdersAndImportedPlanSourcesStayOutOfTheNativeTaskPool() {
        UUID nativeOrder = order("SUBCONTRACT", own, "FINANCE_APPROVED");
        UUID importedOrder = order("SUBCONTRACT", own, "FINANCE_APPROVED");
        jdbc.update("UPDATE subcontract_orders SET legacy_id=19001 WHERE id=?", importedOrder);
        UUID importedPlan = UUID.randomUUID();
        jdbc.update("INSERT INTO production_plans(id,legacy_id) VALUES (?,19002)", importedPlan);
        UUID planBoundOrder = order("SUBCONTRACT", own, "FINANCE_APPROVED");
        jdbc.update("UPDATE v_procurement_decomposition_tasks SET plan_id=? WHERE action_doc_id=?", importedPlan, planBoundOrder);
        assertEquals(false, jdbc.queryForObject(
                "SELECT fn_imported_business_document('subcontract_orders',?)", Boolean.class, nativeOrder));
        assertEquals(true, jdbc.queryForObject(
                "SELECT fn_imported_business_document('subcontract_orders',?)", Boolean.class, importedOrder));
        var access = access();
        when(access.documentAccess("SUBCONTRACT", "ORDER"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));
        assertEquals(1, service(access).countInProgress("SUBCONTRACT"));
    }

    private void applicationHeader(String department, UUID id) {
        String table = department.equals("SUBCONTRACT") ? "subcontract_applications" : "purchase_requests";
        jdbc.update("INSERT INTO " + table + "(id,maker_id) VALUES (?,?)", id, own);
    }

    private void applicationItem(String department, UUID application, UUID id, UUID goods) {
        boolean subcontract = department.equals("SUBCONTRACT");
        String table = subcontract ? "subcontract_application_items" : "purchase_request_items";
        String owner = subcontract ? "application_id" : "request_id";
        jdbc.update("INSERT INTO " + table + "(id,goods_id," + owner + ") VALUES (?,?,?)", id, goods, application);
    }

    private void shortCases(UUID order, UUID owner) {
        jdbc.update("""
                INSERT INTO subcontract_short_delivery_cases(order_id,order_item_id,owner_employee_id,status,severity,expected_complete_by)
                SELECT action_doc_id, action_item_id, ?, 'PENDING_OWNER', 'BELOW_FLOOR', NULL
                FROM v_procurement_decomposition_tasks WHERE action_doc_id = ?
                """, owner, order);
    }

    private UUID order(String department, UUID owner, String status) {
        UUID order = UUID.randomUUID();
        jdbc.update("INSERT INTO " + department.toLowerCase() + "_orders(id,maker_id,is_deleted) VALUES (?, ?, false)", order, owner);
        jdbc.update("INSERT INTO v_procurement_decomposition_tasks(department,action_doc_type,action_doc_id,action_item_id,task_status,open_qty) VALUES (?, ?, ?, ?, ?, 1)",
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
