package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractPreparationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.flywaydb.core.Flyway;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** V476 historical-data upgrade plus actual route confirmation/refresh on PostgreSQL. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisOptionalRouteReasonPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID UNIT = UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID PRODUCT = UUID.randomUUID();
    private static final UUID COMPONENT = UUID.randomUUID();
    private static final UUID BOM = UUID.randomUUID();
    private static UUID actor;
    private static UUID employee;
    private static JdbcTemplate jdbc;
    private static SessionFactory factory;
    private static EntityManager em;
    private static MaterialAnalysisService service;
    private static Fixture historical;
    private static Map<String, Object> historicalConfirmation;

    @BeforeAll
    static void upgradeHistoricalDatabase() {
        POSTGRES.start();
        migrate("476");
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        employee = jdbc.queryForObject("SELECT id FROM employees ORDER BY id LIMIT 1", UUID.class);
        actor = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, status)
                VALUES (?, ?, ?, 'test-only-hash', 'active')
                """, actor, employee, "optional-route-" + actor);
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, ?, 'piece')", UNIT, "RR-U-" + UNIT);
        jdbc.update("""
                INSERT INTO warehouses(id, code, name, status, is_accountable)
                VALUES (?, ?, 'Route reason warehouse', '使用', TRUE)
                """, WAREHOUSE, "RR-W-" + WAREHOUSE);
        insertGoods(PRODUCT, "自制");
        insertGoods(COMPONENT, "采购");
        jdbc.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, sort_order,
                    control_stage, consumption_basis, basis_output_qty, allow_partial_package, hard_gate)
                VALUES (?, ?, ?, 1, 1, 'START', 'PER_UNIT', 1, TRUE, TRUE)
                """, BOM, PRODUCT, COMPONENT);
        historical = createFixture();
        historicalConfirmation = confirmation(historical.materialId());
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_materials SET route_reason = '1' WHERE id = ?
                """, historical.materialId())).satisfies(MaterialAnalysisOptionalRouteReasonPostgresTest::checkViolation);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_materials SET route_reason = NULL WHERE id = ?
                """, historical.materialId())).satisfies(MaterialAnalysisOptionalRouteReasonPostgresTest::checkViolation);
        migrate("477");
        assertThat(confirmation(historical.materialId())).isEqualTo(historicalConfirmation);
        // Later independently developed migrations may add product-route fields
        // read by the current service. V477 preservation is verified first.
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        factory = new Configuration()
                .setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", POSTGRES.getJdbcUrl())
                .setProperty("hibernate.connection.username", POSTGRES.getUsername())
                .setProperty("hibernate.connection.password", POSTGRES.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none")
                .buildSessionFactory();
        em = factory.createEntityManager();
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.requireId()).thenReturn(actor);
        when(current.requireEmployeeId()).thenReturn(employee);
        when(current.employeeId()).thenReturn(Optional.of(employee));
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        service = new MaterialAnalysisService(em, current, mock(TxSessionVars.class), access,
                mock(OwnerVisibility.class), mock(SubcontractPreparationPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.features.production.analysis.PreplanStockEntitlementService.class),
                new MaterialAnalysisFlowStageService(em),
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
    }

    private static void migrate(String target) {
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }

    private static void insertGoods(UUID id, String source) {
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, code_sequence, source_type)
                VALUES (?, ?, 'Route reason material', ?,
                    (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods), ?)
                """, id, "RR-G-" + id, UNIT, source);
    }

    private static Fixture createFixture() {
        UUID analysisId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(id, warehouse_id, status, fingerprint,
                    initial_idempotency_key, maker_id, created_by, updated_by)
                VALUES (?, ?, 'ACTIVE', ?, ?, ?, ?, ?)
                """, analysisId, WAREHOUSE, "a".repeat(64), "optional-route-" + analysisId,
                employee, actor, actor);
        jdbc.update("""
                INSERT INTO production_material_analysis_items(id, analysis_id, source_type, goods_id,
                    unit_id, source_ref, source_reason, requested_qty, line_priority, created_by, updated_by)
                VALUES (?, ?, 'OTHER', ?, ?, ?, 'Optional route reason regression', 10, 1, ?, ?)
                """, itemId, analysisId, PRODUCT, UNIT, "RR-SOURCE-" + itemId, actor, actor);
        jdbc.update("""
                INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id,
                    node_key, bom_item_id, goods_id, unit_id, depth, path, per_product_qty,
                    required_qty, available_qty, allocated_available_qty, shortage_qty,
                    control_stage, consumption_basis, basis_output_qty, allow_partial_package, hard_gate,
                    bom_qty, parent_per_product_qty, calculation_mode, source_suggestion,
                    confirmed_route, route_reason, route_confirmed_by, route_confirmed_at, created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, 1, 10, 0, 0, 10,
                    'START', 'PER_UNIT', 1, TRUE, TRUE, 1, 1, 'EDGE_RULE', 'BUY',
                    'SUBCONTRACT', 'Historical reason retained', ?, '2026-09-01T00:00:00Z', ?, ?)
                """, materialId, analysisId, itemId, BOM.toString(), BOM, COMPONENT, UNIT,
                BOM.toString(), actor, actor, actor);
        return new Fixture(analysisId, materialId);
    }

    @AfterAll
    static void stopPostgres() {
        if (em != null) em.close();
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @Test
    void forwardMigrationAndRefreshPreserveHistoricalConfirmationIdentityAndReason() {
        assertThat(confirmation(historical.materialId())).isEqualTo(historicalConfirmation);
        transaction(() -> { service.refreshLocked(historical.analysisId()); return null; });
        assertThat(confirmation(historical.materialId())).isEqualTo(historicalConfirmation);
    }

    @Test
    void actualConfirmationAndRefreshAcceptNullBlankSingleCharacterAndMaximumLength() {
        Fixture fixture = createFixture();
        for (String reason : new String[]{null, " \t\n", "1", "理".repeat(1000)}) {
            confirm(fixture, "MAKE", reason);
            Map<String, Object> saved = confirmation(fixture.materialId());
            assertThat(saved.get("confirmed_route")).isEqualTo("MAKE");
            assertThat(saved.get("route_reason")).isEqualTo(MaterialAnalysisService.normalizeRouteReason(reason));
            assertThat(saved.get("route_confirmed_by")).isEqualTo(actor);
            assertThat(saved.get("route_confirmed_at")).isNotNull();
            transaction(() -> { service.refreshLocked(fixture.analysisId()); return null; });
            assertThat(confirmation(fixture.materialId())).isEqualTo(saved);
        }
    }

    @Test
    void oversizedReasonFailsAtServiceAndDatabaseWithoutChangingTheSavedRoute() {
        Fixture fixture = createFixture();
        Map<String, Object> before = confirmation(fixture.materialId());
        assertThrows(ApiException.class, () -> confirm(fixture, "MAKE", "理".repeat(1001)));
        assertThat(confirmation(fixture.materialId())).isEqualTo(before);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_materials SET route_reason = ? WHERE id = ?
                """, "理".repeat(1001), fixture.materialId()))
                .satisfies(MaterialAnalysisOptionalRouteReasonPostgresTest::checkViolation);
        assertThat(confirmation(fixture.materialId())).isEqualTo(before);
    }

    @Test
    void optionalReasonDoesNotPermitInvalidRoutesOrIncompleteConfirmationAudit() {
        Fixture fixture = createFixture();
        for (String change : List.of("route_confirmed_by = NULL", "route_confirmed_at = NULL",
                "confirmed_route = NULL, route_reason = NULL", "confirmed_route = 'INVALID'")) {
            assertThatThrownBy(() -> jdbc.update(
                    "UPDATE production_material_analysis_materials SET " + change + " WHERE id = ?",
                    fixture.materialId())).satisfies(MaterialAnalysisOptionalRouteReasonPostgresTest::checkViolation);
        }
        jdbc.update("""
                UPDATE production_material_analysis_materials SET confirmed_route = NULL,
                    route_reason = NULL, route_confirmed_by = NULL, route_confirmed_at = NULL WHERE id = ?
                """, fixture.materialId());
        assertThat(confirmation(fixture.materialId()).values()).allMatch(value -> value == null);
    }

    @Test
    void reviewSuggestionAllowsNoReasonWhileBlankDirectSqlMustUseNull() {
        Fixture fixture = createFixture();
        jdbc.update("""
                UPDATE production_material_analysis_materials
                SET source_suggestion = 'REVIEW', confirmed_route = 'BUY', route_reason = NULL WHERE id = ?
                """, fixture.materialId());
        assertThat(confirmation(fixture.materialId()).get("route_reason")).isNull();
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE production_material_analysis_materials SET route_reason = ' ' WHERE id = ?
                """, fixture.materialId())).satisfies(MaterialAnalysisOptionalRouteReasonPostgresTest::checkViolation);
    }

    private static void confirm(Fixture fixture, String route, String reason) {
        transaction(() -> {
            var header = service.lockHeader(fixture.analysisId());
            return service.saveRoutes(fixture.analysisId(), new RouteRequest(header.version(),
                    header.fingerprint(), "optional-confirm-" + UUID.randomUUID(),
                    List.of(new RouteDecision(fixture.materialId(), null, route, reason))));
        });
    }

    private static Map<String, Object> confirmation(UUID materialId) {
        return jdbc.queryForMap("""
                SELECT confirmed_route, route_reason, route_confirmed_by, route_confirmed_at
                FROM production_material_analysis_materials WHERE id = ?
                """, materialId);
    }

    private static <T> T transaction(Supplier<T> action) {
        em.getTransaction().begin();
        try {
            em.createNativeQuery("SELECT set_config('app.actor_id', :actor, TRUE)")
                    .setParameter("actor", actor.toString()).getSingleResult();
            T result = action.get();
            em.getTransaction().commit();
            return result;
        } catch (RuntimeException error) {
            if (em.getTransaction().isActive()) em.getTransaction().rollback();
            throw error;
        }
    }

    private static void checkViolation(Throwable error) {
        Throwable root = error;
        while (root.getCause() != null) root = root.getCause();
        assertThat(root).isInstanceOf(PSQLException.class);
        assertThat(((PSQLException) root).getSQLState()).isEqualTo("23514");
    }

    private record Fixture(UUID analysisId, UUID materialId) {}
}
