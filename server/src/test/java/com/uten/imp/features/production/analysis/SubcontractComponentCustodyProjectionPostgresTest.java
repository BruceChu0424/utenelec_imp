package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.math.MathContext;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Exercises the real projection SQL; only its input relations are replaced by read-only CTEs. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractComponentCustodyProjectionPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ANALYSIS = UUID.fromString("00000000-0000-0000-0000-000000000001");
    private static final BigDecimal EPSILON = new BigDecimal("0.0000000000000001");

    @BeforeAll static void start() { DB.start(); }
    @AfterAll static void stop() { DB.stop(); }

    @Test void allRoundedCustodyStaysWithItsExactParent() throws Exception {
        assertProjection("1", "1", "1", "1", List.of("0.3333", "0.3334", "0.3333"),
                List.of("0.3333", "0.3334", "0.3333"));
    }

    @Test void issuingOnlyTheRemainderParentDoesNotInventPublicIssueForOtherParents() throws Exception {
        assertProjection("1", "1", "1", "0.3334", List.of("0", "0.3334", "0"),
                List.of("0", "0.3334", "0"));
    }

    @Test void nonUnitOrderRateDoesNotEraseTheRoundedCustodySlices() throws Exception {
        assertProjection("2", "2", "1", "2", List.of("0.6667", "0.6666", "0.6667"),
                List.of("0.6667", "0.6666", "0.6667"));
    }

    @Test void frozenBomAndBothUnitRatesConvertEachExactSliceBeforePublicAllocation() throws Exception {
        // order rate 2 and BOM edge 0.7 freeze 1.4 component base units per order unit.
        // An issue unit contains 10 component base units; custody already stores base units.
        assertProjection("2", "1.4", "10", "1.4", List.of("0.4667", "0.4666", "0.4667"),
                List.of(parentQty("0.4667", "1.4", "2"), parentQty("0.4666", "1.4", "2"),
                        parentQty("0.4667", "1.4", "2")));
    }

    @Test void genuinelyPublicIssueStillSharesTheUncoveredParentCapacity() throws Exception {
        assertProjection("1", "1", "1", "1", List.of("0", "0", "0"),
                List.of("0.3333", "0.3334", "0.3333"));
    }

    @Test void partialNonUnitCustodyDoesNotDistributeDivisionRoundoffToAnUnissuedParent() throws Exception {
        assertProjection("2", "1.4", "1", "0.9334", List.of("0.4667", "0", "0.4667"),
                List.of(parentQty("0.4667", "1.4", "2"), "0", parentQty("0.4667", "1.4", "2")));
    }

    @Test void exactRemainderIsPreservedWhenTheOtherTwoParentsUsePublicStock() throws Exception {
        assertProjection("1", "1", "1", "1", List.of("0", "0.3334", "0"),
                List.of("0.3333", "0.3334", "0.3333"));
    }

    private static String parentQty(String component, String frozen, String rate) {
        return new BigDecimal(component).divide(new BigDecimal(frozen), MathContext.DECIMAL128)
                .multiply(new BigDecimal(rate)).toPlainString();
    }

    private static void assertProjection(String orderRate, String frozen, String issueRate,
                                         String issuedComponent, List<String> consumed,
                                         List<String> expected) throws Exception {
        String actualSql = productionSql().replace(":analysisId", "'" + ANALYSIS + "'::uuid");
        assertThat(actualSql).startsWith("WITH ");
        String sql = fixtureSql(orderRate, frozen, issueRate, issuedComponent, consumed)
                + "," + actualSql.substring("WITH".length());
        Map<String, BigDecimal> rows = new LinkedHashMap<>();
        try (var connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())) {
            connection.setReadOnly(true);
            try (var statement = connection.createStatement()) {
                statement.setQueryTimeout(10);
                try (var result = statement.executeQuery(sql)) {
                    while (result.next()) rows.put(result.getString(2), result.getBigDecimal(3));
                }
            }
        }
        assertThat(rows).hasSize(3);
        for (int i = 0; i < 3; i++) {
            BigDecimal expectedQuantity = new BigDecimal(expected.get(i));
            if (expectedQuantity.signum() == 0) {
                assertThat(rows.get("P-" + (i + 1))).as("unissued parent %s", i + 1).isZero();
            } else {
                assertThat(rows.get("P-" + (i + 1))).as("exact parent %s", i + 1)
                        .isCloseTo(expectedQuantity, within(EPSILON));
            }
        }
        assertThat(rows.values().stream().reduce(BigDecimal.ZERO, BigDecimal::add))
                .isCloseTo(new BigDecimal(parentQty(issuedComponent, frozen, orderRate)), within(EPSILON));
    }

    static String productionSql() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        SubcontractComponentCustodyProjection.issuedByParent(em, ANALYSIS);
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        return sql.getValue();
    }

    static String fixtureSql(String orderRate, String frozen, String issueRate, String issuedComponent,
                             List<String> consumed) {
        return """
                WITH fixture AS (
                    SELECT '%s'::uuid AS analysis_id, md5('order')::uuid AS order_id,
                           md5('application')::uuid AS application_id, md5('action')::uuid AS action_id,
                           md5('plan')::uuid AS plan_id, md5('issue')::uuid AS issue_id,
                           %s::numeric AS order_rate, %s::numeric AS frozen,
                           %s::numeric AS issue_rate, %s::numeric AS issued_component
                ), parents AS (
                    SELECT n, ('10000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid AS material_id,
                           md5('item-'||n)::uuid AS item_id, md5('reservation-'||n)::uuid AS reservation_id,
                           CASE n WHEN 1 THEN %s::numeric WHEN 2 THEN %s::numeric ELSE %s::numeric END AS consumed
                    FROM generate_series(1,3) n
                ), preplan_supply_actions AS (
                    SELECT action_id AS id, analysis_id, 'SUBCONTRACT' AS route, 'SUPPLY' AS operation_type,
                           'CREATED' AS status, 'SUBCONTRACT_APPLICATION' AS external_document_type,
                           NULL::uuid AS public_surplus_external_item_id FROM fixture
                ), preplan_supply_action_allocations AS (
                    SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid AS id, action_id, analysis_id,
                           1::numeric AS allocated_qty, application_id AS external_item_id,
                           material_id AS analysis_material_id FROM fixture CROSS JOIN parents
                ), subcontract_order_item_sources AS (
                    SELECT order_id AS order_item_id, application_id AS application_item_id,
                           1::numeric AS alloc_qty FROM fixture
                ), subcontract_order_items AS (
                    SELECT order_id AS id, order_rate AS unit_rate, 1::numeric AS qty,
                           false AS is_deleted FROM fixture
                ), production_material_analysis_materials AS (
                    SELECT material_id AS id, analysis_id, item_id AS analysis_item_id,
                           'P-'||n AS node_key, true AS active FROM fixture CROSS JOIN parents
                ), subcontract_material_plan_items AS (
                    SELECT plan_id AS id, order_id AS order_item_id, 'COMPONENT_OUTBOUND' AS flow_mode,
                           false AS is_deleted, frozen AS bom_unit_qty FROM fixture
                ), subcontract_material_issue_items AS (
                    SELECT plan_id AS plan_item_id, issue_id, (issued_component/issue_rate)::numeric(18,4) AS qty,
                           issue_rate AS unit_rate, frozen AS frozen_unit_qty, false AS is_deleted FROM fixture
                ), subcontract_material_issues AS (
                    SELECT issue_id AS id, 1 AS status, false AS is_deleted FROM fixture
                ), subcontract_component_stock_handoffs AS (
                    SELECT plan_id AS plan_item_id, material_id AS parent_material_id,
                           reservation_id AS target_reservation_id FROM fixture CROSS JOIN parents
                ), stock_reservations AS (
                    SELECT reservation_id AS id, consumed AS consumed_qty, false AS is_deleted FROM parents
                )
                """.formatted(ANALYSIS, orderRate, frozen, issueRate, issuedComponent,
                consumed.get(0), consumed.get(1), consumed.get(2));
    }
}
