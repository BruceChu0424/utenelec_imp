package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * <b>手写 fixture schema 与正式迁移目录的一致性守卫（2026-09-18 起）。</b>
 *
 * <p>背景：约 80 个 {@code *PostgresTest} 各自维护私有手写最小 DDL（不做迁移、
 * 只建被测查询碰到的表）。这是历史上最大的 CI 红源——每次迁移给既有表加列
 * （V584/V595/V599 一轮 7 类失败），fixture 不跟就红一轮 1.5 小时的 DB 全链。
 * 本守卫把「漂移发现」从 1.5 小时的测试运行提前到这一个测试类里：
 *
 * <ul>
 *   <li><b>列已不存在/类型族漂移</b>：fixture 定义的列在真实迁移后的 schema 里找不到
 *       （改名/删除/手误）或类型族对不上 → 直接红；</li>
 *   <li><b>缺列棘轮</b>：迁移给既有表加列而 fixture 没跟（本轮事故的原始形态）→
 *       与 {@code fixture-schema-guard/column-debt-baseline.txt} 对账，
 *       <b>新增</b>缺列当场红（连受影响的 fixture 文件一起报出），补齐的列要求从
 *       基线删掉（基线只缩不涨）；</li>
 *   <li><b>动态建表棘轮</b>：建表语句的表名来自 Java 变量拼接、静态无法解析时，
 *       记入 {@code fixture-schema-guard/dynamic-ddl-files.txt}，新文件出现即红，
 *       迫使 consciously 登记或改回固定表名。</li>
 * </ul>
 *
 * <p>根治方向是新测试不再手写 DDL：用 {@link com.uten.imp.support.MigratedSchemaBaseline}
 * 从真实 Flyway 迁移克隆基线，加列零维护。存量 fixture 在棘轮约束下渐进迁移。
 *
 * <p>基线再生成（只在本地跑，CI 不设这个变量）：
 * {@code UTEN_RUN_DB_TESTS=true UTEN_REGEN_FIXTURE_BASELINE=true mvn test -Dtest=FixtureSchemaDriftGuardPostgresTest}
 * 会重写两个基线文件后失败提醒审查提交。
 *
 * <p>已知边界：只对账建表语句（fixture 把真实视图建成 TABLE 桩也算——
 * information_schema.columns 对视图同样有列清单）；TEMP/UNLOGGED 表是
 * 测试内部暂存（故意用少列表影射真实表名），跳过；视图与函数桩不查。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FixtureSchemaDriftGuardPostgresTest {

    private static final Path TEST_SOURCES = resolve(
            Path.of("src", "test", "java"),
            Path.of("server", "src", "test", "java"));
    private static final Path BASELINE_DIR = resolve(
            Path.of("src", "test", "resources"),
            Path.of("server", "src", "test", "resources")).resolve("fixture-schema-guard");
    private static final Set<String> OWN_FILES = Set.of(
            "FixtureSchemaDriftGuardPostgresTest.java",
            "FixtureSchemaDdlTest.java",
            // Its CREATE TABLE strings are parser input samples only; this
            // read-only migration contract class never creates a database fixture.
            "AuditTriggerCoverageMigrationContractTest.java",
            "MigratedSchemaBaselinePostgresTest.java",
            // Creates complete projections from trusted live Flyway catalog
            // metadata rather than hand-written fixture DDL.
            "MigratedProjectionSchema.java");

    /**
     * 真实 schema 里不存在、且确属测试私有的关系（探针/影子表/投影桩）。
     * 新增条目必须写清理由——它意味着该 fixture 表永远不会被迁移目录约束。
     */
    private static final Set<String> FIXTURE_ONLY_RELATIONS = Set.of(
            // 演练/清库探针：断言继承与拦截行为用的临时关系名。
            "reset_probe_inherited",
            "reset_probe_child",
            // V625 verifies denied DDL and persistent-name shadow protection;
            // neither name is a business fixture or a production table.
            "runtime_ddl_should_fail",
            "reset_business_table_policy",
            // 事务完整性/状态锁探针（tx_test_* 影子表）。
            "tx_test_inventory",
            "tx_test_reservations",
            "tx_test_procurement_postings",
            // 估值作业进度桩（库存估值并发测试）。
            "applied_refresh",
            // outbox 唤醒投递记录桩。
            "outbox_wake_test_deliveries",
            // 委外准备分页的工作台文档投影桩。
            "workbench_documents",
            // Workbench query function outcomes are test-owned facts, never
            // invented columns on the production_execution_segments table.
            "workbench_execution_policy_facts",
            // 物料分析测试的影子事实/取证暂存表（聚合口径桩，不是业务表）。
            "entitlement_evidence",
            "entitlement_facts",
            "stock_facts",
            // 审计分类迁移测试的材料探针。
            "audit_v556_material_probe",
            // ADR-105 列级审计登记探针: 只验证「只在登记列变化时写审计」, 不是业务表。
            "audit_scope_probe",
            // ADR-105 起迁移目录里已没有分区的清空表; 清库稀疏测试故意建一张三列的按年分区表,
            // 改名顶替 production_plan_costs, 钉住重置函数处理分区叶子(换文件节点/序列/外键)的合同。
            "reset_probe_partitioned_costs",
            // 金额精确度迁移助手的三张数字夹具表。
            "financial_exact_fixture",
            "financial_book_fixture",
            "financial_unsupported_fixture",
            // 货品删除守卫的外键引用方桩（迁移目录里没有图片引用表）。
            "goods_image_references",
            // ADR-107 行版本语义探针(ProductionFootprintRowVersionPostgresTest)与
            // BaseEntity 新建判定探针实体(BaseEntityPersistablePostgresTest), 都不是业务表。
            "version_probe",
            "persistable_probe",
            // SchemaIndexHygieneContractTest 在回滚事务里自检索引规则用的样本表(ADR-106)。
            "index_rule_probe",
            // ADR-113(V646) 子件精确权益批次测试: 权益批次余额视图 v_preplan_stock_entitlement_lot_balance
            // 的底表桩(SubcontractComponentEntitledLotsPostgresTest), 不是业务表。
            "fixture_entitlement_lots",
            // BusinessIdentifierRegistryMigrationContractTest 里对迁移 SQL 做
            // contains 断言时，字面量拼接出的伪表名（不是真的建表语句）。
            "upper");

    /**
     * 影子表上测试自有的记账列（表是真实表、列是测试自己的）——被测 SQL
     * 本身就用这些列名，真实迁移目录里没有、也不该有。
     */
    private static final Set<String> FIXTURE_ONLY_COLUMNS = Set.of(
            // FulfillmentMutationLocksPostgresTest 的乐观锁影子列（真实列名是 lock_version）。
            "sales_orders.revision",
            "sales_shipments.revision",
            // SalesOrderChainSqlPostgresTest 共享影子表的用例编号列。
            "sales_order_items.case_no",
            // MaterialAnalysisArrayMembershipPostgresTest 的合格来源桩布尔
            // （真实列名是 requires_qualified_origin，V535）。
            "stock_reservations.qualified");

    @Test
    void handWrittenFixtureSchemasStayReconciledWithTheRealMigrationDirectory() throws Exception {
        Map<String, Map<String, String>> realColumns = migrateAndReadRealColumns();
        FixtureSchemaDdl.Scan scan = FixtureSchemaDdl.scan(TEST_SOURCES, OWN_FILES);
        List<String> violations = new ArrayList<>(scan.parseFailures());
        // 缺列债务按「文件#表.列」记账而不是按表并集：并集会让「某文件补齐过、
        // 别的文件仍缺」的列永远留在基线里，单文件回退就看不见；按文件记，
        // 任何一个文件缺列或回退都是独立条目，棘轮严密。
        Set<String> debt = new TreeSet<>();

        for (FixtureSchemaDdl.FixtureTable fixtureTable : scan.tables()) {
            reconcileTable(fixtureTable, violations, debt, realColumns);
        }

        if (System.getenv().getOrDefault("UTEN_REGEN_FIXTURE_BASELINE", "").matches("(?i)true")) {
            regenerateBaselines(debt, scan.dynamicDdlFiles());
            violations.add("UTEN_REGEN_FIXTURE_BASELINE=true：基线已重写，git diff 审查后提交，"
                    + "本轮按失败处理防止静默放宽。");
        } else {
            reconcileDebtAgainstBaseline(debt, violations);
            reconcileAgainstBaseline(scan.dynamicDdlFiles(), "dynamic-ddl-files.txt", violations,
                    """
                            下列文件出现静态无法解析的动态建表（表名拼接）——\
                            这是新的手写 DDL，请改用 MigratedSchemaBaseline 或固定表名；\
                            确需动态请登记基线：""",
                    "下列文件已无动态建表，从基线删掉：");
        }
        assertThat(violations)
                .as("""
                        fixture schema 与 db/migration 漂移（详见各项说明）。\
                        基线再生成（仅本地）：UTEN_RUN_DB_TESTS=true \
                        UTEN_REGEN_FIXTURE_BASELINE=true mvn test \
                        -Dtest=FixtureSchemaDriftGuardPostgresTest""")
                .isEmpty();
    }

    // ------------------------------------------------------------------
    // 真实 schema：跑完整迁移目录，读关系（表+视图）列清单
    // ------------------------------------------------------------------

    private static Map<String, Map<String, String>> migrateAndReadRealColumns() throws Exception {
        try (PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            Flyway.configure()
                    .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("classpath:db/migration")
                    .load()
                    .migrate();
            try (Connection connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                assertThat(MigrationRehearsalSupport.latestSuccessfulVersion(connection))
                        .isEqualTo(MigrationRehearsalSupport.CURRENT_HEAD_VERSION);
                assertThat(MigrationRehearsalSupport.successfulMigrationCount(connection))
                        .isEqualTo(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT);
                return realColumnFamilies(connection);
            }
        }
    }

    private static Map<String, Map<String, String>> realColumnFamilies(Connection connection)
            throws SQLException {
        String columnSql = "SELECT table_name, column_name, udt_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name <> 'flyway_schema_history'";
        Map<String, Map<String, String>> columns = new TreeMap<>();
        try (PreparedStatement columnsQuery = connection.prepareStatement(columnSql);
             ResultSet rows = columnsQuery.executeQuery()) {
            while (rows.next()) {
                columns.computeIfAbsent(rows.getString(1), ignored -> new LinkedHashMap<>())
                        .put(rows.getString(2), FixtureSchemaDdl.realFamily(rows.getString(3)));
            }
        }
        return columns;
    }

    // ------------------------------------------------------------------
    // 对账
    // ------------------------------------------------------------------

    private static void reconcileTable(
            FixtureSchemaDdl.FixtureTable fixtureTable,
            List<String> violations,
            Set<String> debt,
            Map<String, Map<String, String>> realColumns) {
        String table = fixtureTable.table().toLowerCase();
        Map<String, String> realForTable = realColumns.get(table);
        if (realForTable == null) {
            if (!FIXTURE_ONLY_RELATIONS.contains(table)) {
                violations.add("""
                        %s: 建表 %s 在真实迁移 schema（含视图）里不存在——表被改名/删除\
                        ，或纯测试关系未登记 FIXTURE_ONLY_RELATIONS。"""
                        .formatted(fixtureTable.file(), fixtureTable.table()));
            }
            return;
        }
        for (Map.Entry<String, String> column : fixtureTable.columns().entrySet()) {
            String realColumnFamily = realForTable.get(column.getKey());
            if (realColumnFamily == null) {
                if (!FIXTURE_ONLY_COLUMNS.contains("%s.%s".formatted(table, column.getKey()))) {
                    violations.add("""
                            %s: 表 %s 的列 %s 在真实 schema 里不存在（改名/删除/手误？）。\
                            fixture 与迁移目录必须同名同义；测试自有记账列须登记 \
                            FIXTURE_ONLY_COLUMNS 并写明理由。"""
                            .formatted(fixtureTable.file(), fixtureTable.table(), column.getKey()));
                }
            } else if (!column.getValue().equals(realColumnFamily)) {
                violations.add("%s: 表 %s.%s 类型族漂移：fixture=%s，真实=%s。"
                        .formatted(fixtureTable.file(), fixtureTable.table(),
                                column.getKey(), column.getValue(), realColumnFamily));
            }
        }
        for (String realColumn : realForTable.keySet()) {
            if (!fixtureTable.columns().containsKey(realColumn)) {
                debt.add("%s#%s.%s".formatted(fixtureTable.file(), table, realColumn));
            }
        }
    }

    // ------------------------------------------------------------------
    // 基线棘轮
    // ------------------------------------------------------------------

    private static void reconcileDebtAgainstBaseline(
            Set<String> debt, List<String> violations) throws IOException {
        Set<String> baseline = loadBaseline("column-debt-baseline.txt");
        Set<String> grown = new TreeSet<>(debt);
        grown.removeAll(baseline);
        Set<String> shrunk = new TreeSet<>(baseline);
        shrunk.removeAll(debt);
        if (!grown.isEmpty()) {
            List<String> lines = new ArrayList<>();
            lines.add("""
                    下列文件缺列（迁移给既有表加了列而 fixture 没跟，或已补齐的列回退了）\
                    ——V584/V595/V599 类 CI 红的原始形态。给对应 fixture 补列、转用 \
                    MigratedSchemaBaseline、或说明理由后重新生成基线：""");
            grown.forEach(entry -> lines.add("  %s".formatted(entry)));
            violations.add(String.join("\n", lines));
        }
        if (!shrunk.isEmpty()) {
            List<String> lines = new ArrayList<>();
            lines.add("下列文件已补列/文件已删除，把对应基线条目删掉（基线只缩不涨）：");
            shrunk.forEach(entry -> lines.add("  %s".formatted(entry)));
            violations.add(String.join("\n", lines));
        }
    }

    private static void reconcileAgainstBaseline(
            Set<String> current, String baselineFile, List<String> violations,
            String growHeader, String shrinkHeader) throws IOException {
        Set<String> baseline = loadBaseline(baselineFile);
        Set<String> grown = new TreeSet<>(current);
        grown.removeAll(baseline);
        Set<String> shrunk = new TreeSet<>(baseline);
        shrunk.removeAll(current);
        if (!grown.isEmpty()) {
            violations.add(joinMessage(growHeader, grown));
        }
        if (!shrunk.isEmpty()) {
            violations.add(joinMessage(shrinkHeader, shrunk));
        }
    }

    private static String joinMessage(String header, Set<String> entries) {
        List<String> lines = new ArrayList<>();
        lines.add(header);
        entries.forEach(entry -> lines.add("  %s".formatted(entry)));
        return String.join("\n", lines);
    }

    private static Set<String> loadBaseline(String file) throws IOException {
        Path path = BASELINE_DIR.resolve(file);
        if (!Files.exists(path)) {
            return Set.of();
        }
        try (Stream<String> lines = Files.lines(path, StandardCharsets.UTF_8)) {
            return lines.map(String::trim)
                    .filter(line -> !line.isEmpty() && !line.startsWith("#"))
                    .collect(Collectors.toCollection(TreeSet::new));
        }
    }

    private static void regenerateBaselines(Set<String> debt, Set<String> dynamicDdlFiles)
            throws IOException {
        Files.createDirectories(BASELINE_DIR);
        Files.writeString(BASELINE_DIR.resolve("column-debt-baseline.txt"),
                baselineContent(
                        "手写 fixture 相对真实迁移 schema 的已知缺列债务（文件#表.列）。",
                        "只缩不涨：迁移加列后 fixture 未跟、或已补齐的列回退，都会在这里之外新增条目并让守卫红。",
                        debt),
                StandardCharsets.UTF_8);
        Files.writeString(BASELINE_DIR.resolve("dynamic-ddl-files.txt"),
                baselineContent(
                        "含静态不可解析动态建表（表名拼接）的测试文件（相对 src/test/java）。",
                        "新文件出现即红；改用 MigratedSchemaBaseline 或固定表名后从本表删除。",
                        dynamicDdlFiles),
                StandardCharsets.UTF_8);
    }

    private static String baselineContent(String what, String policy, Set<String> entries) {
        String header = "# %s\n# %s\n# 重新生成：UTEN_RUN_DB_TESTS=true UTEN_REGEN_FIXTURE_BASELINE=true\n"
                .formatted(what, policy);
        if (entries.isEmpty()) {
            return header;
        }
        List<String> lines = new ArrayList<>();
        lines.add(header.stripTrailing());
        entries.forEach(entry -> lines.add(entry));
        return String.join("\n", lines).concat("\n");
    }

    private static Path resolve(Path direct, Path fallback) {
        Path existing = Files.exists(direct) ? direct : fallback;
        return existing.toAbsolutePath().normalize();
    }
}
