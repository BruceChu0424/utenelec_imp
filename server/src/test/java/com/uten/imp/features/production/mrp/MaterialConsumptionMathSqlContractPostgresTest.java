package com.uten.imp.features.production.mrp;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.MaterialConsumptionMath;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-129 §2.3：BOM 计量只有一份 Java 公式 {@link MaterialConsumptionMath#required}，SQL 里有两个孪生：
 * V247 的 {@code fn_material_analysis_edge_required} 算一条 BOM 边(MRP、计划导入需求小计)；
 * V609 的 {@code fn_material_snapshot_required} 按需求冻结的 consumption_snapshot 逐规则求和
 * (需求写入守卫、拆批/追加/预留断言)，Java 侧同一条曲线由 {@link CompleteKitAllocator#required}
 * 逐规则委托共享公式后求和。这里把两个函数的迁移原文装进真实 PostgreSQL，逐例比对。
 * 冻结曲线的 JSON 与下达时写入的同形(规则记录 + productUnitRate，同一个 ObjectMapper 序列化)。
 */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialConsumptionMathSqlContractPostgresTest {

    @Container
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");

    private static final ObjectMapper JSON = new ObjectMapper();

    private static JdbcTemplate jdbc;

    private record Case(String parentOutputQty, String bomQty, String basis,
                        String basisOutputQty, boolean allowPartialPackage) {

        CompleteKitAllocator.ConsumptionRule rule() {
            return new CompleteKitAllocator.ConsumptionRule(
                    basis, new BigDecimal(bomQty), new BigDecimal(basisOutputQty),
                    allowPartialPackage);
        }
    }

    private static final List<Case> CASES = List.of(
            new Case("0", "2", "PER_UNIT", "1", true),
            new Case("7", "0.333333", "PER_UNIT", "1", true),
            new Case("1000", "0.0005", "PER_UNIT", "1", false),
            new Case("12.5", "0.000001", "PER_UNIT", "1", true),
            new Case("3", "1", "PER_PACKAGE", "6", true),
            new Case("10", "1", "PER_PACKAGE", "3", true),
            new Case("10", "0.333334", "PER_PACKAGE", "7", true),
            new Case("10", "2", "PER_PACKAGE", "6", false),
            new Case("6", "2", "PER_PACKAGE", "6", false),
            new Case("0.0001", "2", "PER_PACKAGE", "6", false),
            new Case("101", "0.25", "FIXED_BATCH", "100", true),
            new Case("100", "0.25", "FIXED_BATCH", "100", false),
            new Case("250.75", "3.141593", "FIXED_BATCH", "2.5", true),
            new Case("123456.7891", "0.012345", "PER_PACKAGE", "0.123457", true));

    @BeforeAll
    static void installFunctions() throws Exception {
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        install("V247__bom_control_stage_and_packaging_measurement.sql",
                "CREATE OR REPLACE FUNCTION fn_material_analysis_edge_required(");
        install("V609__execution_material_capacity_snapshot.sql",
                "CREATE FUNCTION fn_material_snapshot_required(");
    }

    private static void install(String migrationFile, String header) throws Exception {
        String migration = Files.readString(
                Path.of("src/main/resources/db/migration", migrationFile));
        int start = migration.indexOf(header);
        int end = migration.indexOf("\n$$;", start) + 4;
        assertThat(start).as(header).isNotNegative();
        assertThat(end).as(header).isGreaterThan(start);
        jdbc.execute(migration.substring(start, end));
    }

    @Test
    void sqlEdgeFunctionEqualsTheSharedJavaFormula() {
        for (Case value : CASES) {
            BigDecimal sql = jdbc.queryForObject(
                    "SELECT fn_material_analysis_edge_required(CAST(? AS numeric),"
                            + "CAST(? AS numeric),?,CAST(? AS numeric),?)",
                    BigDecimal.class,
                    value.parentOutputQty(), value.bomQty(), value.basis(),
                    value.basisOutputQty(), value.allowPartialPackage());
            BigDecimal java = MaterialConsumptionMath.required(
                    new BigDecimal(value.parentOutputQty()),
                    new BigDecimal(value.bomQty()),
                    value.basis(),
                    new BigDecimal(value.basisOutputQty()),
                    value.allowPartialPackage());
            assertThat(sql).as(value.toString()).isEqualByComparingTo(java);
        }
    }

    @Test
    void sqlFrozenCurveFunctionEqualsTheSharedJavaFormulaRuleByRule() throws Exception {
        for (Case value : CASES) {
            BigDecimal output = new BigDecimal(value.parentOutputQty());
            List<CompleteKitAllocator.ConsumptionRule> rules = List.of(value.rule());
            BigDecimal java = CompleteKitAllocator.required(rules, output, BigDecimal.ONE);
            assertThat(java).as(value.toString()).isEqualByComparingTo(
                    MaterialConsumptionMath.required(output, new BigDecimal(value.bomQty()),
                            value.basis(), new BigDecimal(value.basisOutputQty()),
                            value.allowPartialPackage()));
            assertThat(snapshotRequired(rules, BigDecimal.ONE, output))
                    .as(value.toString()).isEqualByComparingTo(java);
        }
    }

    @Test
    void sqlFrozenCurveFunctionEqualsJavaForMultipleRulesAndAUnitRate() throws Exception {
        // 一种物料的多条 BOM 行合成一条曲线，产品单位按打(1 打 = 12 件)：每条规则在
        // 父件产出(数量 × 换算率)上各自向上取 4 位，再求和。
        List<CompleteKitAllocator.ConsumptionRule> rules =
                CASES.stream().map(Case::rule).toList();
        for (String qty : List.of("0", "0.0001", "1", "8.3333", "250.5")) {
            BigDecimal productQty = new BigDecimal(qty);
            BigDecimal rate = new BigDecimal("12");
            assertThat(snapshotRequired(rules, rate, productQty))
                    .as("qty=" + qty)
                    .isEqualByComparingTo(CompleteKitAllocator.required(rules, productQty, rate));
        }
    }

    private static BigDecimal snapshotRequired(
            List<CompleteKitAllocator.ConsumptionRule> rules,
            BigDecimal productUnitRate,
            BigDecimal productQty) throws Exception {
        String snapshot = JSON.writeValueAsString(
                Map.of("rules", rules, "productUnitRate", productUnitRate));
        return jdbc.queryForObject(
                "SELECT fn_material_snapshot_required(CAST(? AS jsonb), CAST(? AS numeric))",
                BigDecimal.class, snapshot, productQty.toPlainString());
    }
}
