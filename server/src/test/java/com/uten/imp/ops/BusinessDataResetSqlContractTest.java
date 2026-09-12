package com.uten.imp.ops;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 工作台「系统测试 · 清空业务数据」三处事实的同步锁：
 * <ol>
 *   <li>ops/reset_business_data.sql（psql 停机版）的全量 CLEAR/PRESERVE 分类；</li>
 *   <li>迁移函数 business_data_reset()（应用内运行的孪生；V464 为最新整函数重发版，
 *       V462 为历史首版）的同一份分类。V474 起经运行时补丁插入
 *       {@link #RUNTIME_RESET_EXTENSIONS} 登记的扩展行（已应用的 V464 字节不可改）；</li>
 *   <li>BusinessDataResetService 只做编排（绑定 actor + 调函数），不内联清空 SQL。</li>
 * </ol>
 * 迁移新增表后必须同步两份清单，否则本测试失败关闭；运行时未知表同样拒绝执行。
 */
class BusinessDataResetSqlContractTest {

    private static final Pattern POLICY_ROW = Pattern.compile(
            "\\('([a-z][a-z0-9_]*)'\\s*,\\s*'(CLEAR|PRESERVE)'\\)");

    /**
     * V474 起经「读取已安装函数定义 + 失败关闭锚点替换」插入孪生函数的扩展行。
     * 表名 -> 引入迁移版本号；新增扩展时同步登记，并保持 ops 脚本与补丁锚点一致。
     */
    private static final Map<String, Integer> RUNTIME_RESET_EXTENSIONS = Map.ofEntries(
            Map.entry("preplan_public_supply_events", 474),
            Map.entry("preplan_root_output_events", 478),
            Map.entry("sales_order_qty_change_logs", 484),
            Map.entry("procurement_order_qty_change_logs", 486),
            Map.entry("sales_order_revision_logs", 492),
            Map.entry("preplan_subcontract_make_batch_reversals", 496),
            Map.entry("stock_value_pools", 504),
            Map.entry("stock_value_events", 504),
            Map.entry("stock_value_nodes", 504),
            Map.entry("stock_value_edges", 504),
            Map.entry("stock_value_jobs", 504),
            Map.entry("stock_value_tasks", 504),
            Map.entry("stock_value_node_revisions", 504),
            Map.entry("stock_value_postings", 504),
            Map.entry("procurement_order_source_revisions", 504),
            Map.entry("procurement_order_source_revision_allocations", 504),
            Map.entry("procurement_order_source_revision_peg_changes", 504),
            Map.entry("stock_value_openings", 506),
            Map.entry("stock_value_legacy_balance_cases", 506),
            Map.entry("stock_value_legacy_balance_case_events", 506),
            Map.entry("sales_shipment_submission_events", 519),
            Map.entry("production_material_movement_links", 514),
            Map.entry("stock_value_acquisition_sources", 517),
            Map.entry("stock_value_position_transfers", 517),
            Map.entry("stock_value_production_cost_dirty", 517),
            Map.entry("stock_value_production_cost_inputs", 517),
            Map.entry("stock_value_production_cost_objects", 517),
            Map.entry("stock_value_production_cost_outputs", 517),
            Map.entry("stock_value_production_cost_revisions", 517),
            Map.entry("stock_value_production_cost_shares", 517),
            Map.entry("stock_value_production_cost_tasks", 517),
            Map.entry("procurement_iqc_consideration_reversals", 518),
            Map.entry("procurement_iqc_consideration_review_approvals", 518),
            Map.entry("procurement_iqc_credit_case_allocations", 518),
            Map.entry("procurement_iqc_credit_documents", 518),
            Map.entry("procurement_iqc_credit_slices", 518),
            Map.entry("procurement_iqc_funding_settlements", 518),
            Map.entry("procurement_iqc_funding_slices", 518),
            Map.entry("procurement_iqc_quality_consideration_parts", 518),
            Map.entry("procurement_iqc_stock_consideration_parts", 518),
            Map.entry("procurement_receipt_consideration_parts", 518),
            Map.entry("subcontract_receipt_material_consumptions", 522),
            Map.entry("production_fqc_inspection_sheets", 547),
            Map.entry("production_fqc_inspection_sheet_items", 547),
            Map.entry("production_finished_arrival_registration_reversals", 548));

    private String opsScript;
    private String migrationSql;
    private String serviceSource;
    private String extensionSql;

    @BeforeEach
    void loadSources() throws IOException {
        opsScript = read(Path.of("ops", "reset_business_data.sql"),
                Path.of("server", "ops", "reset_business_data.sql"));
        migrationSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"));
        extensionSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V474__preplan_public_supply_and_inbound_allocation.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V474__preplan_public_supply_and_inbound_allocation.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V478__analysis_root_supply_fulfillment.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V478__analysis_root_supply_fulfillment.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V484__sales_qty_change_reset_extension.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V484__sales_qty_change_reset_extension.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V486__procurement_qty_change_and_preparation_retirement.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V486__procurement_qty_change_and_preparation_retirement.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V492__sales_order_commercial_revisions.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V492__sales_order_commercial_revisions.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V496__subcontract_make_notification_reversals.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V496__subcontract_make_notification_reversals.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V504__inventory_and_procurement_revision_reset_policy.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V504__inventory_and_procurement_revision_reset_policy.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V514__production_material_exact_movement_links.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V514__production_material_exact_movement_links.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V517__inventory_value_custody_positions.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V517__inventory_value_custody_positions.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V518__procurement_iqc_replacement_consideration.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V518__procurement_iqc_replacement_consideration.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V519__financial_actual_amounts_and_book_allocations.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V519__financial_actual_amounts_and_book_allocations.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V522__subcontract_own_material_cost_sources.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V522__subcontract_own_material_cost_sources.sql"));
        serviceSource = read(
                Path.of("src", "main", "java", "com", "uten", "imp", "features", "admin",
                        "systemtest", "BusinessDataResetService.java"),
                Path.of("server", "src", "main", "java", "com", "uten", "imp", "features",
                        "admin", "systemtest", "BusinessDataResetService.java"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V506__inventory_value_openings_and_legacy_cases.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V506__inventory_value_openings_and_legacy_cases.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V547__production_fqc_inspection_sheets.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V547__production_fqc_inspection_sheets.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V548__production_finished_arrival_registration_reversal.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V548__production_finished_arrival_registration_reversal.sql"));
    }

    @Test
    void appTwinFunctionClassifiesExactlyTheOpsScriptTables() {
        Map<String, String> opsPolicy = policy(opsScript);
        Map<String, String> twinPolicy = policy(migrationSql);

        assertThat(opsPolicy).hasSize(320 + RUNTIME_RESET_EXTENSIONS.size());
        assertThat(opsPolicy.values().stream().filter("CLEAR"::equals).count())
                .isEqualTo(224 + RUNTIME_RESET_EXTENSIONS.size());
        assertThat(opsPolicy.values().stream().filter("PRESERVE"::equals).count())
                .isEqualTo(96);

        // V464 基础清单逐表一致：任何一侧漂移（新增/删除/改分类）都失败关闭。
        Map<String, String> opsBase = new LinkedHashMap<>(opsPolicy);
        RUNTIME_RESET_EXTENSIONS.keySet().forEach(opsBase::remove);
        assertThat(twinPolicy).isEqualTo(opsBase);
        // 扩展行必须全部 CLEAR：追加式运行时事件账随系统测试一并清空。
        RUNTIME_RESET_EXTENSIONS.keySet().forEach(table ->
                assertThat(opsPolicy.get(table))
                        .as(table + " runtime reset extension must be CLEAR")
                        .isEqualTo("CLEAR"));
    }

    @Test
    void rootSupplyForwardFixAcceptsV479WithoutAddingAnotherBusinessTable() {
        assertThat(opsScript)
                .contains("(478, 440)")
                .contains("(479, 441)")
                .contains("(480, 442)")
                .contains("(481, 443)")
                .contains("(482, 444)")
                // V483 审计窄修 + V484 运行时清空扩展：均不新增表（444→446）。
                .contains("(483, 445)")
                .contains("(484, 446)")
                // V485 进行中工作台单趟聚合：不新增表（446→447）。
                .contains("(485, 447)")
                .contains("(486, 448)")
                // V488 偏好表补列、V489/V490 换函数、V491 报工门控：均不新增表。
                .contains("(487, 449)")
                .contains("(488, 450)")
                .contains("(489, 451)")
                .contains("(490, 452)")
                .contains("(491, 453)")
                .contains("V484/446、V485/447、V486/448、V487/449、V488/450")
                .contains("(492, 454)")
                .contains("(493, 455)")
                .contains("(494, 456)")
                .contains("(495, 457)")
                .contains("(496, 458)")
                .contains("(497, 459)")
                .contains("(498, 460)")
                .contains("(499, 461)")
                .contains("(500, 462)")
                .contains("(501, 463)")
                .contains("(502, 464)")
                .contains("(503, 465)")
                .contains("(504, 466)")
                .contains("(505, 467)")
                .contains("(506, 468)")
                .contains("(507, 469)")
                .contains("(508, 470)")
                .contains("(527, 486)")
                .contains("(528, 487)")
                .contains("(529, 488)")
                .contains("(530, 489)")
                .contains("(531, 490)")
                .contains("(532, 491)")
                .contains("(533, 492)")
                .contains("(534, 493)")
                .contains("(535, 494)")
                .contains("(536, 495)")
                .contains("(537, 496)")
                .contains("(538, 497)")
                .contains("(539, 498)")
                .contains("(540, 499)")
                .contains("(541, 500)")
                .contains("(545, 503)")
                .contains("(547, 505)")
                .contains("(548, 506)")
                .contains("(549, 507)")
                .contains("(550, 508)")
                .contains("(551, 509)")
                // V552 只加权限码与默认授权，不新增业务表；但迁移头一动，
                // 清库脚本的 fail-closed 白名单就必须跟着动，否则脚本拒跑。
                .contains("(552, 510)")
                .contains("V507/469、V508/470及V511至V552完整目录");
        assertThat(RUNTIME_RESET_EXTENSIONS)
                .containsEntry("preplan_root_output_events", 478)
                .containsEntry("sales_order_qty_change_logs", 484);
    }

    @Test
    void runtimeResetExtensionsPatchTheTwinFunctionFailClosed() {
        // V474 的补丁构件：读取已安装定义、锚点替换插入、锚点缺失即失败关闭。
        assertThat(extensionSql)
                .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                .contains("RAISE EXCEPTION 'V474 cannot extend business_data_reset policy safely'")
                .contains("(''preplan_supply_actions'', ''CLEAR'')");
        for (String table : RUNTIME_RESET_EXTENSIONS.keySet()) {
            assertThat(extensionSql)
                    .as(table + " must be inserted by the runtime reset patch")
                    .contains("'" + table + "'");
        }
    }

    @Test
    void appTwinKeepsOpsFailClosedChecksAndAddsKickAll() {
        // 与 ops 版同款失败关闭构件
        assertThat(migrationSql)
                .contains("存在未分类 public 表")
                .contains("表分类重复/重叠")
                .contains("保留表仍引用待清业务表，禁止清空")
                .contains("EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY'")
                .contains("清空校验失败")
                .contains("保留校验失败")
                .contains("物化视图清空校验失败")
                .contains("账户金额归零校验失败")
                .contains("遗留期初归零校验失败")
                .contains("货品安全库存/成本预算归零校验失败")
                .contains("USING ERRCODE = 'UT900'")
                .contains("REFRESH MATERIALIZED VIEW purchase_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW production_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW stock_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW finance_ar_ap_mv")
                .contains("REFRESH MATERIALIZED VIEW sales_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW subcontract_monthly_mv")
                .contains("UPDATE accounts")
                .contains("balance_current = 0")
                .contains("UPDATE payment_styles")
                .contains("init_balance = 0")
                .doesNotContain("DISABLE TRIGGER");

        // 应用内孪生独有的收尾：全员强制重新登录（epoch + 1 / 断续期）
        assertThat(migrationSql)
                .contains("UPDATE authorization_state")
                .contains("epoch = epoch + 1")
                .contains("TRUNCATE TABLE refresh_tokens RESTART IDENTITY");

        // 摘要出参：服务层据此回显
        assertThat(migrationSql)
                .contains("cleared_table_count INT")
                .contains("cleared_rows BIGINT")
                .contains("preserved_table_count INT")
                .contains("authorization_epoch_after BIGINT");
    }

    @Test
    void serviceOrchestratesOnlyAndBindsActorParameters() {
        // 服务层只编排：调用函数、绑定 actor（? 参数）、设置事务级超时；
        // 清空 SQL 全部在迁移函数里（安全写入门不允许 Java 内联此类 SQL）。
        assertThat(serviceSource)
                .contains("FROM business_data_reset()")
                .contains("SELECT set_config('app.actor_id', ?, true)")
                .contains("SET LOCAL lock_timeout = '15s'")
                .contains("SET LOCAL statement_timeout = '30min'")
                .doesNotContain("TRUNCATE TABLE")
                .doesNotContain("DO $$");
        // 编排门禁与排水
        assertThat(serviceSource)
                .contains("featureGate.requireEnabled()")
                .contains("drainGate.beginDrain")
                .contains("drainGate.endReset()");
    }

    /**
     * <b>迁移头一动，清库脚本的 fail-closed 白名单就必须跟着动。</b>
     *
     * <p>这条耦合被踩过不止一次（2026-09-11 加 V552 时 CI 后端整条挂掉：
     * {@code 仅允许 ...及V511至V551完整目录，当前 V552/510}）。上面那串
     * {@code .contains("(NNN, MMM)")} 断言只能证明「写了什么」，证明不了
     * 「有没有漏写最新那条」——所以这里**从迁移目录算出真实的迁移头**再比对，
     * 漏了就当场报出该补哪一行，不用等跑到真实库才发现。
     *
     * <p>注意版本对是 (Flyway 版本号, 已应用迁移条数)，两者因跳号（如 V544 未发布）
     * 并不相等；条数只能由目录里实际存在的 .sql 个数数出来。
     */
    @Test
    void resetScriptAllowlistCoversTheCurrentMigrationHead() throws IOException {
        Path migrations = resolve(
                Path.of("src", "main", "resources", "db", "migration"),
                Path.of("server", "src", "main", "resources", "db", "migration"));
        int head = 0;
        int count = 0;
        try (var files = Files.list(migrations)) {
            for (Path file : files.toList()) {
                Matcher matcher = MIGRATION_FILE.matcher(file.getFileName().toString());
                if (!matcher.matches()) continue;
                count++;
                head = Math.max(head, Integer.parseInt(matcher.group(1)));
            }
        }
        assertThat(head).as("迁移目录里没找到任何 V*.sql").isGreaterThan(0);

        String expected = "(" + head + ", " + count + ")";
        assertThat(opsScript)
                .as("""
                        ops/reset_business_data.sql 的迁移头白名单没有覆盖当前迁移头。
                        请在版本对列表末尾补上 %s，并把异常文案里的上界改成 V%d。
                        （新增迁移就必须同步这张表，否则整个清库脚本 fail-closed 拒跑。）"""
                        .formatted(expected, head))
                .contains(expected);
        assertThat(opsScript)
                .as("异常文案里的上界也要同步到 V%d".formatted(head))
                .contains("及V511至V" + head + "完整目录");

        // 同一条耦合的第三处：迁移演练 / 引导兼容性用例把迁移头钉成两个常量。
        // 2026-09-11 就是漏了它，CI 后端又挂一轮（expected 509 but was 510）。
        String rehearsal = read(
                Path.of("src", "test", "java", "com", "uten", "imp", "migration",
                        "MigrationRehearsalSupport.java"),
                Path.of("server", "src", "test", "java", "com", "uten", "imp", "migration",
                        "MigrationRehearsalSupport.java"));
        assertThat(rehearsal)
                .as("MigrationRehearsalSupport 的迁移头常量没跟上："
                        + "请改成 CURRENT_HEAD_VERSION = \"%d\"; CURRENT_MIGRATION_COUNT = %d;"
                                .formatted(head, count))
                .contains("CURRENT_HEAD_VERSION = \"" + head + "\"")
                .contains("CURRENT_MIGRATION_COUNT = " + count);

        // 第四处：迁移总览文档的「当前正式目录」。
        // LegacyMigrationSafetyContractTest 会拿上面那两个常量去比对这一行，
        // 所以文档漏改一样让 CI 后端整轮挂——2026-09-12 又栽了一次。
        // 那条断言在另一个测试类里，但**这里是新增迁移时唯一该看的清单**，
        // 因此把它一并纳入，宁可重复也别再漏。
        String migrationReadme = read(
                Path.of("..", "docs", "数据迁移", "README.md"),
                Path.of("docs", "数据迁移", "README.md"));
        assertThat(migrationReadme)
                .as("docs/数据迁移/README.md 的「当前正式目录」没跟上："
                        + "请改成 **当前正式目录：V%d/%d …**（并补一句新迁移做了什么）"
                                .formatted(head, count))
                .contains("当前正式目录：V" + head + "/" + count);
    }

    private static Path resolve(Path direct, Path fallback) {
        return Files.exists(direct) ? direct : fallback;
    }

    private static String read(Path direct, Path fallback) throws IOException {
        return Files.readString(resolve(direct, fallback), StandardCharsets.UTF_8);
    }

    /** {@code V552__xxx.sql} → 捕获版本号；R__/U__ 等非版本迁移不计。 */
    private static final Pattern MIGRATION_FILE =
            Pattern.compile("^V([0-9]+)__.*\\.sql$");

    static Map<String, String> policy(String sql) {
        Map<String, String> result = new LinkedHashMap<>();
        Matcher matcher = POLICY_ROW.matcher(sql);
        while (matcher.find()) {
            String previous = result.put(matcher.group(1), matcher.group(2));
            assertThat(previous)
                    .as("duplicate policy row for " + matcher.group(1))
                    .isNull();
        }
        return result;
    }
}
