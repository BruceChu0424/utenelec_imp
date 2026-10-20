package com.uten.imp.migration;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Executes V856 against the actual V802/V837 function bodies on a small isolated schema. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopDirectPlanLifecycleReasonsPostgresTest {
    @Container private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID SOURCE_PLAN = id(1), TARGET_PLAN = id(2), SOURCE = id(3), TARGET = id(4);
    private static final UUID DEMAND = id(5), PACKAGE = id(6), GOODS = id(7), ANALYSIS_ITEM = id(8);
    private static JdbcTemplate jdbc;
    private static String reasonDefinition, targetDefinition, migration;

    @BeforeAll static void fixture() throws Exception {
        jdbc = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        jdbc.execute("CREATE UNLOGGED TABLE production_plans(id uuid PRIMARY KEY,bill_no text,status int,is_deleted boolean,is_stopped boolean,is_closed boolean,is_canceled boolean,delivery_date date,material_analysis_item_id uuid,material_analysis_id uuid)");
        jdbc.execute("CREATE UNLOGGED TABLE production_execution_segments(id uuid PRIMARY KEY,product_goods_id uuid,plan_id uuid,source_plan_item_id uuid,is_deleted boolean,status text,segment_code text,continuous_supply boolean,workshop_department_id uuid,package_id uuid)");
        jdbc.execute("CREATE UNLOGGED TABLE production_material_demands(id uuid PRIMARY KEY,status text,required_qty numeric,warehouse_id uuid,need_date date,goods_id uuid,execution_segment_id uuid)");
        jdbc.execute("CREATE UNLOGGED TABLE production_planning_packages(id uuid PRIMARY KEY,plan_id uuid,status text,is_deleted boolean,warehouse_id uuid)");
        jdbc.execute("CREATE UNLOGGED TABLE production_material_analysis_items(id uuid PRIMARY KEY,source_type text,analysis_id uuid,is_deleted boolean,line_priority int,delivery_date date)");
        jdbc.execute("CREATE UNLOGGED TABLE goods(id uuid PRIMARY KEY,code text,name text)");
        jdbc.execute("CREATE UNLOGGED TABLE departments(id uuid,name text)");
        jdbc.execute("CREATE UNLOGGED TABLE subplan_links(plan_id uuid,subplan_id uuid,is_deleted boolean)");
        jdbc.execute("CREATE UNLOGGED TABLE production_material_supply_pegs(supply_type text,supply_item_id uuid,status text)");
        // Structural/quantity proof is orthogonal to this two-branch reason patch.
        jdbc.execute("CREATE FUNCTION fn_workshop_direct_linked_demands(uuid) RETURNS TABLE(demand_id uuid,receiving_plan_canceled boolean) LANGUAGE sql STABLE AS $$ SELECT d.id,p.is_canceled FROM production_material_demands d JOIN production_execution_segments s ON s.id=d.execution_segment_id JOIN production_plans p ON p.id=s.plan_id $$");
        jdbc.execute("CREATE FUNCTION fn_workshop_direct_relation_code(uuid,uuid) RETURNS text LANGUAGE sql STABLE AS $$ SELECT NULL::text $$");
        jdbc.execute("CREATE FUNCTION fn_workshop_direct_covered_base_qty(uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$");
        jdbc.execute("CREATE FUNCTION fn_workshop_direct_remaining_for_source(uuid,uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 10::numeric $$");
        jdbc.execute(function("V736__workshop_direct_target_single_source.sql", "fn_workshop_direct_reason_rank"));
        reasonDefinition = function("V802__workshop_bin_opening_single_source.sql", "fn_workshop_direct_reason_text");
        targetDefinition = function("V837__workshop_direct_transfer_no_preopen.sql", "fn_workshop_direct_targets");
        migration = Files.readString(Path.of("src/main/resources/db/migration/V856__workshop_direct_plan_lifecycle_reasons.sql"));
        jdbc.update("INSERT INTO production_plans VALUES (?,'SJ-SOURCE',1,FALSE,FALSE,FALSE,FALSE,NULL,?,NULL),(?,'SJ-TARGET',1,FALSE,FALSE,FALSE,FALSE,NULL,NULL,NULL)", SOURCE_PLAN, ANALYSIS_ITEM, TARGET_PLAN);
        jdbc.update("INSERT INTO production_execution_segments VALUES (?,?,?,NULL,FALSE,'IN_PROGRESS','ZX00000363',FALSE,NULL,NULL),(?,?,?,NULL,FALSE,'WAITING','ZX00000365',FALSE,NULL,?)", SOURCE, GOODS, SOURCE_PLAN, TARGET, id(9), TARGET_PLAN, PACKAGE);
        jdbc.update("INSERT INTO production_material_demands VALUES (?,'OPEN',10,NULL,NULL,?,?)", DEMAND, GOODS, TARGET);
        jdbc.update("INSERT INTO production_planning_packages VALUES (?,?,'CONFIRMED',FALSE,NULL)", PACKAGE, TARGET_PLAN);
        jdbc.update("INSERT INTO production_material_analysis_items VALUES (?,'AGGREGATE_MAKE',NULL,FALSE,1,NULL)", ANALYSIS_ITEM);
        jdbc.update("INSERT INTO goods VALUES (?,'V5G001','组件')", GOODS);
    }

    @BeforeEach void restoreFunctions() {
        jdbc.execute(reasonDefinition);
        jdbc.execute(targetDefinition);
    }

    @Test void realFunctionsChangeOnlyTheTwoReasonsAndKeepEveryEligibilityQuantityAndRank() {
        String[] scenarios = {"CONFIRMED", "CANCELLED", "REVERSED", "DELETED", "MISSING", "PLAN_REVERSED", "DRAFT", "STOPPED", "CLOSED", "PLAN_CANCELLED", "EXCESS"};
        Map<String, Map<String, Object>> before = new LinkedHashMap<>();
        for (String scenario : scenarios) before.put(scenario, verdict(scenario));
        jdbc.execute(migration);
        for (String scenario : scenarios) {
            Map<String, Object> after = verdict(scenario);
            String text = (String) after.remove("reason_text");
            Map<String, Object> original = new LinkedHashMap<>(before.get(scenario));
            String oldText = (String) original.remove("reason_text");
            assertThat(after).as(scenario + " must preserve eligibility and quantities").isEqualTo(original);
            if (scenario.equals("PLAN_REVERSED")) assertThat(text).contains("已红冲").doesNotContain("未审核");
            else if (java.util.Set.of("CANCELLED", "REVERSED", "DELETED", "MISSING").contains(scenario))
                assertThat(text).contains("尚无有效执行安排，暂不能接收直送").doesNotContain("计划包已取消");
            else assertThat(text).isEqualTo(oldText);
        }
    }

    @ParameterizedTest @ValueSource(strings = {"reason", "target", "duplicate"})
    void missingOrDuplicateAnchorFailsAndRollsBackBothFunctionChanges(String drift) {
        if (drift.equals("reason")) jdbc.execute(reasonDefinition.replace("的计划包已取消，不再接收直送", "执行安排已撤销"));
        else if (drift.equals("target")) jdbc.execute(targetDefinition.replace("WHEN coded.is_stopped THEN '已暂停'", "WHEN coded.is_stopped THEN '暂停'"));
        else jdbc.execute(reasonDefinition.replace("    SELECT CASE p_code", "    -- WHEN 'PACKAGE_NOT_CONFIRMED' THEN format('%s的计划包已取消，不再接收直送', receiver)\n    SELECT CASE p_code"));
        String beforeReason = definition("fn_workshop_direct_reason_text(text,text,text,text,text,numeric,numeric)");
        String beforeTarget = definition("fn_workshop_direct_targets(uuid,uuid,numeric)");
        RuntimeException failure = assertThrows(RuntimeException.class, () -> jdbc.execute(migration));
        assertThat(failure.getMessage()).contains("V856 direct-transfer").contains("anchor changed");
        assertThat(definition("fn_workshop_direct_reason_text(text,text,text,text,text,numeric,numeric)")).isEqualTo(beforeReason);
        assertThat(definition("fn_workshop_direct_targets(uuid,uuid,numeric)")).isEqualTo(beforeTarget);
    }

    @ParameterizedTest @ValueSource(strings = {"PLAN_REVERSED_STOPPED", "PLAN_REVERSED_CLOSED"})
    void reversalReasonOverridesRetainedFlagsWithoutChangingEligibilityOrQuantity(String scenario) {
        Map<String, Object> before = verdict(scenario);
        jdbc.execute(migration);
        Map<String, Object> after = verdict(scenario);
        assertThat((String) after.remove("reason_text")).contains("已红冲").doesNotContain("已暂停", "已结案");
        before.remove("reason_text");
        assertThat(after).as("Terminal reason must leave every actual target predicate and quantity intact")
                .isEqualTo(before);
        assertThat(jdbc.queryForObject("""
                SELECT fn_workshop_direct_reason_text('PLAN_NOT_ACTIVE','目标工单','组件','装配','已红冲',1,0)
                """, String.class)).contains("已红冲");
    }

    private static Map<String, Object> verdict(String scenario) {
        jdbc.update("UPDATE production_plans SET status=?,is_stopped=?,is_closed=?,is_canceled=? WHERE id=?",
                scenario.startsWith("PLAN_REVERSED") ? -1 : scenario.equals("DRAFT") ? 0 : 1,
                scenario.equals("STOPPED") || scenario.equals("PLAN_REVERSED_STOPPED"),
                scenario.equals("CLOSED") || scenario.equals("PLAN_REVERSED_CLOSED"),
                scenario.equals("PLAN_CANCELLED"), TARGET_PLAN);
        jdbc.update("UPDATE production_execution_segments SET package_id=? WHERE id=?", scenario.equals("MISSING") ? id(999) : PACKAGE, TARGET);
        jdbc.update("UPDATE production_planning_packages SET status=?,is_deleted=? WHERE id=?",
                scenario.equals("CANCELLED") || scenario.equals("REVERSED") ? scenario : "CONFIRMED", scenario.equals("DELETED"), PACKAGE);
        return new LinkedHashMap<>(jdbc.queryForMap("SELECT * FROM fn_workshop_direct_targets(?,?,?)", SOURCE, DEMAND,
                new java.math.BigDecimal(scenario.equals("EXCESS") ? "11" : "1")));
    }

    private static String definition(String signature) {
        return jdbc.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))", String.class, signature);
    }

    private static String function(String file, String name) throws Exception {
        String sql = Files.readString(Path.of("src/main/resources/db/migration", file));
        int start = sql.indexOf("CREATE OR REPLACE FUNCTION " + name + "(");
        if (start < 0) start = sql.indexOf("CREATE FUNCTION " + name + "(");
        int end = sql.indexOf("$$;", start);
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        return sql.substring(start, end + 3);
    }

    private static UUID id(int number) {
        return UUID.fromString("20000000-0000-4000-8000-" + String.format(java.util.Locale.ROOT, "%012d", number));
    }
}
