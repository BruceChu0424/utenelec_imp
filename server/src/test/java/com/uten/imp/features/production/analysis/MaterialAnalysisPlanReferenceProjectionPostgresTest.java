package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicInteger;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PlanReference;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Runs the actual read query on a small schema, without the full migration fixture. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisPlanReferenceProjectionPostgresTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ANALYSIS = id(100), ROOT = id(101), SHARED = id(102), OTHER = id(103);
    private static DriverManagerDataSource dataSource;
    private static final AtomicInteger fixtureIds = new AtomicInteger(1000);

    @BeforeAll static void fixture() {
        dataSource = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        var jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("CREATE UNLOGGED TABLE production_plans(id uuid PRIMARY KEY,bill_no text,status int,is_deleted boolean,is_canceled boolean,department_id uuid,worker_id uuid,workshop_name text)");
        jdbc.execute("CREATE UNLOGGED TABLE production_material_analysis_plan_links(analysis_id uuid,analysis_item_id uuid,plan_id uuid,created_at timestamptz,allocation_status text)");
        jdbc.execute("CREATE UNLOGGED TABLE production_plan_items(id uuid PRIMARY KEY,plan_id uuid,is_deleted boolean,qty numeric,iqty numeric)");
        jdbc.execute("CREATE UNLOGGED TABLE production_execution_segments(id uuid,source_plan_item_id uuid,is_deleted boolean,status text,material_requirement_mode text,workshop_department_id uuid,responsible_employee_id uuid,plan_id uuid,package_id uuid)");
        jdbc.execute("CREATE UNLOGGED TABLE production_planning_packages(id uuid PRIMARY KEY,plan_id uuid,status text,is_deleted boolean)");
        jdbc.execute("CREATE UNLOGGED TABLE preplan_make_public_claims(id uuid PRIMARY KEY,target_analysis_id uuid,target_material_id uuid,source_plan_item_id uuid,qty numeric,cancelled_qty numeric,pending_qty numeric)");
        jdbc.execute("CREATE FUNCTION fn_preplan_make_public_claim_pending_qty(uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT pending_qty FROM preplan_make_public_claims WHERE id=$1 $$");
        jdbc.execute("CREATE FUNCTION fn_preplan_make_public_claim_cancelled_qty(uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT cancelled_qty FROM preplan_make_public_claims WHERE id=$1 $$");
        jdbc.execute("CREATE UNLOGGED TABLE departments(id uuid,name text)");
        jdbc.execute("CREATE UNLOGGED TABLE employees(id uuid,full_name text)");
        jdbc.execute("CREATE UNLOGGED TABLE production_daily_reports(id uuid,is_deleted boolean,status int)");
        jdbc.execute("CREATE UNLOGGED TABLE production_daily_report_items(execution_segment_id uuid,report_id uuid,is_deleted boolean,qty numeric)");
        for (int i = 1; i <= 9; i++) {
            jdbc.update("INSERT INTO production_plans VALUES (?,?,?, ?,?,NULL,NULL,NULL)",
                    id(i), i == 3 ? "PP-003 \"装配\"" : "PP-00" + i, i == 6 ? 2 : i == 2 ? 0 : 1, i == 4, i == 5);
            jdbc.update("INSERT INTO production_plan_items VALUES (?,?,FALSE,10,0)", id(200 + i), id(i));
            jdbc.update("INSERT INTO production_material_analysis_plan_links VALUES (?,?,?,CAST(? AS timestamptz),?)",
                    i == 8 ? OTHER : ANALYSIS, i == 7 ? SHARED : ROOT, id(i),
                    i == 1 ? "2026-10-01T00:00:00Z" : "2026-10-02T00:00:00Z", i == 9 ? "CANCELLED" : i == 2 ? "SUBMITTED" : "APPROVED");
        }
        // Multiple allocation links for one plan must not duplicate its display reference or quantities.
        jdbc.update("INSERT INTO production_material_analysis_plan_links VALUES (?,?,?,CAST(? AS timestamptz),'SUBMITTED')",
                ANALYSIS, ROOT, id(3), "2026-10-02T00:00:00Z");
        jdbc.update("INSERT INTO production_material_analysis_plan_links VALUES (?,?,?,CAST(? AS timestamptz),'SUBMITTED')",
                ANALYSIS, SHARED, id(7), "2026-10-02T00:00:00Z");
    }

    @Test void returnsEveryEffectivePlanOnceInStableNewestFirstOrderWithOneAnalysisQuery() {
        var states = readStates(ANALYSIS);
        assertThat(states).containsOnlyKeys(ROOT, SHARED);
        assertThat(states.get(ROOT).planReferences()).containsExactly(
                new PlanReference(id(3), "PP-003 \"装配\"", 1), new PlanReference(id(2), "PP-002", 0), new PlanReference(id(1), "PP-001", 1));
        assertThat(states.get(ROOT).planId()).isEqualTo(id(3));
        assertThat(states.get(ROOT).plannedQty()).isEqualByComparingTo(new BigDecimal("20"));
        assertThat(states.get(SHARED).planReferences()).containsExactly(new PlanReference(id(7), "PP-007", 1));
        assertThat(states.get(SHARED).plannedQty()).isEqualByComparingTo(new BigDecimal("10"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"CANCELLED", "REVERSED", "MISSING", "DELETED"})
    void retainedPlanAndPublicClaimWaitForRearrangementUntilARealConfirmedPackageReturns(String mode) {
        Scenario fixture = retainedPlan(mode);
        var before = readStates(fixture.analysis()).get(fixture.source());
        assertThat(before.status()).isEqualTo("PLANNING_REQUIRED");
        assertThat(before.plannedQty()).isEqualByComparingTo("1000");
        assertThat(before.planReferences()).containsExactly(new PlanReference(fixture.plan(), "SJ-RETAINED", 1));
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_PLANNING_REQUIRED");

        var jdbc = new JdbcTemplate(dataSource);
        UUID newPackage = nextId(), newSegment = nextId();
        jdbc.update("INSERT INTO production_planning_packages VALUES (?,?,'CONFIRMED',FALSE)", newPackage, fixture.plan());
        jdbc.update("INSERT INTO production_execution_segments VALUES (?,?,FALSE,'WAITING','BOM',NULL,NULL,?,?)",
                newSegment, fixture.item(), fixture.plan(), newPackage);
        var confirmed = readStates(fixture.analysis()).get(fixture.source());
        assertThat(confirmed.status()).isEqualTo("WAITING");
        assertThat(confirmed.plannedQty()).isEqualByComparingTo("1000");
        assertThat(confirmed.planReferences()).isEqualTo(before.planReferences());
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_WAITING_MATERIAL");
        jdbc.update("UPDATE production_execution_segments SET status='READY' WHERE id=?", newSegment);
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_WAITING_DRAW");
        jdbc.update("UPDATE production_execution_segments SET status='IN_PROGRESS' WHERE id=?", newSegment);
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_IN_PROGRESS");
        jdbc.update("UPDATE production_execution_segments SET status='COMPLETED' WHERE id=?", newSegment);
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_WAIT_STOCK_IN");
        jdbc.update("UPDATE preplan_make_public_claims SET pending_qty=0 WHERE id=?", fixture.claim());
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_COMPLETED");
    }

    @Test void runningPlanDoesNotHideAnotherRetainedPlanWithNoExecutionArrangement() {
        Scenario fixture = retainedPlan("CANCELLED");
        var jdbc = new JdbcTemplate(dataSource);
        UUID plan = nextId(), item = nextId(), pack = nextId();
        jdbc.update("INSERT INTO production_plans VALUES (?,'SJ-RUNNING',1,FALSE,FALSE,NULL,NULL,NULL)", plan);
        jdbc.update("INSERT INTO production_plan_items VALUES (?,?,FALSE,500,0)", item, plan);
        jdbc.update("INSERT INTO production_material_analysis_plan_links VALUES (?,?,?,now(),'APPROVED')", fixture.analysis(), fixture.source(), plan);
        jdbc.update("INSERT INTO production_planning_packages VALUES (?,?,'CONFIRMED',FALSE)", pack, plan);
        jdbc.update("INSERT INTO production_execution_segments VALUES (?,?,FALSE,'IN_PROGRESS','BOM',NULL,NULL,?,?)", nextId(), item, plan, pack);
        jdbc.update("INSERT INTO preplan_make_public_claims VALUES (?,?,?,?,25,0,25)", nextId(), fixture.targetAnalysis(), fixture.target(), item);
        var state = readStates(fixture.analysis()).get(fixture.source());
        assertThat(state.status()).isEqualTo("PLANNING_REQUIRED");
        assertThat(state.plannedQty()).isEqualByComparingTo("1500");
        assertThat(state.planReferences()).hasSize(2);
        assertThat(readClaims(fixture.targetAnalysis())).containsEntry(fixture.target(), "MAKE_PLANNING_REQUIRED");
    }

    private static Scenario retainedPlan(String mode) {
        var jdbc = new JdbcTemplate(dataSource);
        UUID analysis = nextId(), source = nextId(), plan = nextId(), item = nextId(), pack = nextId();
        UUID targetAnalysis = nextId(), target = nextId(), claim = nextId();
        jdbc.update("INSERT INTO production_plans VALUES (?,'SJ-RETAINED',1,FALSE,FALSE,NULL,NULL,NULL)", plan);
        jdbc.update("INSERT INTO production_plan_items VALUES (?,?,FALSE,1000,0)", item, plan);
        jdbc.update("INSERT INTO production_material_analysis_plan_links VALUES (?,?,?,now(),'APPROVED')", analysis, source, plan);
        if (!mode.equals("MISSING")) jdbc.update("INSERT INTO production_planning_packages VALUES (?,?,?,?)",
                pack, plan, mode.equals("DELETED") ? "CONFIRMED" : mode, mode.equals("DELETED"));
        jdbc.update("INSERT INTO production_execution_segments VALUES (?,?,FALSE,?,'BOM',NULL,NULL,?,?)",
                nextId(), item, mode.equals("CANCELLED") || mode.equals("REVERSED") ? mode : "WAITING", plan, pack);
        jdbc.update("INSERT INTO preplan_make_public_claims VALUES (?,?,?,?,50,0,50)", claim, targetAnalysis, target, item);
        return new Scenario(analysis, source, plan, item, targetAnalysis, target, claim);
    }

    private static Map<UUID, MaterialAnalysisService.ProductPlanState> readStates(UUID analysis) {
        return read(em -> ReflectionTestUtils.invokeMethod(
                new MaterialAnalysisService(em, null, null, null, null, null, null, null, null, null),
                "productPlanStates", analysis), analysis);
    }

    private static Map<UUID, String> readClaims(UUID analysis) {
        return read(em -> PreplanMakePublicSupplyService.claimedStages(em, analysis), analysis);
    }

    private static <T> T read(java.util.function.Function<EntityManager, T> reader, UUID analysis) {
        var namedJdbc = new NamedParameterJdbcTemplate(dataSource);
        Map<String, Object> parameters = new HashMap<>();
        AtomicReference<String> sql = new AtomicReference<>();
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenAnswer(call -> {
            parameters.put(call.getArgument(0), call.getArgument(1));
            return query;
        });
        when(query.getResultList()).thenAnswer(ignored -> namedJdbc.query(sql.get(), parameters, (row, index) -> {
            Object[] values = new Object[row.getMetaData().getColumnCount()];
            for (int column = 0; column < values.length; column++) values[column] = row.getObject(column + 1);
            return values;
        }));
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            sql.set(call.getArgument(0));
            return query;
        });
        T result = reader.apply(em);
        verify(em, times(1)).createNativeQuery(anyString());
        verify(query, times(1)).setParameter(anyString(), eq(analysis));
        return result;
    }

    private record Scenario(UUID analysis, UUID source, UUID plan, UUID item, UUID targetAnalysis, UUID target, UUID claim) { }

    private static UUID nextId() { return id(fixtureIds.incrementAndGet()); }

    private static UUID id(int number) {
        return UUID.fromString("10000000-0000-4000-8000-" + String.format(java.util.Locale.ROOT, "%012d", number));
    }
}
